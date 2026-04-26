package files

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"macmini-server/internal/config"
	"macmini-server/internal/logging"
)

const (
	maxPushBytes        int64 = 100 << 20 // 100 MiB
	multipartMemoryByte int64 = 32 << 20  // 32 MiB before spooling to disk
)

// allowedRoots is per-handler policy (NOT cross-cutting). Adding a new
// destination is a single edit here.
var allowedRoots = []string{
	"~/Desktop",
	"~/Documents/macmini-skill",
	"/tmp/macmini-skill",
}

type PushResponse struct {
	OK           bool   `json:"ok"`
	BytesWritten int64  `json:"bytes_written"`
	SHA256       string `json:"sha256"`
	RemotePath   string `json:"remote_path"`
}

type errorResponse struct {
	Error     string `json:"error"`
	Detail    string `json:"detail"`
	RequestID string `json:"request_id"`
}

// Register installs POST /files/push and GET /files/pull behind authMW. It
// also expands and creates the allowlist roots at startup so allowlist checks
// are filesystem-realistic.
func Register(mux *http.ServeMux, authMW func(http.Handler) http.Handler) {
	roots := expandedRoots()
	for _, r := range roots {
		_ = os.MkdirAll(r, 0o755)
	}

	pushH := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handlePush(w, r, roots)
	})
	pullH := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handlePull(w, r, roots)
	})
	mux.Handle("POST /files/push", authMW(pushH))
	mux.Handle("GET /files/pull", authMW(pullH))
}

func expandedRoots() []string {
	out := make([]string, 0, len(allowedRoots))
	for _, r := range allowedRoots {
		out = append(out, config.ExpandHome(r))
	}
	return out
}

// resolveAndAllowlist resolves an input path (after expanding "~/") to an
// absolute, symlink-resolved path and verifies it falls under one of the
// allowlist roots. If the file does not yet exist, the parent directory is
// resolved instead — this keeps create-new flows valid.
func resolveAndAllowlist(input string, roots []string) (string, error) {
	if input == "" {
		return "", errors.New("empty path")
	}
	abs, err := filepath.Abs(config.ExpandHome(input))
	if err != nil {
		return "", fmt.Errorf("abs: %w", err)
	}
	resolved := abs
	if r, err := filepath.EvalSymlinks(abs); err == nil {
		resolved = r
	} else {
		// File may not exist yet (push case). Resolve the parent dir instead so
		// symlink escape via the parent is still caught.
		parent := filepath.Dir(abs)
		base := filepath.Base(abs)
		if rp, err := filepath.EvalSymlinks(parent); err == nil {
			resolved = filepath.Join(rp, base)
		}
	}
	for _, root := range roots {
		rootAbs, err := filepath.Abs(root)
		if err != nil {
			continue
		}
		// Resolve the root through symlinks too; otherwise a /tmp -> /private/tmp
		// indirection on macOS makes every check fail.
		if r, err := filepath.EvalSymlinks(rootAbs); err == nil {
			rootAbs = r
		}
		rel, err := filepath.Rel(rootAbs, resolved)
		if err != nil {
			continue
		}
		if rel == "." || (!strings.HasPrefix(rel, "..") && !filepath.IsAbs(rel)) {
			return resolved, nil
		}
	}
	return "", fmt.Errorf("path %q is outside allowlist roots", input)
}

