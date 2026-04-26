package transport

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"macmini-client/internal/redact"
)

const (
	defaultPort     = 8765
	requestTimeout  = 30 * time.Second
	streamTimeout   = 0 // no overall timeout for streaming responses
	retryBackoff    = 200 * time.Millisecond
	maxRetries      = 2
	missingEnvFatal = "Missing CRD_MAC_MINI_HOSTNAME and/or CRD_SERVER_TOKEN env. Run /load-creds CRD_PIN,CRD_MAC_MINI_HOSTNAME,CRD_DEVICE_NAME,CRD_SERVER_TOKEN in your Claude Code session."
)

// HealthResp mirrors the server's /health response shape.
type HealthResp struct {
	OK            bool    `json:"ok"`
	Version       string  `json:"version"`
	UptimeSeconds float64 `json:"uptime_seconds"`
}

// PushResp mirrors POST /files/push.
type PushResp struct {
	OK           bool   `json:"ok"`
	BytesWritten int64  `json:"bytes_written"`
	SHA256       string `json:"sha256"`
	RemotePath   string `json:"remote_path"`
}

// PullResp summarises a successful GET /files/pull. (Body is streamed to disk.)
type PullResp struct {
	OK         bool   `json:"ok"`
	LocalPath  string `json:"local_path"`
	BytesRead  int64  `json:"bytes_read"`
	SHA256     string `json:"sha256"`
	RemotePath string `json:"remote_path"`
}

// RunRequest mirrors the server-side struct.
type RunRequest struct {
	Command        string `json:"command"`
	CWD            string `json:"cwd,omitempty"`
	TimeoutSeconds int    `json:"timeout_seconds,omitempty"`
	IdempotencyKey string `json:"-"`
}

// RunResp mirrors the buffered POST /run response.
type RunResp struct {
	Stdout          string  `json:"stdout"`
	Stderr          string  `json:"stderr"`
	ExitCode        int     `json:"exit_code"`
	DurationSeconds float64 `json:"duration_seconds"`
	Truncated       bool    `json:"truncated"`
	RequestID       string  `json:"request_id"`
}

// RotateResp mirrors POST /admin/rotate-token.
type RotateResp struct {
	OK             bool   `json:"ok"`
	NewToken       string `json:"new_token"`
	NewFingerprint string `json:"new_fingerprint"`
}

// VersionResp is a thin wrapper for /version (or reused HealthResp.Version).
type VersionResp struct {
	Version string `json:"version"`
}

// ServerError is the structured 4xx/5xx body returned by handlers.
type ServerError struct {
	Status    int    `json:"-"`
	Code      string `json:"error"`
	Detail    string `json:"detail"`
	RequestID string `json:"request_id"`
}

func (e *ServerError) Error() string {
	if e.Detail != "" {
		return fmt.Sprintf("server error %d: %s: %s", e.Status, e.Code, e.Detail)
	}
	return fmt.Sprintf("server error %d: %s", e.Status, e.Code)
}

// TransportError signals a connection / auth / setup problem distinct from a
// well-formed server error response.
type TransportError struct {
	Op  string
	Err error
}

func (e *TransportError) Error() string {
	return fmt.Sprintf("%s: %v", e.Op, e.Err)
}

func (e *TransportError) Unwrap() error { return e.Err }

// Client is a thin wrapper around http.Client that knows about the server's
// auth model and routes.
type Client struct {
	host  string
	token string
	httpc *http.Client
}

// retryingTransport retries up to maxRetries times on connection-reset, 502, 503.
type retryingTransport struct {
	base http.RoundTripper
}

