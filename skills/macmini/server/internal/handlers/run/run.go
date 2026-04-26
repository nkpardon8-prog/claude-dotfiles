package run

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"macmini-server/internal/logging"
	"macmini-server/internal/redact"
)

// RunRequest is the buffered + streaming /run input.
type RunRequest struct {
	Command        string `json:"command"`
	CWD            string `json:"cwd,omitempty"`
	TimeoutSeconds int    `json:"timeout_seconds,omitempty"`
}

type RunResponse struct {
	Stdout          string  `json:"stdout"`
	Stderr          string  `json:"stderr"`
	ExitCode        int     `json:"exit_code"`
	DurationSeconds float64 `json:"duration_seconds"`
	Truncated       bool    `json:"truncated"`
	RequestID       string  `json:"request_id"`
}

type errorResponse struct {
	Error     string `json:"error"`
	Detail    string `json:"detail"`
	RequestID string `json:"request_id"`
}

const (
	defaultTimeoutSeconds = 30
	maxTimeoutSeconds     = 300
	maxBufferedBytes      = 1 << 20 // 1 MiB per stream (buffered)
	maxStreamLineBytes    = 64 << 10
	idemTTL               = 60 * time.Second
)

// idemSlot tracks an Idempotency-Key in flight or recently completed.
type idemSlot struct {
	done      chan struct{}
	result    *RunResponse
	startedAt time.Time
}

var (
	idemMap     sync.Map // string -> *idemSlot
	janitorOnce sync.Once
)

// Register installs POST /run and POST /run/stream behind authMW. redactList is
// passed in (built once at startup by main).
func Register(mux *http.ServeMux, authMW func(http.Handler) http.Handler, redactList []string) {
	startJanitor()

	bufH := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handleBuffered(w, r, redactList)
	})
	streamH := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handleStream(w, r, redactList)
	})
	mux.Handle("POST /run", authMW(bufH))
	mux.Handle("POST /run/stream", authMW(streamH))
}

func startJanitor() {
	janitorOnce.Do(func() {
		go func() {
			ticker := time.NewTicker(30 * time.Second)
			defer ticker.Stop()
			for range ticker.C {
				now := time.Now()
				idemMap.Range(func(k, v any) bool {
					slot := v.(*idemSlot)
					select {
					case <-slot.done:
						if now.Sub(slot.startedAt) > idemTTL {
							idemMap.Delete(k)
						}
					default:
						// in flight; never sweep an in-flight slot
					}
					return true
				})
			}
		}()
	})
}

func handleBuffered(w http.ResponseWriter, r *http.Request, redactList []string) {
	rid := logging.RequestIDFromContext(r)
	w.Header().Set("Content-Type", "application/json")

	var req RunRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse{
			Error: "run.bad_request", Detail: err.Error(), RequestID: rid,
		})
		return
	}
	if req.Command == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse{
			Error: "run.empty_command", Detail: "command is required", RequestID: rid,
		})
		return
	}

	idemKey := r.Header.Get("Idempotency-Key")
	var slot *idemSlot
	if idemKey != "" {
		newSlot := &idemSlot{done: make(chan struct{}), startedAt: time.Now()}
		actual, loaded := idemMap.LoadOrStore(idemKey, newSlot)
		slot = actual.(*idemSlot)
		if loaded {
			// Existing slot
			select {
			case <-slot.done:
				if time.Since(slot.startedAt) <= idemTTL && slot.result != nil {
					writeJSON(w, http.StatusOK, slot.result)
					return
				}
				// Stale — overwrite
				newSlot = &idemSlot{done: make(chan struct{}), startedAt: time.Now()}
				idemMap.Store(idemKey, newSlot)
				slot = newSlot
			default:
				writeJSON(w, http.StatusConflict, errorResponse{
					Error:     "run.idempotency_in_flight",
					Detail:    "another request with this Idempotency-Key is still running",
					RequestID: rid,
				})
				return
			}
		}
	}

	timeout := chooseTimeout(req.TimeoutSeconds)
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "/bin/zsh", "-lc", req.Command)
	if req.CWD != "" {
		cmd.Dir = req.CWD
	}
	cmd.Env = curatedEnv()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	var stdoutBuf, stderrBuf bytes.Buffer
	stdoutCap := &capWriter{buf: &stdoutBuf, max: maxBufferedBytes}
	stderrCap := &capWriter{buf: &stderrBuf, max: maxBufferedBytes}
	cmd.Stdout = stdoutCap
	cmd.Stderr = stderrCap

	start := time.Now()
	runErr := cmd.Run()
	dur := time.Since(start).Seconds()

	// Process-group cleanup for any orphaned descendants. Best-effort.
	if cmd.Process != nil {
		_ = killGroup(cmd.Process.Pid)
	}

	exitCode := 0
	timedOut := errors.Is(ctx.Err(), context.DeadlineExceeded)
	switch {
	case timedOut:
		// Mirror coreutils `timeout`: exit 124 when the deadline tripped.
		exitCode = 124
	case runErr == nil:
		exitCode = 0
	default:
		var ee *exec.ExitError
		if errors.As(runErr, &ee) {
			exitCode = ee.ExitCode()
		} else {
			exitCode = 1
		}
	}

	resp := RunResponse{
		Stdout:          redact.Scrub(stdoutBuf.String(), redactList),
		Stderr:          redact.Scrub(stderrBuf.String(), redactList),
		ExitCode:        exitCode,
		DurationSeconds: dur,
		Truncated:       stdoutCap.truncated || stderrCap.truncated,
		RequestID:       rid,
	}

	if slot != nil {
		slot.result = &resp
		close(slot.done)
	}
	writeJSON(w, http.StatusOK, resp)
}

