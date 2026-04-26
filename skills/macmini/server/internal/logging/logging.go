package logging

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	maxLogSize      int64 = 50 * 1024 * 1024 // 50 MiB
	keepGenerations       = 3
)

// RotatingWriter is an io.WriteCloser that rotates the underlying file once it
// exceeds maxLogSize. It keeps `keepGenerations` historical files (.1 .. .N).
// Implementation is in-process; no external newsyslog dependency.
type RotatingWriter struct {
	mu   sync.Mutex
	path string
	f    *os.File
	size int64
}

// NewRotatingWriter opens (or creates) the log file at path and returns a
// rotating writer. It ensures the parent directory exists.
func NewRotatingWriter(path string) (*RotatingWriter, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("mkdir log dir: %w", err)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open log file: %w", err)
	}
	st, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("stat log file: %w", err)
	}
	return &RotatingWriter{path: path, f: f, size: st.Size()}, nil
}

func (w *RotatingWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.size+int64(len(p)) > maxLogSize {
		if err := w.rotateLocked(); err != nil {
			return 0, err
		}
	}
	n, err := w.f.Write(p)
	w.size += int64(n)
	return n, err
}

// Close closes the underlying file handle.
func (w *RotatingWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f == nil {
		return nil
	}
	err := w.f.Close()
	w.f = nil
	return err
}

func (w *RotatingWriter) rotateLocked() error {
	if w.f != nil {
		_ = w.f.Close()
		w.f = nil
	}
	// Shift .N-1 -> .N, ..., .1 -> .2, current -> .1.
	for i := keepGenerations; i >= 1; i-- {
		var src string
		if i-1 == 0 {
			src = w.path
		} else {
			src = fmt.Sprintf("%s.%d", w.path, i-1)
		}
		dst := fmt.Sprintf("%s.%d", w.path, i)
		if i == keepGenerations {
			_ = os.Remove(dst)
		}
		if _, err := os.Stat(src); err == nil {
			_ = os.Rename(src, dst)
		}
	}
	f, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("reopen log file after rotate: %w", err)
	}
	w.f = f
	w.size = 0
	return nil
}

// NewLogger builds a slog.Logger that writes JSON lines to w (typically a
// RotatingWriter). Authorization headers and request/response bodies must
// never be passed to this logger.
func NewLogger(w io.Writer) *slog.Logger {
	return slog.New(slog.NewJSONHandler(w, &slog.HandlerOptions{Level: slog.LevelInfo}))
}

// NewRequestID returns a random 16-char hex request id.
func NewRequestID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Sprintf("t%x", time.Now().UnixNano())
	}
	return hex.EncodeToString(b[:])
}

type ctxKey int

const (
	ctxKeyRequestID ctxKey = iota
)

// RequestIDFromContext returns the request id stored on r by Middleware (or ""
// if none was set).
func RequestIDFromContext(r *http.Request) string {
	if v, ok := r.Context().Value(ctxKeyRequestID).(string); ok {
		return v
	}
	return ""
}

type statusRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (s *statusRecorder) WriteHeader(code int) {
	if s.wroteHeader {
		return
	}
	s.status = code
	s.wroteHeader = true
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(p []byte) (int, error) {
	if !s.wroteHeader {
		s.status = http.StatusOK
		s.wroteHeader = true
	}
	return s.ResponseWriter.Write(p)
}

// Flush forwards to the underlying ResponseWriter if it supports flushing
// (needed by /run/stream NDJSON output).
func (s *statusRecorder) Flush() {
	if f, ok := s.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Middleware emits two JSON lines per request — request_start and request_end —
// using the supplied logger. It NEVER logs the Authorization header, request
// body, or response body.
func Middleware(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			rid := NewRequestID()
			ctx := context.WithValue(r.Context(), ctxKeyRequestID, rid)
			r = r.WithContext(ctx)

			route := r.Method + " " + r.URL.Path
			start := time.Now()
			logger.Info("request_start",
				slog.String("request_id", rid),
				slog.String("route", route),
			)

			w.Header().Set("X-Request-ID", rid)
			rec := &statusRecorder{ResponseWriter: w}

			next.ServeHTTP(rec, r)

			logger.Info("request_end",
				slog.String("request_id", rid),
				slog.String("route", route),
				slog.Int("status", rec.status),
				slog.Float64("duration_ms", float64(time.Since(start).Microseconds())/1000.0),
			)
		})
	}
}