func (rt *retryingTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	// Buffer the body so we can replay it on retry.
	var bodyBytes []byte
	if req.Body != nil && req.GetBody == nil {
		b, err := io.ReadAll(req.Body)
		if err != nil {
			return nil, err
		}
		_ = req.Body.Close()
		bodyBytes = b
		req.Body = io.NopCloser(bytes.NewReader(bodyBytes))
		req.GetBody = func() (io.ReadCloser, error) {
			return io.NopCloser(bytes.NewReader(bodyBytes)), nil
		}
	}

	var lastResp *http.Response
	var lastErr error
	for attempt := 0; attempt <= maxRetries; attempt++ {
		if attempt > 0 {
			if req.GetBody != nil {
				newBody, err := req.GetBody()
				if err != nil {
					return nil, err
				}
				req.Body = newBody
			}
			time.Sleep(retryBackoff)
		}
		resp, err := rt.base.RoundTrip(req)
		if err != nil {
			lastErr = err
			lastResp = nil
			if isRetryableErr(err) {
				continue
			}
			return nil, err
		}
		if resp.StatusCode == http.StatusBadGateway || resp.StatusCode == http.StatusServiceUnavailable {
			// drain + close so we can retry
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
			lastResp = nil
			lastErr = fmt.Errorf("server returned %d", resp.StatusCode)
			continue
		}
		return resp, nil
	}
	if lastResp != nil {
		return lastResp, nil
	}
	return nil, lastErr
}

func isRetryableErr(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "connection reset") ||
		strings.Contains(msg, "EOF") ||
		strings.Contains(msg, "broken pipe")
}

// New constructs a Client by reading env. On missing env it prints the exact
// message the plan requires and exits with code 2.
func New() *Client {
	host := strings.TrimSpace(os.Getenv("CRD_MAC_MINI_HOSTNAME"))
	token := strings.TrimSpace(os.Getenv("CRD_SERVER_TOKEN"))
	if host == "" || token == "" {
		fmt.Fprintln(os.Stderr, missingEnvFatal)
		os.Exit(2)
	}

	base := http.DefaultTransport.(*http.Transport).Clone()
	base.MaxIdleConnsPerHost = 4

	return &Client{
		host:  host,
		token: token,
		httpc: &http.Client{
			Timeout:   requestTimeout,
			Transport: &retryingTransport{base: base},
		},
	}
}

func (c *Client) baseURL() string {
	return fmt.Sprintf("http://%s:%d", c.host, defaultPort)
}

func (c *Client) newRequest(method, path string, body io.Reader, auth bool) (*http.Request, error) {
	req, err := http.NewRequest(method, c.baseURL()+path, body)
	if err != nil {
		return nil, err
	}
	if auth {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	return req, nil
}

func (c *Client) do(req *http.Request) (*http.Response, error) {
	resp, err := c.httpc.Do(req)
	if err != nil {
		return nil, &TransportError{Op: req.Method + " " + req.URL.Path, Err: errors.New(redact.Scrub(err.Error()))}
	}
	return resp, nil
}

// readError parses a server JSON error or returns a generic ServerError.
func readError(resp *http.Response) error {
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	var se ServerError
	if jerr := json.Unmarshal(body, &se); jerr == nil && se.Code != "" {
		se.Status = resp.StatusCode
		return &se
	}
	return &ServerError{
		Status: resp.StatusCode,
		Code:   "unknown",
		Detail: strings.TrimSpace(string(body)),
	}
}

// Health calls GET /health (no auth).
func (c *Client) Health() (*HealthResp, error) {
	req, err := c.newRequest(http.MethodGet, "/health", nil, false)
	if err != nil {
		return nil, &TransportError{Op: "health", Err: err}
	}
	resp, err := c.do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, readError(resp)
	}
	var out HealthResp
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, &TransportError{Op: "health.decode", Err: err}
	}
	return &out, nil
}

