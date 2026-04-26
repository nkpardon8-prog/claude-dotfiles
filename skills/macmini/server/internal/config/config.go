package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Version is set at build-time via -ldflags "-X macmini-server/internal/config.Version=..."
var Version = "dev"

// Config holds cross-cutting server configuration. Per-handler policy lives in
// the handler package, not here.
type Config struct {
	ListenAddr string
	TokenPath  string
	LogPath    string
	Version    string
	StartTime  time.Time
}

// Load reads config from environment variables and applies defaults. It refuses
// to start if MACMINI_LISTEN_ADDR is unset — this prevents accidental 0.0.0.0
// bind, by construction.
func Load() (*Config, error) {
	listen := strings.TrimSpace(os.Getenv("MACMINI_LISTEN_ADDR"))
	if listen == "" {
		return nil, fmt.Errorf("MACMINI_LISTEN_ADDR is required (set by install.sh to TS_IP:8765); refusing to start to prevent 0.0.0.0 bind")
	}

	tokenPath := strings.TrimSpace(os.Getenv("MACMINI_TOKEN_PATH"))
	if tokenPath == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, fmt.Errorf("user home dir: %w", err)
		}
		tokenPath = filepath.Join(home, ".config", "macmini-server", "token")
	}
	tokenPath = expandHome(tokenPath)

	logPath := strings.TrimSpace(os.Getenv("MACMINI_LOG_PATH"))
	if logPath == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, fmt.Errorf("user home dir: %w", err)
		}
		logPath = filepath.Join(home, "Library", "Logs", "macmini-server.log")
	}
	logPath = expandHome(logPath)

	return &Config{
		ListenAddr: listen,
		TokenPath:  tokenPath,
		LogPath:    logPath,
		Version:    Version,
		StartTime:  time.Now(),
	}, nil
}

// ExpandHome expands a leading "~/" or bare "~" to the current user's home dir.
func ExpandHome(p string) string { return expandHome(p) }

func expandHome(p string) string {
	if p == "" {
		return p
	}
	if p == "~" {
		if home, err := os.UserHomeDir(); err == nil {
			return home
		}
		return p
	}
	if strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, p[2:])
		}
	}
	return p
}
