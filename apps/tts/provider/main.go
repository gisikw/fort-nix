package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"time"
)

// Injected at build time via ldflags
var domain = "gisi.network"

const kokoroURL = "http://127.0.0.1:8880/v1/audio/speech"
const defaultVoice = "af_sky"
const defaultFormat = "mp3"

var httpClient = &http.Client{
	Timeout: 120 * time.Second,
}

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		writeError(fmt.Sprintf("failed to read stdin: %v", err))
		os.Exit(1)
	}

	req, err := validateRequest(input)
	if err != nil {
		writeError(err.Error())
		os.Exit(1)
	}

	// Respond with "accepted" before starting work
	writeResponse(TTSResponse{Status: "accepted"})

	// Close stdout so fort-provider knows we're done responding
	os.Stdout.Close()

	// Now do the actual work (process stays alive until complete)
	synthesize(req)
}

func validateRequest(input []byte) (*TTSRequest, error) {
	var req TTSRequest
	if err := json.Unmarshal(input, &req); err != nil {
		return nil, fmt.Errorf("invalid JSON: %v", err)
	}

	if req.Text == "" {
		return nil, fmt.Errorf("text field is required")
	}
	if req.Output.Host == "" {
		return nil, fmt.Errorf("output.host field is required")
	}
	if req.Output.Name == "" {
		return nil, fmt.Errorf("output.name field is required")
	}

	if req.Voice == "" {
		req.Voice = defaultVoice
	}
	if req.Format == "" {
		req.Format = defaultFormat
	}

	return &req, nil
}

func synthesize(req *TTSRequest) {
	fmt.Fprintf(os.Stderr, "[tts] generating speech: voice=%s format=%s text=%q\n",
		req.Voice, req.Format, truncate(req.Text, 80))

	// Call Kokoro API (OpenAI-compatible)
	body := map[string]interface{}{
		"model":           "kokoro",
		"voice":           req.Voice,
		"input":           req.Text,
		"response_format": req.Format,
	}

	bodyJSON, err := json.Marshal(body)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[tts] ERROR: failed to marshal request: %v\n", err)
		return
	}

	httpReq, err := http.NewRequest("POST", kokoroURL, bytes.NewReader(bodyJSON))
	if err != nil {
		fmt.Fprintf(os.Stderr, "[tts] ERROR: failed to create request: %v\n", err)
		return
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := httpClient.Do(httpReq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[tts] ERROR: kokoro request failed: %v\n", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		errBody, _ := io.ReadAll(resp.Body)
		fmt.Fprintf(os.Stderr, "[tts] ERROR: kokoro returned %d: %s\n", resp.StatusCode, string(errBody))
		return
	}

	audioData, err := io.ReadAll(resp.Body)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[tts] ERROR: failed to read audio response: %v\n", err)
		return
	}

	fmt.Fprintf(os.Stderr, "[tts] got %d bytes of audio, uploading to %s as %s\n",
		len(audioData), req.Output.Host, req.Output.Name)

	// Upload to target host
	uploadURL := fmt.Sprintf("https://%s.fort.%s/upload", req.Output.Host, domain)
	if err := uploadFile(uploadURL, req.Output.Name, audioData); err != nil {
		fmt.Fprintf(os.Stderr, "[tts] ERROR: upload failed: %v\n", err)
		return
	}

	fmt.Fprintf(os.Stderr, "[tts] completed: %s\n", req.Output.Name)
}

func uploadFile(url, filename string, content []byte) error {
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

func writeResponse(resp TTSResponse) {
	data, err := json.Marshal(resp)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to marshal response: %v\n", err)
		os.Exit(1)
	}
	os.Stdout.Write(data)
}

func writeError(msg string) {
	writeResponse(TTSResponse{Error: msg})
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
