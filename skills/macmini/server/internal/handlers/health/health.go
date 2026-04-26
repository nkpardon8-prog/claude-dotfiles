package health

import (
	"encoding/json"
	"net/http"
	"time"
)

// HealthResponse is intentionally minimal — no macos_version, no hostname.
// /health is unauthenticated, so the response must not leak privileged info.
type HealthResponse struct {
	OK            bool    `json:"ok"`
	Version       string  `json:"version"`
	UptimeSeconds float64 `json:"uptime_seconds"`
}

// Register installs GET /health on mux. NO auth middleware — intentionally.
func Register(mux *http.ServeMux, version string, startTime time.Time) {
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		resp := HealthResponse{
			OK:            true,
			Version:       version,
			UptimeSeconds: time.Since(startTime).Seconds(),
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	})
}
