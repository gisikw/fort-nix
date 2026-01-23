package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const dropsDir = "/var/lib/fort/drops"

// Injected at build time via ldflags
var domain = "gisi.network"
var ffmpegPath = "ffmpeg"
var whisperPath = "whisper-transcribe"

var httpClient = &http.Client{
	Timeout: 60 * time.Second,
}

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		writeError(fmt.Sprintf("failed to read stdin: %v", err))
		os.Exit(1)
	}

	response := processRequest(input)
	writeResponse(response)

	if response.Error != "" {
		os.Exit(1)
	}
}

func processRequest(input []byte) TranscribeResponse {
	var req TranscribeRequest
	if err := json.Unmarshal(input, &req); err != nil {
		return TranscribeResponse{Error: fmt.Sprintf("invalid JSON: %v", err)}
	}

	if req.Name == "" {
		return TranscribeResponse{Error: "name field is required"}
	}
	if req.Output.Host == "" {
		return TranscribeResponse{Error: "output.host field is required"}
	}
	if req.Output.Name == "" {
		return TranscribeResponse{Error: "output.name field is required"}
	}

	// Sanitize filename to prevent path traversal
	safeName := filepath.Base(req.Name)
	if safeName != req.Name || strings.Contains(safeName, "..") {
		return TranscribeResponse{Error: "invalid filename"}
	}

	sourcePath := filepath.Join(dropsDir, safeName)
	if _, err := os.Stat(sourcePath); os.IsNotExist(err) {
		return TranscribeResponse{Error: fmt.Sprintf("file not found: %s", safeName)}
	}

	return transcribe(sourcePath, safeName, req.Output)
}

func transcribe(sourcePath, sourceName string, output OutputTarget) TranscribeResponse {
	// Create temp directory for processing
	tmpDir, err := os.MkdirTemp("", "transcribe-*")
	if err != nil {
		return TranscribeResponse{Error: fmt.Sprintf("failed to create temp dir: %v", err)}
	}
	defer os.RemoveAll(tmpDir)

	// Convert to mp3 (whisper works best with mp3/wav)
	mp3Path := filepath.Join(tmpDir, "audio.mp3")
	fmt.Fprintf(os.Stderr, "[transcribe] converting %s to mp3\n", sourceName)

	ffCmd := exec.Command(ffmpegPath, "-i", sourcePath, "-y", "-vn", "-acodec", "libmp3lame", "-q:a", "2", mp3Path)
	ffCmd.Stderr = os.Stderr
	if err := ffCmd.Run(); err != nil {
		return TranscribeResponse{Error: fmt.Sprintf("ffmpeg conversion failed: %v", err)}
	}

	// Run whisper-transcribe
	fmt.Fprintf(os.Stderr, "[transcribe] running whisper on %s\n", mp3Path)

	// whisper-transcribe outputs to audio.mp3.txt in same directory
	wsCmd := exec.Command(whisperPath, "-f", mp3Path)
	wsCmd.Dir = tmpDir
	wsCmd.Stderr = os.Stderr
	if err := wsCmd.Run(); err != nil {
		return TranscribeResponse{Error: fmt.Sprintf("whisper-transcribe failed: %v", err)}
	}

	// Read the output
	txtPath := mp3Path + ".txt"
	txtContent, err := os.ReadFile(txtPath)
	if err != nil {
		// Whisper failed silently - write error message
		txtContent = []byte(fmt.Sprintf("Transcription failed: could not read output file: %v", err))
	}

	// Upload to target host
	fmt.Fprintf(os.Stderr, "[transcribe] uploading result to %s as %s\n", output.Host, output.Name)

	uploadURL := fmt.Sprintf("https://%s.fort.%s/upload", output.Host, domain)
	if err := uploadFile(uploadURL, output.Name, txtContent); err != nil {
		return TranscribeResponse{Error: fmt.Sprintf("upload failed: %v", err)}
	}

	// Clean up source file from drops
	fmt.Fprintf(os.Stderr, "[transcribe] cleaning up %s\n", sourcePath)
	os.Remove(sourcePath)

	return TranscribeResponse{
		Status:   "completed",
		Filename: output.Name,
	}
}

func uploadFile(url, filename string, content []byte) error {
	// Create multipart form
	var buf bytes.Buffer
	writer := multipart.NewWriter(&buf)

	part, err := writer.CreateFormFile("file", filename)
	if err != nil {
		return fmt.Errorf("create form file: %w", err)
	}

	if _, err := part.Write(content); err != nil {
		return fmt.Errorf("write content: %w", err)
	}

	if err := writer.Close(); err != nil {
		return fmt.Errorf("close writer: %w", err)
	}

	// Send request
	req, err := http.NewRequest("POST", url, &buf)
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", writer.FormDataContentType())

	resp, err := httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("http request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("upload returned %d: %s", resp.StatusCode, string(body))
	}

	return nil
}

func writeResponse(resp TranscribeResponse) {
	data, err := json.Marshal(resp)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to marshal response: %v\n", err)
		os.Exit(1)
	}
	os.Stdout.Write(data)
}

func writeError(msg string) {
	writeResponse(TranscribeResponse{Error: msg})
}
