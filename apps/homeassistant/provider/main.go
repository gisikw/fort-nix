package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

// Configuration - can be overridden via ldflags at build time
var webhookURL = "http://127.0.0.1:8123/api/webhook/fort-notify"

// HTTPClient interface for testing
type HTTPClient interface {
	Do(req *http.Request) (*http.Response, error)
}

var httpClient HTTPClient = &http.Client{
	Timeout: 10 * time.Second,
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

// processRequest handles the notification request
// Separated from main() for testability
func processRequest(input []byte) NotifyResponse {
	var req NotifyRequest
	if err := json.Unmarshal(input, &req); err != nil {
		return NotifyResponse{Error: fmt.Sprintf("invalid JSON: %v", err)}
	}

	if req.Message == "" {
		return NotifyResponse{Error: "message field is required"}
	}

	return sendNotification(req)
}

// sendNotification posts the request to the Home Assistant webhook
func sendNotification(req NotifyRequest) NotifyResponse {
	body, err := json.Marshal(req)
	if err != nil {
		return NotifyResponse{Error: fmt.Sprintf("failed to marshal request: %v", err)}
	}

	httpReq, err := http.NewRequest("POST", webhookURL, bytes.NewReader(body))
	if err != nil {
		return NotifyResponse{Error: fmt.Sprintf("failed to create request: %v", err)}
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := httpClient.Do(httpReq)
	if err != nil {
		return NotifyResponse{Error: fmt.Sprintf("webhook request failed: %v", err)}
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return NotifyResponse{Error: fmt.Sprintf("webhook returned %d", resp.StatusCode)}
	}

	return NotifyResponse{Status: "sent"}
}

// writeResponse marshals and writes the response to stdout
func writeResponse(resp NotifyResponse) {
	data, err := json.Marshal(resp)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to marshal response: %v\n", err)
		os.Exit(1)
	}
	os.Stdout.Write(data)
}

// writeError is a convenience for fatal errors before response processing
func writeError(msg string) {
	writeResponse(NotifyResponse{Error: msg})
}
