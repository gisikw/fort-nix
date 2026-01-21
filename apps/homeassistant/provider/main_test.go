package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"testing"
)

// mockHTTPClient implements HTTPClient for testing
type mockHTTPClient struct {
	response *http.Response
	err      error
	// Capture the request for inspection
	lastRequest *http.Request
	lastBody    []byte
}

func (m *mockHTTPClient) Do(req *http.Request) (*http.Response, error) {
	m.lastRequest = req
	if req.Body != nil {
		m.lastBody, _ = io.ReadAll(req.Body)
	}
	return m.response, m.err
}

func mockResponse(statusCode int, body string) *http.Response {
	return &http.Response{
		StatusCode: statusCode,
		Body:       io.NopCloser(bytes.NewBufferString(body)),
		Header:     make(http.Header),
	}
}

// --- JSON Parsing Tests ---

func TestProcessRequest_ValidJSON(t *testing.T) {
	mock := &mockHTTPClient{response: mockResponse(200, "")}
	httpClient = mock

	input := []byte(`{"message": "test notification"}`)
	resp := processRequest(input)

	if resp.Error != "" {
		t.Errorf("unexpected error: %s", resp.Error)
	}
	if resp.Status != "sent" {
		t.Errorf("expected status 'sent', got '%s'", resp.Status)
	}
}

func TestProcessRequest_InvalidJSON(t *testing.T) {
	input := []byte(`{not valid json}`)
	resp := processRequest(input)

	if resp.Error == "" {
		t.Error("expected error for invalid JSON")
	}
	if resp.Status != "" {
		t.Errorf("expected empty status on error, got '%s'", resp.Status)
	}
}

func TestProcessRequest_EmptyInput(t *testing.T) {
	input := []byte(``)
	resp := processRequest(input)

	if resp.Error == "" {
		t.Error("expected error for empty input")
	}
}

// --- Validation Tests ---

func TestProcessRequest_MissingMessage(t *testing.T) {
	input := []byte(`{"title": "Hello"}`)
	resp := processRequest(input)

	if resp.Error != "message field is required" {
		t.Errorf("expected 'message field is required', got '%s'", resp.Error)
	}
}

func TestProcessRequest_EmptyMessage(t *testing.T) {
	input := []byte(`{"message": ""}`)
	resp := processRequest(input)

	if resp.Error != "message field is required" {
		t.Errorf("expected 'message field is required', got '%s'", resp.Error)
	}
}

func TestProcessRequest_WhitespaceOnlyMessage(t *testing.T) {
	// Whitespace-only is technically valid - the field is present and non-empty
	// Home Assistant can decide if it wants to reject it
	mock := &mockHTTPClient{response: mockResponse(200, "")}
	httpClient = mock

	input := []byte(`{"message": "   "}`)
	resp := processRequest(input)

	if resp.Error != "" {
		t.Errorf("whitespace message should be accepted: %s", resp.Error)
	}
}

// --- HTTP Success Tests ---

func TestProcessRequest_FullRequest(t *testing.T) {
	mock := &mockHTTPClient{response: mockResponse(200, "")}
	httpClient = mock

	input := []byte(`{
		"title": "Alert",
		"message": "Something happened",
		"url": "https://example.com",
		"actions": [
			{"action": "OPEN", "title": "Open App"},
			{"action": "DISMISS", "title": "Dismiss", "uri": "https://example.com/dismiss"}
		]
	}`)
	resp := processRequest(input)

	if resp.Error != "" {
		t.Errorf("unexpected error: %s", resp.Error)
	}
	if resp.Status != "sent" {
		t.Errorf("expected status 'sent', got '%s'", resp.Status)
	}

	// Verify the request was forwarded correctly
	if mock.lastRequest == nil {
		t.Fatal("no request was made")
	}
	if mock.lastRequest.Method != "POST" {
		t.Errorf("expected POST, got %s", mock.lastRequest.Method)
	}
	if mock.lastRequest.Header.Get("Content-Type") != "application/json" {
		t.Errorf("expected application/json content type")
	}

	// Verify body was forwarded
	var forwarded NotifyRequest
	if err := json.Unmarshal(mock.lastBody, &forwarded); err != nil {
		t.Fatalf("failed to parse forwarded body: %v", err)
	}
	if forwarded.Title != "Alert" {
		t.Errorf("title not forwarded correctly")
	}
	if forwarded.Message != "Something happened" {
		t.Errorf("message not forwarded correctly")
	}
	if len(forwarded.Actions) != 2 {
		t.Errorf("expected 2 actions, got %d", len(forwarded.Actions))
	}
}