func handleStream(w http.ResponseWriter, r *http.Request, redactList []string) {
	rid := logging.RequestIDFromContext(r)

	var req RunRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.Header().Set("Content-Type", "application/json")
		writeJSON(w, http.StatusBadRequest, errorResponse{
			Error: "run.bad_request", Detail: err.Error(), RequestID: rid,
		})
		return
	}
	if req.Command == "" {
		w.Header().Set("Content-Type", "application/json")
		writeJSON(w, http.StatusBadRequest, errorResponse{
			Error: "run.empty_command", Detail: "command is required", RequestID: rid,
		})
		return
	}

	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-store")

	flusher, _ := w.(http.Flusher)
	enc := json.NewEncoder(w)

	emit := func(obj any) {
		if err := enc.Encode(obj); err != nil {
			slog.Error("run.stream.encode_failed", slog.String("err", err.Error()), slog.String("request_id", rid))
		}
		if flusher != nil {
			flusher.Flush()
		}
	}

	timeout := chooseTimeout(req.TimeoutSeconds)
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "/bin/zsh", "-lc", req.Command)
	if req.CWD != "" {
		cmd.Dir = req.CWD
	}
	cmd.Env = curatedEnv()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		emit(errorResponse{Error: "run.stdout_pipe_failed", Detail: err.Error(), RequestID: rid})
		return
	}
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		emit(errorResponse{Error: "run.stderr_pipe_failed", Detail: err.Error(), RequestID: rid})
		return
	}

	var emitMu sync.Mutex
	safeEmit := func(obj any) {
		emitMu.Lock()
		defer emitMu.Unlock()
		emit(obj)
	}

	start := time.Now()
	if err := cmd.Start(); err != nil {
		safeEmit(errorResponse{Error: "run.start_failed", Detail: err.Error(), RequestID: rid})
		return
	}

	exitCode := 1
	defer func() {
		safeEmit(map[string]any{
			"event":       "exit",
			"code":        exitCode,
			"duration_ms": time.Since(start).Milliseconds(),
			"request_id":  rid,
		})
	}()

	pumpDone := make(chan struct{}, 2)
	pump := func(stream string, src io.Reader) {
		defer func() { pumpDone <- struct{}{} }()
		scanner := bufio.NewScanner(src)
		// Allow long lines; we cap per-line below.
		scanner.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
		for scanner.Scan() {
			line := scanner.Text()
			line = redact.Scrub(line, redactList)
			for len(line) > maxStreamLineBytes {
				safeEmit(map[string]any{
					"event":  "line_truncated",
					"stream": stream,
				})
				safeEmit(map[string]any{
					"stream": stream,
					"data":   line[:maxStreamLineBytes],
					"ts_ms":  time.Now().UnixMilli(),
				})
				line = line[maxStreamLineBytes:]
			}
			safeEmit(map[string]any{
				"stream": stream,
				"data":   line,
				"ts_ms":  time.Now().UnixMilli(),
			})
		}
	}

	go pump("stdout", stdoutPipe)
	go pump("stderr", stderrPipe)

	// Watch for client disconnect / timeout — kill the process group either way.
	doneCh := make(chan error, 1)
	go func() { doneCh <- cmd.Wait() }()

	var waitErr error
	select {
	case waitErr = <-doneCh:
	case <-r.Context().Done():
		// Client went away — kill the process group and drain.
		if cmd.Process != nil {
			_ = killGroup(cmd.Process.Pid)
		}
		waitErr = <-doneCh
	}

	// Drain pumps so the final exit JSON appears AFTER all output lines.
	<-pumpDone
	<-pumpDone

	timedOut := errors.Is(ctx.Err(), context.DeadlineExceeded)
	switch {
	case timedOut:
		exitCode = 124
	case waitErr == nil:
		exitCode = 0
	default:
		var ee *exec.ExitError
		if errors.As(waitErr, &ee) {
			exitCode = ee.ExitCode()
		} else {
			exitCode = 1
		}
	}
}

// curatedEnv returns the explicit allowlist of env vars to pass to spawned
// shells. We do NOT inherit os.Environ() — that would leak server-side
// MACMINI_TOKEN_PATH etc. into user shells.
func curatedEnv() []string {
	env := []string{
		"PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
	}
	for _, k := range []string{"HOME", "USER", "LANG", "TERM", "SHELL"} {
		if v, ok := os.LookupEnv(k); ok {
			env = append(env, fmt.Sprintf("%s=%s", k, v))
		}
	}
	return env
}

func chooseTimeout(requested int) time.Duration {
	t := requested
	if t <= 0 {
		t = defaultTimeoutSeconds
	}
	if t > maxTimeoutSeconds {
		t = maxTimeoutSeconds
	}
	return time.Duration(t) * time.Second
}

// killGroup sends SIGTERM to the negative PID (process group), waits 2s, then
// sends SIGKILL. Best-effort; errors are intentionally swallowed.
func killGroup(pid int) error {
	if pid <= 0 {
		return nil
	}
	_ = syscall.Kill(-pid, syscall.SIGTERM)
	go func() {
		time.Sleep(2 * time.Second)
		_ = syscall.Kill(-pid, syscall.SIGKILL)
	}()
	return nil
}

// capWriter is an io.Writer that fills a bytes.Buffer up to max bytes and
// silently drops the rest, flagging truncated=true.
type capWriter struct {
	buf       *bytes.Buffer
	max       int
	truncated bool
}

func (c *capWriter) Write(p []byte) (int, error) {
	remaining := c.max - c.buf.Len()
	if remaining <= 0 {
		c.truncated = true
		return len(p), nil
	}
	if len(p) > remaining {
		c.buf.Write(p[:remaining])
		c.truncated = true
		return len(p), nil
	}
	return c.buf.Write(p)
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
