package shot

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"

	"macmini-server/internal/logging"
)

type errorResponse struct {
	Error     string `json:"error"`
	Detail    string `json:"detail"`
	RequestID string `json:"request_id"`
}

// pngSig is the 8-byte PNG file signature.
var pngSig = []byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}

// Register installs POST /shot behind authMW.
func Register(mux *http.ServeMux, authMW func(http.Handler) http.Handler) {
	h := http.HandlerFunc(handleShot)
	mux.Handle("POST /shot", authMW(h))
}

func handleShot(w http.ResponseWriter, r *http.Request) {
	rid := logging.RequestIDFromContext(r)

	tmp := filepath.Join("/tmp", "macmini-shot-"+randHex(16)+".png")
	defer os.Remove(tmp)

	cmd := exec.Command("/usr/sbin/screencapture", "-x", "-t", "png", tmp)
	if err := cmd.Run(); err != nil {
		w.Header().Set("Content-Type", "application/json")
		writeJSON(w, http.StatusInternalServerError, errorResponse{
			Error:     "shot.screencapture_failed",
			Detail:    err.Error(),
			RequestID: rid,
		})
		return
	}

	data, err := os.ReadFile(tmp)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		writeJSON(w, http.StatusInternalServerError, errorResponse{
			Error:     "shot.read_failed",
			Detail:    err.Error(),
			RequestID: rid,
		})
		return
	}

	width, height, ok := parsePNGDimensions(data)
	if !ok {
		w.Header().Set("Content-Type", "application/json")
		writeJSON(w, http.StatusInternalServerError, errorResponse{
			Error:     "shot.invalid_png",
			Detail:    "screencapture produced a non-PNG payload",
			RequestID: rid,
		})
		return
	}

	if isLikelyBlack(data) {
		w.Header().Set("Content-Type", "application/json")
		writeJSON(w, http.StatusForbidden, errorResponse{
			Error: "shot.permission_denied",
			Detail: "Open System Settings > Privacy & Security > Screen Recording, " +
				"enable /usr/local/bin/macmini-server, then run: " +
				"launchctl kickstart -k gui/$(id -u)/com.macmini-skill.server",
			RequestID: rid,
		})
		return
	}

	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("X-Width", strconv.Itoa(width))
	w.Header().Set("X-Height", strconv.Itoa(height))
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	_, _ = io.Copy(w, bytesReader(data))
}

func bytesReader(b []byte) io.Reader { return &readerAt{b: b} }

type readerAt struct {
	b []byte
	i int
}

func (r *readerAt) Read(p []byte) (int, error) {
	if r.i >= len(r.b) {
		return 0, io.EOF
	}
	n := copy(p, r.b[r.i:])
	r.i += n
	return n, nil
}

func randHex(nBytes int) string {
	b := make([]byte, nBytes)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("%x", os.Getpid())
	}
	return hex.EncodeToString(b)
}

// parsePNGDimensions reads the PNG IHDR chunk (first 24 bytes) and returns the
// image's width, height, and whether parsing succeeded.
//
// PNG layout (relevant bytes):
//
//	[0..7]   PNG signature
//	[8..11]  IHDR length (always 13)
//	[12..15] "IHDR"
//	[16..19] width  (BE uint32)
//	[20..23] height (BE uint32)
func parsePNGDimensions(data []byte) (int, int, bool) {
	if len(data) < 24 {
		return 0, 0, false
	}
	for i, b := range pngSig {
		if data[i] != b {
			return 0, 0, false
		}
	}
	if string(data[12:16]) != "IHDR" {
		return 0, 0, false
	}
	w := binary.BigEndian.Uint32(data[16:20])
	h := binary.BigEndian.Uint32(data[20:24])
	return int(w), int(h), true
}

// isLikelyBlack samples the first ~100 pixels of raw PNG payload bytes (an
// extremely cheap check; we don't decompress IDAT). A genuinely black image
// produced by Screen Recording denial has near-zero entropy, so checking that
// the first chunk after IHDR is overwhelmingly low-byte is a reasonable
// approximation. False positives on extremely dark wallpapers are tolerable —
// the user can re-grant Screen Recording and retry.
func isLikelyBlack(data []byte) bool {
	if len(data) < 256 {
		return true
	}
	// Skip the first 8 bytes (signature) + IHDR (25 bytes incl. CRC) ~= 33.
	// Sample the next 100 bytes of the first IDAT block.
	sample := data[33:]
	if len(sample) > 100 {
		sample = sample[:100]
	}
	var sum int
	for _, b := range sample {
		sum += int(b)
	}
	mean := float64(sum) / float64(len(sample))
	return mean < 4.0
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
