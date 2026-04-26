package redact

import (
	"os"
	"strings"
)

// BuildRedactList returns substrings to scrub from any user-visible string
// (typically error messages). It pulls the Tailscale hostname from the
// CRD_MAC_MINI_HOSTNAME env var and includes obvious variants:
//   - the raw value
//   - the value with any trailing dot stripped
//   - the short form (everything before the first dot)
func BuildRedactList() []string {
	raw := strings.TrimSpace(os.Getenv("CRD_MAC_MINI_HOSTNAME"))
	if raw == "" {
		return nil
	}
	seen := map[string]struct{}{}
	out := []string{}
	add := func(s string) {
		if s == "" {
			return
		}
		if _, ok := seen[s]; ok {
			return
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	add(raw)
	trimmed := strings.TrimRight(raw, ".")
	add(trimmed)
	if i := strings.Index(trimmed, "."); i > 0 {
		add(trimmed[:i])
	}
	return out
}

// Scrub replaces every entry from BuildRedactList in s with the literal
// "<host>". Safe to call repeatedly.
func Scrub(s string) string {
	for _, h := range BuildRedactList() {
		s = strings.ReplaceAll(s, h, "<host>")
	}
	return s
}
