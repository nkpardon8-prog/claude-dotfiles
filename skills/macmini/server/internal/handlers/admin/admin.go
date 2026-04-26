package admin

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sync/atomic"

	"macmini-server/internal/auth"
	"macmini-server/internal/logging"
)

// RotateTokenResponse is returned EXACTLY ONCE per rotation; the new token is
// surfaced here because the caller has no other way to learn it. The caller is
// responsible for updating credentials.md / 1Password.
type RotateTokenResponse struct {
	OK             bool   `json:"ok"`
	NewToken       string `json:"new_token"`
	NewFingerprint string `json:"new_fingerprint"`
}

type errorResponse struct {
	Error     string `json:"error"`
	Detail    string `json:"detail"`
	RequestID string `json:"request_id"`
}

// Register installs POST /admin/rotate-token behind authMW. tokenPtr is the
// shared pointer used by auth.Middleware (auth.TokenPtr in main).
func Register(mux *http.ServeMux, authMW func(http.Handler) http.Handler, tokenPtr *atomic.Pointer[string], tokenPath string) {
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handleRotate(w, r, tokenPtr, tokenPath)
	})
	mux.Handle("POST /admin/rotate-token", authMW(h))
}

func handleRotate(w http.ResponseWriter, r *http.Request, tokenPtr *atomic.Pointer[string], tokenPath string) {
	rid := logging.RequestIDFromContext(r)
	w.Header().Set("Content-Type", "application/json")

	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse{
			Error: "admin.rand_failed", Detail: err.Error(), RequestID: rid,
		})
		return
	}
	// Use StdEncoding to match install.sh (`openssl rand -base64 32`).
	newToken := base64.StdEncoding.EncodeToString(raw[:])

	if err := atomicWriteToken(tokenPath, newToken); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse{
			Error: "admin.write_failed", Detail: err.Error(), RequestID: rid,
		})
		return
	}

	// Hot-swap the in-memory pointer using whichever pointer was supplied. We
	// also call auth.SetToken so any other reader of auth.TokenPtr sees the
	// new value (in main.go we always pass &auth.TokenPtr, so these align).
	if tokenPtr != nil {
		t := newToken
		tokenPtr.Store(&t)
	}
	if err := auth.SetToken(newToken); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse{
			Error: "admin.swap_failed", Detail: err.Error(), RequestID: rid,
		})
		return
	}

	sum := sha256.Sum256([]byte(newToken))
	fingerprint := hex.EncodeToString(sum[:])[:8]

	writeJSON(w, http.StatusOK, RotateTokenResponse{
		OK:             true,
		NewToken:       newToken,
		NewFingerprint: fingerprint,
	})
}

// atomicWriteToken writes to ${path}.tmp.<pid>, fsyncs, then renames. It also
// chmods to 600.
func atomicWriteToken(path, token string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("mkdir: %w", err)
	}
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("open tmp: %w", err)
	}
	if _, err := f.WriteString(token); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return fmt.Errorf("write: %w", err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return fmt.Errorf("fsync: %w", err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("close: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("rename: %w", err)
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