// Paste calls POST /paste with text body.
func (c *Client) Paste(text string) error {
	body, _ := json.Marshal(map[string]string{"text": text})
	req, err := c.newRequest(http.MethodPost, "/paste", bytes.NewReader(body), true)
	if err != nil {
		return &TransportError{Op: "paste", Err: err}
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return readError(resp)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	return nil
}

// Push uploads a local file to remote via POST /files/push (multipart).
func (c *Client) Push(local, remote string, overwrite bool) (*PushResp, error) {
	f, err := os.Open(local)
	if err != nil {
		return nil, &TransportError{Op: "push.open", Err: err}
	}
	defer f.Close()

	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)
	errCh := make(chan error, 1)
	go func() {
		defer pw.Close()
		defer mw.Close()
		if err := mw.WriteField("remote_path", remote); err != nil {
			errCh <- err
			return
		}
		if overwrite {
			if err := mw.WriteField("overwrite", "true"); err != nil {
				errCh <- err
				return
			}
		}
		fw, err := mw.CreateFormFile("file", filepath.Base(local))
		if err != nil {
			errCh <- err
			return
		}
		if _, err := io.Copy(fw, f); err != nil {
			errCh <- err
			return
		}
		errCh <- nil
	}()

	req, err := c.newRequest(http.MethodPost, "/files/push", pr, true)
	if err != nil {
		return nil, &TransportError{Op: "push", Err: err}
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())

	resp, err := c.do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if werr := <-errCh; werr != nil {
		return nil, &TransportError{Op: "push.write", Err: werr}
	}
	if resp.StatusCode != http.StatusOK {
		return nil, readError(resp)
	}
	var out PushResp
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, &TransportError{Op: "push.decode", Err: err}
	}
	return &out, nil
}

// Pull streams remote → local file via GET /files/pull.
func (c *Client) Pull(remote, local string) (*PullResp, error) {
	q := url.Values{}
	q.Set("remote_path", remote)
	req, err := c.newRequest(http.MethodGet, "/files/pull?"+q.Encode(), nil, true)
	if err != nil {
		return nil, &TransportError{Op: "pull", Err: err}
	}
	resp, err := c.do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, readError(resp)
	}
	out, err := os.Create(local)
	if err != nil {
		return nil, &TransportError{Op: "pull.create", Err: err}
	}
	defer out.Close()
	n, err := io.Copy(out, resp.Body)
	if err != nil {
		return nil, &TransportError{Op: "pull.copy", Err: err}
	}
	return &PullResp{
		OK:         true,
		LocalPath:  local,
		BytesRead:  n,
		SHA256:     resp.Header.Get("X-SHA256"),
		RemotePath: remote,
	}, nil
}

// Run calls POST /run (buffered).
func (c *Client) Run(req RunRequest) (*RunResp, error) {
	body, _ := json.Marshal(req)
	hreq, err := c.newRequest(http.MethodPost, "/run", bytes.NewReader(body), true)
	if err != nil {
		return nil, &TransportError{Op: "run", Err: err}
	}
	hreq.Header.Set("Content-Type", "application/json")
	if req.IdempotencyKey != "" {
		hreq.Header.Set("Idempotency-Key", req.IdempotencyKey)
	}
	// Buffered runs may take longer than the default 30s if the user passed
	// a longer server-side timeout. Use a one-shot client so we don't mutate
	// shared state.
	runClient := &http.Client{
		Timeout:   clientTimeoutFor(req.TimeoutSeconds),
		Transport: c.httpc.Transport,
	}
	resp, err := runClient.Do(hreq)
	if err != nil {
		return nil, &TransportError{Op: "run.do", Err: errors.New(redact.Scrub(err.Error()))}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, readError(resp)
	}
	var out RunResp
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, &TransportError{Op: "run.decode", Err: err}
	}
	return &out, nil
}

func clientTimeoutFor(serverTimeoutSeconds int) time.Duration {
	if serverTimeoutSeconds <= 0 {
		return requestTimeout
	}
	// Give some slack so the server can return its own timeout JSON
	// rather than us aborting transport-side first.
	return time.Duration(serverTimeoutSeconds+10) * time.Second
}

