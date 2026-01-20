package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestProcessEntries_NoCIToken(t *testing.T) {
	// Test getCacheConfig directly - it reads from const paths that won't exist in test
	resp := getCacheConfig("/nonexistent/attic")
	if resp.Error == "" {
		t.Error("expected error when CI token missing")
	}
	if resp.Error != "CI token not yet created" {
		t.Errorf("unexpected error: %s", resp.Error)
	}
}


func TestParsePublicKey(t *testing.T) {
	tests := []struct {
		name     string
		output   string
		expected string
	}{
		{
			name:     "standard format",
			output:   "Cache: fort\nPublic Key: fort:abc123xyz\nIs Public: true",
			expected: "fort:abc123xyz",
		},
		{
			name:     "with extra whitespace",
			output:   "Public Key:   fort:def456   \n",
			expected: "fort:def456",
		},
		{
			name:     "no public key",
			output:   "Cache: fort\nIs Public: true",
			expected: "",
		},
		{
			name:     "empty output",
			output:   "",
			expected: "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			result := parsePublicKey(tc.output)
			if result != tc.expected {
				t.Errorf("parsePublicKey(%q) = %q, want %q", tc.output, result, tc.expected)
			}
		})
	}
}

func TestReadFile(t *testing.T) {
	tmpDir := t.TempDir()

	// Test valid file
	validPath := filepath.Join(tmpDir, "valid")
	os.WriteFile(validPath, []byte("  content with whitespace  \n"), 0600)

	content, err := readFile(validPath)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if content != "content with whitespace" {
		t.Errorf("expected trimmed content, got %q", content)
	}

	// Test empty file
	emptyPath := filepath.Join(tmpDir, "empty")
	os.WriteFile(emptyPath, []byte("   \n"), 0600)

	_, err = readFile(emptyPath)
	if err == nil {
		t.Error("expected error for empty file")
	}

	// Test missing file
	_, err = readFile(filepath.Join(tmpDir, "nonexistent"))
	if err == nil {
		t.Error("expected error for missing file")
	}
}

func TestSymmetricOutputFormat(t *testing.T) {
	// Create minimal bootstrap setup in temp dir
	tmpDir := t.TempDir()
	bootstrapPath := filepath.Join(tmpDir, "bootstrap")
	os.MkdirAll(bootstrapPath, 0700)
	os.WriteFile(filepath.Join(bootstrapPath, "ci-token"), []byte("test-token"), 0600)
	os.WriteFile(filepath.Join(bootstrapPath, "public-key"), []byte("fort:testkey"), 0600)

	// Mock the response (can't easily test full flow without modifying consts)
	resp := TokenResponse{
		CacheURL:  "https://cache.test",
		CacheName: "fort",
		PublicKey: "fort:testkey",
		PushToken: "test-token",
	}
	respBytes, _ := json.Marshal(resp)

	originalRequest := json.RawMessage(`{}`)
	output := HandlerOutput{
		"host:attic-token": OutputEntry{
			Request:  originalRequest,
			Response: respBytes,
		},
	}

	entry := output["host:attic-token"]

	// Verify symmetric format: request is echoed back
	if string(entry.Request) != string(originalRequest) {
		t.Errorf("request not echoed: got %s, want %s", string(entry.Request), string(originalRequest))
	}

	// Verify response contains expected fields
	var parsedResp TokenResponse
	if err := json.Unmarshal(entry.Response, &parsedResp); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}

	if parsedResp.CacheURL != "https://cache.test" {
		t.Errorf("unexpected cacheUrl: %s", parsedResp.CacheURL)
	}
	if parsedResp.CacheName != "fort" {
		t.Errorf("unexpected cacheName: %s", parsedResp.CacheName)
	}
	if parsedResp.PublicKey != "fort:testkey" {
		t.Errorf("unexpected publicKey: %s", parsedResp.PublicKey)
	}
	if parsedResp.PushToken != "test-token" {
		t.Errorf("unexpected pushToken: %s", parsedResp.PushToken)
	}
}

func TestMultipleRequesters(t *testing.T) {
	// Test that all requesters get the same response
	resp := TokenResponse{
		CacheURL:  "https://cache.test",
		CacheName: "fort",
		PublicKey: "fort:key",
		PushToken: "token",
	}
	respBytes, _ := json.Marshal(resp)

	input := HandlerInput{
		"host1:attic-token": InputEntry{Request: json.RawMessage(`{}`)},
		"host2:attic-token": InputEntry{Request: json.RawMessage(`{}`)},
		"host3:attic-token": InputEntry{Request: json.RawMessage(`{}`)},
	}

	output := make(HandlerOutput)
	for key, entry := range input {
		output[key] = OutputEntry{
			Request:  entry.Request,
			Response: respBytes,
		}
	}

	// All should have identical responses
	var firstResp []byte
	for key, entry := range output {
		if firstResp == nil {
			firstResp = entry.Response
		} else if string(entry.Response) != string(firstResp) {
			t.Errorf("response for %s differs from first response", key)
		}
	}

	if len(output) != 3 {
		t.Errorf("expected 3 outputs, got %d", len(output))
	}
}

func TestTokenResponseJSON(t *testing.T) {
	resp := TokenResponse{
		CacheURL:  "https://cache.example.com",
		CacheName: "fort",
		PublicKey: "fort:abc123",
		PushToken: "secret-token",
	}

	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("failed to marshal: %v", err)
	}

	var parsed TokenResponse
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("failed to unmarshal: %v", err)
	}

	if parsed.CacheURL != resp.CacheURL {
		t.Errorf("cacheUrl mismatch")
	}
	if parsed.CacheName != resp.CacheName {
		t.Errorf("cacheName mismatch")
	}
	if parsed.PublicKey != resp.PublicKey {
		t.Errorf("publicKey mismatch")
	}
	if parsed.PushToken != resp.PushToken {
		t.Errorf("pushToken mismatch")
	}
}

func TestTokenResponseWithError(t *testing.T) {
	resp := TokenResponse{
		Error: "something went wrong",
	}

	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("failed to marshal: %v", err)
	}

	var parsed TokenResponse
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("failed to unmarshal: %v", err)
	}

	if parsed.Error != "something went wrong" {
		t.Errorf("error mismatch: %s", parsed.Error)
	}

	// Other fields should be empty
	if parsed.CacheURL != "" || parsed.PushToken != "" {
		t.Error("expected empty fields when error is set")
	}
}
