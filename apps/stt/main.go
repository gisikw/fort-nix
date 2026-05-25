package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Injected at build time via ldflags
var (
	ffmpegPath  = "ffmpeg"
	whisperPath = "whisper-transcribe"
	listenAddr  = "127.0.0.1:8787"
)

type TranscribeResponse struct {
	Text  string `json:"text,omitempty"`
	Error string `json:"error,omitempty"`
}

func main() {
	http.HandleFunc("/transcribe", handleTranscribe)
	http.HandleFunc("/health", handleHealth)

	log.Printf("stt: listening on %s", listenAddr)
	if err := http.ListenAndServe(listenAddr, nil); err != nil {
		log.Fatalf("stt: server failed: %v", err)
	}
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"ok"}`))
}

func handleTranscribe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST required")
		return
	}

	// Parse multipart form — 32MB in memory, rest spills to disk
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Sprintf("invalid multipart form: %v", err))
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Sprintf("missing 'file' field: %v", err))
		return
	}
	defer file.Close()

	// Create temp directory for processing
	tmpDir, err := os.MkdirTemp("", "stt-*")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Sprintf("failed to create temp dir: %v", err))
		return
	}
	defer os.RemoveAll(tmpDir)

	// Save uploaded file
	inputPath := filepath.Join(tmpDir, filepath.Base(header.Filename))
	inputFile, err := os.Create(inputPath)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Sprintf("failed to save upload: %v", err))
		return
	}

	if _, err := inputFile.ReadFrom(file); err != nil {
		inputFile.Close()
		writeErr(w, http.StatusInternalServerError, fmt.Sprintf("failed to write upload: %v", err))
		return
	}
	inputFile.Close()

	log.Printf("stt: received %s (%d bytes)", header.Filename, header.Size)

	// Convert to WAV (whisper-cpp works best with 16kHz mono WAV)
	wavPath := filepath.Join(tmpDir, "audio.wav")
	ffCmd := exec.Command(ffmpegPath,
		"-i", inputPath,
		"-y",
		"-ar", "16000",
		"-ac", "1",
		"-c:a", "pcm_s16le",
		wavPath,
	)
	ffCmd.Stderr = os.Stderr
	if err := ffCmd.Run(); err != nil {
		writeErr(w, http.StatusUnprocessableEntity, fmt.Sprintf("ffmpeg conversion failed: %v", err))
		return
	}

	// Run whisper-transcribe
	log.Printf("stt: transcribing %s", header.Filename)
	wsCmd := exec.Command(whisperPath, "-f", wavPath)
	wsCmd.Dir = tmpDir
	wsCmd.Stderr = os.Stderr
	if err := wsCmd.Run(); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Sprintf("whisper failed: %v", err))
		return
	}

	// Read the output — whisper-transcribe writes to <input>.txt
	txtPath := wavPath + ".txt"
	txtContent, err := os.ReadFile(txtPath)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Sprintf("failed to read transcript: %v", err))
		return
	}

	text := strings.TrimSpace(string(txtContent))
	log.Printf("stt: completed %s (%d chars)", header.Filename, len(text))

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(TranscribeResponse{Text: text})
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	log.Printf("stt: error: %s", msg)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(TranscribeResponse{Error: msg})
}
