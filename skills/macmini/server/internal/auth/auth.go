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
			writeUnauth(w, "server has no token loaded")
			return
		}

		hdr := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if !strings.HasPrefix(hdr, prefix) {
			writeUnauth(w, "missing or malformed Authorization header")
			return
		}
		provided := hdr[len(prefix):]

		// crypto/subtle.ConstantTimeCompare returns int (1 = equal, 0 = not equal).
		if subtle.ConstantTimeCompare([]byte(provided), []byte(*current)) != 1 {
			writeUnauth(w, "invalid token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeUnauth(w http.ResponseWriter, detail string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusUnauthorized)
	// Hand-build the JSON to avoid pulling encoding/json into auth — keeps the
	// auth middleware a tight stdlib leaf.
	body := `{"error":"unauthorized","detail":` + jsonString(detail) + `}`
	_, _ = w.Write([]byte(body))
}

// jsonString returns a JSON-quoted form of s. Only escapes the characters that
// must be escaped in a JSON string literal.
func jsonString(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '\\':
			b.WriteString(`\\`)
		case '"':
			b.WriteString(`\"`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if r < 0x20 {
				b.WriteString(`\u00`)
				const hexd = "0123456789abcdef"
				b.WriteByte(hexd[r>>4])
				b.WriteByte(hexd[r&0xF])
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}