// RunStreamResult captures the trailing {"event":"exit",...} record so the
// caller can format a human-readable trailer.
type RunStreamResult struct {
	ExitCode   int
	DurationMS int64
}

// RunStream calls POST /run/stream and pipes raw NDJSON lines to w as they
// arrive. It returns the remote exit code reported by the final
// {"event":"exit","code":N,...} line.
func (c *Client) RunStream(req RunRequest, w io.Writer) (*RunStreamResult, error) {
	body, _ := json.Marshal(req)
	hreq, err := c.newRequest(http.MethodPost, "/run/stream", bytes.NewReader(body), true)
	if err != nil {
		return &RunStreamResult{ExitCode: 2}, &TransportError{Op: "run-stream", Err: err}
	}
	hreq.Header.Set("Content-Type", "application/json")
	hreq.Header.Set("Accept", "application/x-ndjson")

	// Streaming: bypass the per-request timeout (it would kill long streams).
	streamingClient := &http.Client{
		Timeout:   streamTimeout,
		Transport: c.httpc.Transport,
	}
	resp, err := streamingClient.Do(hreq)
	if err != nil {
		return &RunStreamResult{ExitCode: 2}, &TransportError{Op: "run-stream.do", Err: errors.New(redact.Scrub(err.Error()))}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return &RunStreamResult{ExitCode: 1}, readError(resp)
	}

	result := &RunStreamResult{}
	br := bufio.NewReaderSize(resp.Body, 64<<10)
	for {
		line, err := br.ReadBytes('\n')
		if len(line) > 0 {
			if _, werr := w.Write(line); werr != nil {
				return &RunStreamResult{ExitCode: 2}, &TransportError{Op: "run-stream.write", Err: werr}
			}
			// Inspect for the final exit record.
			var probe struct {
				Event      string `json:"event"`
				Code       int    `json:"code"`
				DurationMS int64  `json:"duration_ms"`
			}
			if jerr := json.Unmarshal(bytes.TrimSpace(line), &probe); jerr == nil {
				if probe.Event == "exit" {
					result.ExitCode = probe.Code
					result.DurationMS = probe.DurationMS
				}
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return &RunStreamResult{ExitCode: 2}, &TransportError{Op: "run-stream.read", Err: errors.New(redact.Scrub(err.Error()))}
		}
	}
	return result, nil
}

// Shot calls POST /shot and writes the PNG to w.
func (c *Client) Shot(out io.Writer) error {
	req, err := c.newRequest(http.MethodPost, "/shot", nil, true)
	if err != nil {
		return &TransportError{Op: "shot", Err: err}
	}
	resp, err := c.do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return readError(resp)
	}
	if _, err := io.Copy(out, resp.Body); err != nil {
		return &TransportError{Op: "shot.copy", Err: err}
	}
	return nil
}

// RotateToken calls POST /admin/rotate-token using the current token.
// The returned RotateResp.NewToken replaces the in-memory token in this
// process; callers should also update 1Password / credentials.md.
func (c *Client) RotateToken() (*RotateResp, error) {
	req, err := c.newRequest(http.MethodPost, "/admin/rotate-token", nil, true)
	if err != nil {
		return nil, &TransportError{Op: "rotate-token", Err: err}
	}
	resp, err := c.do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, readError(resp)
	}
	var out RotateResp
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, &TransportError{Op: "rotate-token.decode", Err: err}
	}
	return &out, nil
}

// Version returns the server version. The server exposes it via /health, so
// we reuse that endpoint to avoid coupling the client to a route the plan
// did not require.
func (c *Client) Version() (*VersionResp, error) {
	h, err := c.Health()
	if err != nil {
		return nil, err
	}
	return &VersionResp{Version: h.Version}, nil
}

// Helper: parse an integer flag value safely.
func ParseInt(s string) (int, error) {
	return strconv.Atoi(s)
}