func handlePush(w http.ResponseWriter, r *http.Request, roots []string) {
	rid := logging.RequestIDFromContext(r)
	w.Header().Set("Content-Type", "application/json")

	r.Body = http.MaxBytesReader(w, r.Body, maxPushBytes)
	if err := r.ParseMultipartForm(multipartMemoryByte); err != nil {
		writeErr(w, http.StatusBadRequest, errorResponse{
			Error:     "files.bad_multipart",
			Detail:    err.Error(),
			RequestID: rid,
		})
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		writeErr(w, http.StatusBadRequest, errorResponse{
			Error:     "files.missing_file",
			Detail:    err.Error(),
			RequestID: rid,
		})
		return
	}
	defer file.Close()
	_ = header // header.Filename is informational; remote_path is authoritative

	remotePath := r.FormValue("remote_path")
	overwrite := strings.EqualFold(r.FormValue("overwrite"), "true")

	resolved, err := resolveAndAllowlist(remotePath, roots)
	if err != nil {
		writeErr(w, http.StatusForbidden, errorResponse{
			Error:     "files.path_outside_allowlist",
			Detail:    err.Error(),
			RequestID: rid,
		})
		return
	}

	if _, err := os.Stat(resolved); err == nil && !overwrite {
		writeErr(w, http.StatusConflict, errorResponse{
			Error:     "files.exists",
			Detail:    fmt.Sprintf("file %q exists; pass overwrite=true to replace", remotePath),
			RequestID: rid,
		})
		return
	}

	if err := os.MkdirAll(filepath.Dir(resolved), 0o755); err != nil {
		writeErr(w, http.StatusInternalServerError, errorResponse{
			Error:     "files.mkdir_failed",
			Detail:    err.Error(),
			RequestID: rid,
		})
		return
	}

	dst, err := os.OpenFile(resolved, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, errorResponse{
			Error:     "files.open_dest_failed",
			Detail:    err.Error(),
			RequestID: rid,
		})
		return
	}
	defer dst.Close()

	hasher := sha256.New()
	mw := io.MultiWriter(dst, hasher)
	n, err := io.Copy(mw, file)
	if err != nil {
		_ = os.Remove(resolved)
		writeErr(w, http.StatusInternalServerError, errorResponse{
			Error:     "files.write_failed",
			Detail:    err.Error(),
			RequestID: rid,
		})
		return
	}

	_ = json.NewEncoder(w).Encode(PushResponse{
		OK:           true,
		BytesWritten: n,
		SHA256:       hex.EncodeToString(hasher.Sum(nil)),
		RemotePath:   resolved,
	})
}

func handlePull(w http.ResponseWriter, r *http.Request, roots []string) {
	rid := logging.RequestIDFromContext(r)

	remotePath := r.URL.Query().Get("remote_path")
	resolved, err := resolveAndAllowlist(remotePath, roots)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		writeErr(w, http.StatusForbidden, errorResponse{
			Error:     "files.path_outside_allowlist",
			Detail:    err.Error(),
			RequestID: rid,
		})
		return
	}

	st, err := os.Stat(resolved)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		writeErr(w, http.StatusNotFound, errorResponse{
			Error:     "files.path_not_found",
			Detail:    err.Error(),
			RequestID: rid,
		})
		return
	}
	if st.IsDir() {
		w.Header().Set("Content-Type", "application/json")
		writeErr(w, http.StatusBadRequest, errorResponse{
			Error:     "files.is_directory",
			Detail:    fmt.Sprintf("%q is a directory", remotePath),
			RequestID: rid,
		})
		return
	}

	f, err := os.Open(resolved)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		writeErr(w, http.StatusInternalServerError, errorResponse{
			Error:     "files.open_failed",
			Detail:    err.Error(),
			RequestID: rid,
		})
		return
	}
	defer f.Close()

	// Pre-compute the sha256 in a streaming pass so we can set X-SHA256 as a
	// regular response header (no HTTP trailers, which curl callers ignore by
	// default). The double read is acceptable: pull is bounded by /files/push
	// upload limits (100 MiB) and uses the local SSD.
	hasher := sha256.New()
	if _, err := io.Copy(hasher, f); err != nil {
		w.Header().Set("Content-Type", "application/json")
		writeErr(w, http.StatusInternalServerError, errorResponse{
			Error: "files.hash_failed", Detail: err.Error(), RequestID: rid,
		})
		return
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		w.Header().Set("Content-Type", "application/json")
		writeErr(w, http.StatusInternalServerError, errorResponse{
			Error: "files.seek_failed", Detail: err.Error(), RequestID: rid,
		})
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Filename", filepath.Base(resolved))
	w.Header().Set("X-SHA256", hex.EncodeToString(hasher.Sum(nil)))
	w.Header().Set("Content-Length", strconv.FormatInt(st.Size(), 10))
	_, _ = io.Copy(w, f)
}

func writeErr(w http.ResponseWriter, status int, body errorResponse) {
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
