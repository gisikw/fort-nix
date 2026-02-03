// Fort Upload - Simple file upload handler for the per-host fort service
//
// Accepts multipart/form-data uploads and drops files in /var/lib/fort/drops/
// with a timestamp prefix. VPN-only, no auth required.
//
// Runs as FastCGI behind nginx, socket-activated.

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/fcgi"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	dropsDir = "/var/lib/fort/drops"
)

type UploadHandler struct{}

type UploadResponse struct {
	Success  bool   `json:"success"`
	Path     string `json:"path,omitempty"`
	Filename string `json:"filename,omitempty"`
	Size     int64  `json:"size,omitempty"`
	Error    string `json:"error,omitempty"`
}

func main() {
	// Ensure drops directory exists
	if err := os.MkdirAll(dropsDir, 0755); err != nil {
		fmt.Fprintf(os.Stderr, "failed to create drops dir: %v\n", err)
		os.Exit(1)
	}

	handler := &UploadHandler{}

	// Socket activation: stdin is the connected socket
	listener, err := net.FileListener(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create listener from stdin: %v\n", err)
		os.Exit(1)
	}

	if err := fcgi.Serve(listener, handler); err != nil {
		fmt.Fprintf(os.Stderr, "fcgi serve error: %v\n", err)
		os.Exit(1)
	}
}

func (h *UploadHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method != http.MethodPost {
		h.errorResponse(w, http.StatusMethodNotAllowed, "only POST allowed")
		return
	}

	// Parse multipart form (32MB memory buffer, rest spills to disk)
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		h.errorResponse(w, http.StatusBadRequest, fmt.Sprintf("parse form failed: %v", err))
		return
	}

	// Get the uploaded file
	file, header, err := r.FormFile("file")
	if err != nil {
		h.errorResponse(w, http.StatusBadRequest, fmt.Sprintf("no file in request: %v", err))
		return
	}
	defer file.Close()

	// Generate timestamped filename
	origName := sanitizeFilename(header.Filename)
	timestamp := time.Now().Format("2006-01-02T15-04-05")
	destName := fmt.Sprintf("%s_%s", timestamp, origName)
	destPath := filepath.Join(dropsDir, destName)

	// Create destination file
	dst, err := os.Create(destPath)
	if err != nil {
		h.errorResponse(w, http.StatusInternalServerError, fmt.Sprintf("create file failed: %v", err))
		return
	}
	defer dst.Close()

	// Copy the uploaded content
	size, err := io.Copy(dst, file)
	if err != nil {
		os.Remove(destPath) // Clean up partial file
		h.errorResponse(w, http.StatusInternalServerError, fmt.Sprintf("write failed: %v", err))
		return
	}

	// Return success
	resp := UploadResponse{
		Success:  true,
		Path:     destPath,
		Filename: destName,
		Size:     size,
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(resp)

	fmt.Fprintf(os.Stderr, "[upload] saved %s (%d bytes)\n", destPath, size)
}

func (h *UploadHandler) errorResponse(w http.ResponseWriter, status int, message string) {
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(UploadResponse{
		Success: false,
		Error:   message,
	})
}

// sanitizeFilename removes path components and dangerous characters
func sanitizeFilename(name string) string {
	// Take only the base name (no directory components)
	name = filepath.Base(name)

	// Replace potentially problematic characters
	replacer := strings.NewReplacer(
		"/", "_",
		"\\", "_",
		"\x00", "",
		"..", "_",
	)
	name = replacer.Replace(name)

	// If empty after sanitization, use default
	if name == "" || name == "." {
		name = "unnamed"
	}

	return name
}