// --- HTTP Error Tests ---

func TestProcessRequest_HTTP500(t *testing.T) {
	mock := &mockHTTPClient{response: mockResponse(500, "Internal Server Error")}
	httpClient = mock

	input := []byte(`{"message": "test"}`)
	resp := processRequest(input)

	if resp.Error != "webhook returned 500" {
		t.Errorf("expected 'webhook returned 500', got '%s'", resp.Error)
	}
	if resp.Status != "" {
		t.Errorf("expected empty status on error")
	}
}

func TestProcessRequest_HTTP404(t *testing.T) {
	mock := &mockHTTPClient{response: mockResponse(404, "Not Found")}
	httpClient = mock

	input := []byte(`{"message": "test"}`)
	resp := processRequest(input)

	if resp.Error != "webhook returned 404" {
		t.Errorf("expected 'webhook returned 404', got '%s'", resp.Error)
	}
}

func TestProcessRequest_HTTP401(t *testing.T) {
	mock := &mockHTTPClient{response: mockResponse(401, "Unauthorized")}
	httpClient = mock

	input := []byte(`{"message": "test"}`)
	resp := processRequest(input)

	if resp.Error != "webhook returned 401" {
		t.Errorf("expected 'webhook returned 401', got '%s'", resp.Error)
	}
}

func TestProcessRequest_ConnectionError(t *testing.T) {
	mock := &mockHTTPClient{
		response: nil,
		err:      errors.New("connection refused"),
	}
	httpClient = mock

	input := []byte(`{"message": "test"}`)
	resp := processRequest(input)

	if resp.Error == "" {
		t.Error("expected error for connection failure")
	}
	if resp.Status != "" {
		t.Error("expected empty status on connection error")
	}
}

func TestProcessRequest_Timeout(t *testing.T) {
	mock := &mockHTTPClient{
		response: nil,
		err:      errors.New("context deadline exceeded"),
	}
	httpClient = mock

	input := []byte(`{"message": "test"}`)
	resp := processRequest(input)

	if resp.Error == "" {
		t.Error("expected error for timeout")
	}
}

// --- Response Format Tests ---

func TestNotifyResponse_SuccessJSON(t *testing.T) {
	resp := NotifyResponse{Status: "sent"}
	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("failed to marshal: %v", err)
	}

	// Verify omitempty works - error field should be absent
	var parsed map[string]interface{}
	json.Unmarshal(data, &parsed)

	if parsed["status"] != "sent" {
		t.Errorf("expected status 'sent'")
	}
	if _, exists := parsed["error"]; exists {
		t.Error("error field should be omitted when empty")
	}
}

func TestNotifyResponse_ErrorJSON(t *testing.T) {
	resp := NotifyResponse{Error: "something went wrong"}
	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("failed to marshal: %v", err)
	}

	var parsed map[string]interface{}
	json.Unmarshal(data, &parsed)

	if parsed["error"] != "something went wrong" {
		t.Errorf("expected error message")
	}
	if _, exists := parsed["status"]; exists {
		t.Error("status field should be omitted when empty")
	}
}

// --- Type Tests ---

func TestNotifyRequest_AllFields(t *testing.T) {
	req := NotifyRequest{
		Title:   "Test Title",
		Message: "Test Message",
		URL:     "https://example.com",
		Actions: []NotifyAction{
			{Action: "open", Title: "Open", URI: "app://open"},
		},
	}

	data, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("failed to marshal: %v", err)
	}

	var parsed NotifyRequest
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("failed to unmarshal: %v", err)
	}

	if parsed.Title != req.Title {
		t.Error("title mismatch")
	}
	if parsed.Message != req.Message {
		t.Error("message mismatch")
	}
	if parsed.URL != req.URL {
		t.Error("url mismatch")
	}
	if len(parsed.Actions) != 1 {
		t.Error("actions mismatch")
	}
	if parsed.Actions[0].URI != "app://open" {
		t.Error("action uri mismatch")
	}
}

func TestNotifyRequest_MinimalFields(t *testing.T) {
	// Only message is required
	input := []byte(`{"message": "hello"}`)

	var req NotifyRequest
	if err := json.Unmarshal(input, &req); err != nil {
		t.Fatalf("failed to unmarshal: %v", err)
	}

	if req.Message != "hello" {
		t.Error("message not parsed")
	}
	if req.Title != "" {
		t.Error("title should be empty")
	}
	if req.Actions != nil {
		t.Error("actions should be nil")
	}
}
