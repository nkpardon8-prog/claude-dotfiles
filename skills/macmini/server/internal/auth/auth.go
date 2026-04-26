package auth

import (
	"crypto/subtle"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
)

// TokenPtr holds the currently-active bearer token. It is hot-swapped atomically
// by /admin/rotate-token so no restart is needed when the token changes.
var TokenPtr atomic.Pointer[string]

// LoadToken reads the token from path, trims whitespace, and stores it into
// TokenPtr. Returns an error if the file is missing or empty so the server can
// fail loudly at startup.
func LoadToken(path string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read token file %q: %w", path, err)
	}
	tok := strings.TrimSpace(string(b))
	if tok == "" {
		return fmt.Errorf("token file %q is empty; run install.sh to generate one", path)
	}
	TokenPtr.Store(&tok)
	return nil
}

// SetToken installs a new in-memory token (used by /admin/rotate-token after a
// successful disk write).
func SetToken(tok string) error {
	tok = strings.TrimSpace(tok)
	if tok == "" {
		return errors.New("refusing to install empty token")
	}
	TokenPtr.Store(&tok)
	return nil
}

// Middleware verifies the Authorization: Bearer <token> header against the
// currently-loaded token using a constant-time compare. The header value is
// NEVER logged.
func Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		current := TokenPtr.Load()
		if current == nil || *current == "" {
			http.Error(w, `{"error":"unauthorized","detail":"server has no token loaded"}`, http.StatusUnauthorized)
			return
		}

		hdr := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if !strings.HasPrefix(hdr, prefix) {
			http.Error(w, `{"error":"unauthorized","detail":"missing or malformed Authorization header"}`, http.StatusUnauthorized)
			return
		}
		provided := hdr[len(prefix):]

		// crypto/subtle.ConstantTimeCompare returns int (1 = equal, 0 = not equal).
		if subtle.ConstantTimeCompare([]byte(provided), []byte(*current)) != 1 {
			http.Error(w, `{"error":"unauthorized","detail":"invalid token"}`, http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}
