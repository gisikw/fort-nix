package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

// Injected at build time
var (
	listenAddr       = ":8882"
	backendURL       = "http://127.0.0.1:8880"
	refAudioPath     = ""
	refTranscriptPath = ""
)

var (
	refAudioDataURI string
	refTranscript   string
	httpClient      = &http.Client{Timeout: 300 * time.Second}
)

// Request from the caller — just text and optional format
type SpeechRequest struct {
	Input          string `json:"input"`
	ResponseFormat string `json:"response_format,omitempty"`
}

// Full request sent to the groxaxo backend
type BackendRequest struct {
	Model          string `json:"model"`
	Voice          string `json:"voice"`
	Input          string `json:"input"`
	ResponseFormat string `json:"response_format"`
	TaskType       string `json:"task_type"`
	RefAudio       string `json:"ref_audio"`
	RefText        string `json:"ref_text"`
	Language       string `json:"language"`
}

func main() {
	if err := loadReference(); err != nil {
		log.Fatalf("failed to load reference data: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/audio/speech", handleSpeech)
	mux.HandleFunc("/health", handleHealth)

	log.Printf("exo-tts proxy listening on %s (backend: %s)", listenAddr, backendURL)
	log.Fatal(http.ListenAndServe(listenAddr, mux))
}

func loadReference() error {
	audioBytes, err := os.ReadFile(refAudioPath)
	if err != nil {
		return fmt.Errorf("read ref audio %s: %w", refAudioPath, err)
	}
	b64 := base64.StdEncoding.EncodeToString(audioBytes)
	refAudioDataURI = "data:audio/wav;base64," + b64
	log.Printf("loaded reference audio: %d bytes -> %d base64 chars", len(audioBytes), len(b64))

	transcriptBytes, err := os.ReadFile(refTranscriptPath)
	if err != nil {
		return fmt.Errorf("read ref transcript %s: %w", refTranscriptPath, err)
	}
	refTranscript = strings.TrimSpace(string(transcriptBytes))
	log.Printf("loaded reference transcript: %q", refTranscript)

	return nil
}

func handleSpeech(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "failed to read request body", http.StatusBadRequest)
		return
	}

	var req SpeechRequest
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, fmt.Sprintf("invalid JSON: %v", err), http.StatusBadRequest)
		return
	}

	if req.Input == "" {
		http.Error(w, "input field is required", http.StatusBadRequest)
		return
	}

	format := req.ResponseFormat
	if format == "" {
		format = "mp3"
	}

	log.Printf("synthesizing: format=%s text=%q", format, truncate(req.Input, 80))

	backendReq := BackendRequest{
		Model:          "tts-1",
		Voice:          "alloy",
		Input:          req.Input,
		ResponseFormat: format,
		TaskType:       "Base",
		RefAudio:       refAudioDataURI,
		RefText:        refTranscript,
		Language:       "English",
	}

	reqJSON, err := json.Marshal(backendReq)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	httpReq, err := http.NewRequest("POST", backendURL+"/v1/audio/speech", bytes.NewReader(reqJSON))
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := httpClient.Do(httpReq)
	if err != nil {
		log.Printf("backend error: %v", err)
		http.Error(w, fmt.Sprintf("backend error: %v", err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// Forward content type and status from backend
	for k, v := range resp.Header {
		for _, vv := range v {
			w.Header().Add(k, vv)
		}
	}
	w.WriteHeader(resp.StatusCode)

	n, err := io.Copy(w, resp.Body)
	if err != nil {
		log.Printf("error streaming response: %v", err)
		return
	}

	log.Printf("completed: %d bytes, format=%s", n, format)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"ok"}`))
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
