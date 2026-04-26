package paste

import (
	"encoding/json"
	"net/http"
	"os/exec"
	"strings"

	"macmini-server/internal/logging"
)

// PasteRequest is bounded to 1 MiB by MaxBytesReader before Unmarshal runs.
type PasteRequest struct {
	Text string `json:"text"`
}

type PasteResponse struct {
	OK           bool `json:"ok"`
	BytesWritten int  `json:"bytes_written"`
}

// errorResponse is the common error envelope.
type errorResponse struct {
	Error     string `json:"error"`
	Detail    string `json:"detail"`
	RequestID string `json:"request_id"`
}

const maxPasteBytes int64 = 1 << 20 // 1 MiB

// Register installs POST /paste on mux behind authMW.
func Register(mux *http.ServeMux, authMW func(http.Handler) http.Handler) {
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rid := logging.RequestIDFromContext(r)
		w.Header().Set("Content-Type", "application/json")

		r.Body = http.MaxBytesReader(w, r.Body, maxPasteBytes)
		var req PasteRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, errorResponse{
				Error:     "paste.bad_request",
				Detail:    err.Error(),
				RequestID: rid,
			})
			return
		}

		// /usr/bin/pbcopy is text-only and stdlib for macOS.
		cmd := exec.Command("/usr/bin/pbcopy")
		cmd.Stdin = strings.NewReader(req.Text)
		if err := cmd.Run(); err != nil {
			writeErr(w, http.StatusInternalServerError, errorResponse{
				Error:     "paste.pbcopy_failed",
				Detail:    err.Error(),
				RequestID: rid,
			})
			return
		}

		_ = json.NewEncoder(w).Encode(PasteResponse{
			OK:           true,
			BytesWritten: len(req.Text),
		})
	})
	mux.Handle("POST /paste", authMW(h))
}

func writeErr(w http.ResponseWriter, status int, body errorResponse) {
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
