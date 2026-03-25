package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"
)

// Injected at build time via ldflags
var (
	backendURL = "http://127.0.0.1:8880/v1/audio/speech"
	listenAddr = "127.0.0.1:8788"
)

const defaultVoice = "af_bella"
const defaultFormat = "mp3"

var httpClient = &http.Client{
	Timeout: 120 * time.Second,
}

type SynthesizeRequest struct {
	Text   string `json:"text"`
	Voice  string `json:"voice,omitempty"`
	Format string `json:"format,omitempty"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

func main() {
	http.HandleFunc("/synthesize", handleSynthesize)
	http.HandleFunc("/health", handleHealth)

	log.Printf("tts-http: listening on %s", listenAddr)
	if err := http.ListenAndServe(listenAddr, nil); err != nil {
		log.Fatalf("tts-http: server failed: %v", err)
	}
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"ok"}`))
}

func handleSynthesize(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST required")
		return
	}

	var req SynthesizeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Sprintf("invalid JSON: %v", err))
		return
	}

	if req.Text == "" {
		writeErr(w, http.StatusBadRequest, "text field is required")
		return
	}
	if req.Voice == "" {
		req.Voice = defaultVoice
	}
	if req.Format == "" {
		req.Format = defaultFormat
	}

	contentType := formatToContentType(req.Format)
	if contentType == "" {
		writeErr(w, http.StatusBadRequest, fmt.Sprintf("unsupported format: %s (use mp3, wav, or opus)", req.Format))
		return
	}

	log.Printf("tts-http: synthesizing voice=%s format=%s text=%q", req.Voice, req.Format, truncate(req.Text, 80))

	// Call TTS backend (currently Kokoro, but this is the indirection point)
	body := map[string]interface{}{
		"model":           "kokoro",
		"voice":           req.Voice,
		"input":           req.Text,
		"response_format": req.Format,
	}
	bodyJSON, err := json.Marshal(body)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Sprintf("failed to marshal request: %v", err))
		return
	}

	backendReq, err := http.NewRequest("POST", backendURL, bytes.NewReader(bodyJSON))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Sprintf("failed to create backend request: %v", err))
		return
	}
	backendReq.Header.Set("Content-Type", "application/json")

	resp, err := httpClient.Do(backendReq)
	if err != nil {
		writeErr(w, http.StatusBadGateway, fmt.Sprintf("backend request failed: %v", err))
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		errBody, _ := io.ReadAll(resp.Body)
		writeErr(w, http.StatusBadGateway, fmt.Sprintf("backend returned %d: %s", resp.StatusCode, string(errBody)))
		return
	}

	w.Header().Set("Content-Type", contentType)
	n, err := io.Copy(w, resp.Body)
	if err != nil {
		log.Printf("tts-http: error streaming response: %v", err)
		return
	}
	log.Printf("tts-http: completed (%d bytes)", n)
}

func formatToContentType(format string) string {
	switch format {
	case "mp3":
		return "audio/mpeg"
	case "wav":
		return "audio/wav"
	case "opus":
		return "audio/opus"
	default:
		return ""
	}
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	log.Printf("tts-http: error: %s", msg)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(ErrorResponse{Error: msg})
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
