package redact

import (
	"encoding/json"
	"log/slog"
	"os"
	"os/exec"
	"strings"
)

// BuildRedactList returns a list of strings to scrub from /run output. Sources:
//   - tailscale status --json: Self.HostName, Self.DNSName (TrimSuffix "."),
//     Self.TailscaleIPs (filtered to IPv4 — entries containing ".").
//   - os.Hostname()
//   - scutil --get LocalHostName
//
// Any individual lookup failure logs a warning via slog and is skipped — the
// rest of the list is still returned.
func BuildRedactList() []string {
	out := []string{}
	seen := map[string]struct{}{}
	add := func(s string) {
		s = strings.TrimSpace(s)
		if s == "" {
			return
		}
		if _, ok := seen[s]; ok {
			return
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}

	// tailscale status --json — try several known binary locations.
	tsPaths := []string{
		"/usr/local/bin/tailscale",
		"/opt/homebrew/bin/tailscale",
		"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
	}
	var tsJSON []byte
	for _, p := range tsPaths {
		if _, err := os.Stat(p); err == nil {
			b, err := exec.Command(p, "status", "--json").Output()
			if err == nil {
				tsJSON = b
				break
			}
			slog.Warn("redact: tailscale status failed", slog.String("path", p), slog.String("err", err.Error()))
		}
	}
	if tsJSON != nil {
		var parsed struct {
			Self struct {
				HostName     string   `json:"HostName"`
				DNSName      string   `json:"DNSName"`
				TailscaleIPs []string `json:"TailscaleIPs"`
			} `json:"Self"`
		}
		if err := json.Unmarshal(tsJSON, &parsed); err == nil {
			add(parsed.Self.HostName)
			add(strings.TrimSuffix(parsed.Self.DNSName, "."))
			for _, ip := range parsed.Self.TailscaleIPs {
				// IPv4 only — IPv4 entries contain ".".
				if strings.Contains(ip, ".") {
					add(ip)
				}
			}
		} else {
			slog.Warn("redact: tailscale json parse failed", slog.String("err", err.Error()))
		}
	}

	if h, err := os.Hostname(); err == nil {
		add(h)
		// Strip trailing ".local" suffix common on macOS.
		add(strings.TrimSuffix(h, ".local"))
	} else {
		slog.Warn("redact: os.Hostname failed", slog.String("err", err.Error()))
	}

	if b, err := exec.Command("/usr/sbin/scutil", "--get", "LocalHostName").Output(); err == nil {
		add(strings.TrimSpace(string(b)))
	} else {
		slog.Warn("redact: scutil LocalHostName failed", slog.String("err", err.Error()))
	}

	return out
}

// Scrub replaces every entry of list with "<host>" in s. The input list is
// applied longest-first so that prefix overlaps don't corrupt longer matches.
func Scrub(s string, list []string) string {
	if s == "" || len(list) == 0 {
		return s
	}
	// Sort by length descending in-place via a copy.
	sorted := make([]string, len(list))
	copy(sorted, list)
	for i := 1; i < len(sorted); i++ {
		for j := i; j > 0 && len(sorted[j]) > len(sorted[j-1]); j-- {
			sorted[j], sorted[j-1] = sorted[j-1], sorted[j]
		}
	}
	for _, needle := range sorted {
		if needle == "" {
			continue
		}
		s = strings.ReplaceAll(s, needle, "<host>")
	}
	return s
}
