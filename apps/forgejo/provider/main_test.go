package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// mockForgejoClient simulates Forgejo token operations
type mockForgejoClient struct {
	tokens        map[string]string // tokenName -> token value
	generateCalls []string          // track generate calls
	revokeCalls   []string          // track revoke calls
	failGenerate  bool              // simulate generation failure
}

func newMockForgejoClient() *mockForgejoClient {
	return &mockForgejoClient{
		tokens: make(map[string]string),
	}
}

func (m *mockForgejoClient) GenerateToken(tokenName, scopes string) (string, error) {
	m.generateCalls = append(m.generateCalls, tokenName)
	if m.failGenerate {
		return "", &mockError{"generate failed"}
	}
	token := "token-" + tokenName + "-" + scopes
	m.tokens[tokenName] = token
	return token, nil
}

func (m *mockForgejoClient) RevokeToken(tokenName string) error {
	m.revokeCalls = append(m.revokeCalls, tokenName)
	delete(m.tokens, tokenName)
	return nil
}

type mockError struct{ msg string }

func (e *mockError) Error() string { return e.msg }

// TokenGenerator interface for testing
type TokenGenerator interface {
	GenerateToken(tokenName, scopes string) (string, error)
	RevokeToken(tokenName string) error
}

// Ensure ForgejoClient implements the interface
var _ TokenGenerator = (*ForgejoClient)(nil)

// processEntriesWithClient is a testable version that accepts an interface
func processEntriesWithClient(client TokenGenerator, input HandlerInput, tokenDir string) (HandlerOutput, error) {
	output := make(HandlerOutput)
	now := time.Now().Unix()

	expectedFiles := make(map[string]bool)

	for key, entry := range input {
		origin := strings.Split(key, ":")[0]

		var req TokenRequest
		if err := json.Unmarshal(entry.Request, &req); err != nil {
			resp := TokenResponse{Error: "invalid request format"}
			respBytes, _ := json.Marshal(resp)
			output[key] = OutputEntry{
				Request:  entry.Request,
				Response: respBytes,
			}
			continue
		}

		access := req.Access
		if access == "" {
			access = "ro"
		}

		if access != "ro" && access != "rw" {
			resp := TokenResponse{Error: "access must be ro or rw"}
			respBytes, _ := json.Marshal(resp)
			output[key] = OutputEntry{
				Request:  entry.Request,
				Response: respBytes,
			}
			continue
		}

		if access == "rw" && origin != "ratched" {
			resp := TokenResponse{Error: "rw access requires dev-sandbox host (ratched)"}
			respBytes, _ := json.Marshal(resp)
			output[key] = OutputEntry{
				Request:  entry.Request,
				Response: respBytes,
			}
			continue
		}

		tokenFile := filepath.Join(tokenDir, origin+"-"+access)
		expectedFiles[tokenFile] = true

		resp := processTokenWithClient(client, origin, access, tokenFile, now)
		respBytes, _ := json.Marshal(resp)
		output[key] = OutputEntry{
			Request:  entry.Request,
			Response: respBytes,
		}
	}

	garbageCollectWithClient(client, tokenDir, expectedFiles)

	return output, nil
}

func processTokenWithClient(client TokenGenerator, origin, access, tokenFile string, now int64) TokenResponse {
	tokenName := origin + "-" + access
	scopes := "read:repository"
	if access == "rw" {
		scopes = "read:repository,write:repository"
	}

	if stored, err := loadStoredToken(tokenFile); err == nil {
		remaining := stored.Expiry - now
		if remaining > rotationThreshold {
			return TokenResponse{
				Token:    stored.Token,
				Username: username,
				TTL:      remaining,
			}
		}
	}

	client.RevokeToken(tokenName)

	token, err := client.GenerateToken(tokenName, scopes)
	if err != nil {
		return TokenResponse{Error: "failed to generate token"}
	}

	expiry := now + tokenTTL
	saveStoredToken(tokenFile, token, expiry)

	return TokenResponse{
		Token:    token,
		Username: username,
		TTL:      tokenTTL,
	}
}

func garbageCollectWithClient(client TokenGenerator, tokenDir string, expectedFiles map[string]bool) {
	entries, err := os.ReadDir(tokenDir)
	if err != nil {
		return
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		tokenFile := filepath.Join(tokenDir, entry.Name())
		if !expectedFiles[tokenFile] {
			client.RevokeToken(entry.Name())
			os.Remove(tokenFile)
		}
	}
}

func TestProcessEntries_NewToken(t *testing.T) {
	tmpDir := t.TempDir()
	mock := newMockForgejoClient()

	input := HandlerInput{
		"joker:git-token": InputEntry{
			Request: json.RawMessage(`{"access":"ro"}`),
		},
	}

	output, err := processEntriesWithClient(mock, input, tmpDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	entry, ok := output["joker:git-token"]
	if !ok {
		t.Fatal("expected output for joker:git-token")
	}

	var resp TokenResponse
	if err := json.Unmarshal(entry.Response, &resp); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}

	if resp.Error != "" {
		t.Errorf("unexpected error: %s", resp.Error)
	}
	if resp.Token == "" {
		t.Error("expected token to be set")
	}
	if resp.Username != "forge-admin" {
		t.Errorf("expected username forge-admin, got %s", resp.Username)
	}
	if resp.TTL != tokenTTL {
		t.Errorf("expected TTL %d, got %d", tokenTTL, resp.TTL)
	}

	// Verify token file was created
	tokenFile := filepath.Join(tmpDir, "joker-ro")
	if _, err := os.Stat(tokenFile); os.IsNotExist(err) {
		t.Error("expected token file to be created")
	}
}

func TestProcessEntries_CachedToken(t *testing.T) {
	tmpDir := t.TempDir()
	mock := newMockForgejoClient()

	// Pre-create a valid token file
	tokenFile := filepath.Join(tmpDir, "joker-ro")
	futureExpiry := time.Now().Unix() + tokenTTL // Full TTL remaining
	saveStoredToken(tokenFile, "cached-token-value", futureExpiry)

	input := HandlerInput{
		"joker:git-token": InputEntry{
			Request: json.RawMessage(`{"access":"ro"}`),
		},
	}

	output, err := processEntriesWithClient(mock, input, tmpDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp TokenResponse
	json.Unmarshal(output["joker:git-token"].Response, &resp)

	// Should reuse cached token
	if resp.Token != "cached-token-value" {
		t.Errorf("expected cached token, got %s", resp.Token)
	}

	// Should not have called generate
	if len(mock.generateCalls) > 0 {
		t.Errorf("should not generate new token, got %d calls", len(mock.generateCalls))
	}
}

func TestProcessEntries_ExpiredToken(t *testing.T) {
	tmpDir := t.TempDir()
	mock := newMockForgejoClient()

	// Pre-create an expired token file (within rotation threshold)
	tokenFile := filepath.Join(tmpDir, "joker-ro")
	nearExpiry := time.Now().Unix() + 1000 // Less than rotationThreshold (7200)
	saveStoredToken(tokenFile, "old-token", nearExpiry)

	input := HandlerInput{
		"joker:git-token": InputEntry{
			Request: json.RawMessage(`{"access":"ro"}`),
		},
	}

	output, err := processEntriesWithClient(mock, input, tmpDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp TokenResponse
	json.Unmarshal(output["joker:git-token"].Response, &resp)

	// Should have generated new token
	if resp.Token == "old-token" {
		t.Error("should have rotated expired token")
	}
	if len(mock.generateCalls) != 1 {
		t.Errorf("expected 1 generate call, got %d", len(mock.generateCalls))
	}
	if len(mock.revokeCalls) != 1 {
		t.Errorf("expected 1 revoke call, got %d", len(mock.revokeCalls))
	}
}

func TestProcessEntries_RBACDenied(t *testing.T) {
	tmpDir := t.TempDir()
	mock := newMockForgejoClient()

	// Non-ratched host requesting rw access
	input := HandlerInput{
		"joker:git-token": InputEntry{
			Request: json.RawMessage(`{"access":"rw"}`),
		},
	}

	output, err := processEntriesWithClient(mock, input, tmpDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp TokenResponse
	json.Unmarshal(output["joker:git-token"].Response, &resp)

	if resp.Error == "" {
		t.Error("expected RBAC error")
	}
	if !strings.Contains(resp.Error, "dev-sandbox") {
		t.Errorf("error should mention dev-sandbox: %s", resp.Error)
	}

	// Should not have called generate
	if len(mock.generateCalls) > 0 {
		t.Error("should not generate token for unauthorized request")
	}
}

func TestProcessEntries_RBACAllowed(t *testing.T) {
	tmpDir := t.TempDir()
	mock := newMockForgejoClient()

	// ratched host requesting rw access
	input := HandlerInput{
		"ratched:git-token": InputEntry{
			Request: json.RawMessage(`{"access":"rw"}`),
		},
	}

	output, err := processEntriesWithClient(mock, input, tmpDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp TokenResponse
	json.Unmarshal(output["ratched:git-token"].Response, &resp)

	if resp.Error != "" {
		t.Errorf("unexpected error: %s", resp.Error)
	}
	if resp.Token == "" {
		t.Error("expected token for authorized request")
	}

	// Verify scopes include write
	if len(mock.generateCalls) != 1 {
		t.Fatalf("expected 1 generate call")
	}
}

func TestProcessEntries_InvalidAccess(t *testing.T) {
	tmpDir := t.TempDir()
	mock := newMockForgejoClient()

	input := HandlerInput{
		"joker:git-token": InputEntry{
			Request: json.RawMessage(`{"access":"admin"}`),
		},
	}

	output, err := processEntriesWithClient(mock, input, tmpDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp TokenResponse
	json.Unmarshal(output["joker:git-token"].Response, &resp)

	if resp.Error == "" {
		t.Error("expected error for invalid access level")
	}
	if !strings.Contains(resp.Error, "ro or rw") {
		t.Errorf("error should mention valid values: %s", resp.Error)
	}
}

func TestProcessEntries_DefaultAccess(t *testing.T) {
	tmpDir := t.TempDir()
	mock := newMockForgejoClient()

	// No access specified - should default to ro
	input := HandlerInput{
		"joker:git-token": InputEntry{
			Request: json.RawMessage(`{}`),
		},
	}

	output, err := processEntriesWithClient(mock, input, tmpDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp TokenResponse
	json.Unmarshal(output["joker:git-token"].Response, &resp)

	if resp.Error != "" {
		t.Errorf("unexpected error: %s", resp.Error)
	}

	// Check token file name indicates ro
	tokenFile := filepath.Join(tmpDir, "joker-ro")
	if _, err := os.Stat(tokenFile); os.IsNotExist(err) {
		t.Error("expected ro token file")
	}
}

func TestProcessEntries_GarbageCollection(t *testing.T) {
	tmpDir := t.TempDir()
	mock := newMockForgejoClient()

	// Pre-create an orphan token file
	orphanFile := filepath.Join(tmpDir, "orphan-ro")
	saveStoredToken(orphanFile, "orphan-token", time.Now().Unix()+tokenTTL)

	// Pre-create an active token file
	activeFile := filepath.Join(tmpDir, "joker-ro")
	saveStoredToken(activeFile, "active-token", time.Now().Unix()+tokenTTL)

	// Only request joker's token
	input := HandlerInput{
		"joker:git-token": InputEntry{
			Request: json.RawMessage(`{"access":"ro"}`),
		},
	}

	_, err := processEntriesWithClient(mock, input, tmpDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Orphan should be deleted
	if _, err := os.Stat(orphanFile); !os.IsNotExist(err) {
		t.Error("orphan token file should have been deleted")
	}

	// Active should remain
	if _, err := os.Stat(activeFile); os.IsNotExist(err) {
		t.Error("active token file should still exist")
	}

	// Should have revoked orphan
	found := false
	for _, name := range mock.revokeCalls {
		if name == "orphan-ro" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected revoke call for orphan token")
	}
}

func TestProcessEntries_InvalidJSON(t *testing.T) {
	tmpDir := t.TempDir()
	mock := newMockForgejoClient()

	input := HandlerInput{
		"bad-key": InputEntry{
			Request: json.RawMessage(`{invalid json`),
		},
	}

	output, err := processEntriesWithClient(mock, input, tmpDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp TokenResponse
	json.Unmarshal(output["bad-key"].Response, &resp)

	if resp.Error == "" {
		t.Error("expected error for invalid JSON")
	}
}

func TestProcessEntries_GenerationFailure(t *testing.T) {
	tmpDir := t.TempDir()
	mock := newMockForgejoClient()
	mock.failGenerate = true

	input := HandlerInput{
		"joker:git-token": InputEntry{
			Request: json.RawMessage(`{"access":"ro"}`),
		},
	}

	output, err := processEntriesWithClient(mock, input, tmpDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp TokenResponse
	json.Unmarshal(output["joker:git-token"].Response, &resp)

	if resp.Error == "" {
		t.Error("expected error for generation failure")
	}
	if !strings.Contains(resp.Error, "generate") {
		t.Errorf("error should mention generation: %s", resp.Error)
	}
}

func TestSymmetricOutputFormat(t *testing.T) {
	tmpDir := t.TempDir()
	mock := newMockForgejoClient()

	originalRequest := json.RawMessage(`{"access":"ro"}`)
	input := HandlerInput{
		"host:need": InputEntry{
			Request: originalRequest,
		},
	}

	output, err := processEntriesWithClient(mock, input, tmpDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	entry := output["host:need"]

	// Verify symmetric format: request is echoed back
	if string(entry.Request) != string(originalRequest) {
		t.Errorf("request not echoed: got %s, want %s", string(entry.Request), string(originalRequest))
	}

	// Verify response is present
	if len(entry.Response) == 0 {
		t.Error("expected response to be present")
	}
}

func TestMultipleHosts(t *testing.T) {
	tmpDir := t.TempDir()
	mock := newMockForgejoClient()

	input := HandlerInput{
		"joker:git-token":     InputEntry{Request: json.RawMessage(`{"access":"ro"}`)},
		"minos:git-token":     InputEntry{Request: json.RawMessage(`{"access":"ro"}`)},
		"ratched:git-token":   InputEntry{Request: json.RawMessage(`{"access":"rw"}`)},
		"lordhenry:git-token": InputEntry{Request: json.RawMessage(`{}`)},
	}

	output, err := processEntriesWithClient(mock, input, tmpDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(output) != 4 {
		t.Errorf("expected 4 outputs, got %d", len(output))
	}

	// All should succeed
	for key, entry := range output {
		var resp TokenResponse
		json.Unmarshal(entry.Response, &resp)
		if resp.Error != "" {
			t.Errorf("unexpected error for %s: %s", key, resp.Error)
		}
		if resp.Token == "" {
			t.Errorf("expected token for %s", key)
		}
	}

	// Verify token files
	expectedFiles := []string{"joker-ro", "minos-ro", "ratched-rw", "lordhenry-ro"}
	for _, name := range expectedFiles {
		path := filepath.Join(tmpDir, name)
		if _, err := os.Stat(path); os.IsNotExist(err) {
			t.Errorf("expected token file %s", name)
		}
	}
}

func TestStoredTokenFormat(t *testing.T) {
	tmpDir := t.TempDir()
	tokenFile := filepath.Join(tmpDir, "test-token")

	expiry := time.Now().Unix() + 3600
	err := saveStoredToken(tokenFile, "my-secret-token", expiry)
	if err != nil {
		t.Fatalf("failed to save token: %v", err)
	}

	stored, err := loadStoredToken(tokenFile)
	if err != nil {
		t.Fatalf("failed to load token: %v", err)
	}

	if stored.Token != "my-secret-token" {
		t.Errorf("expected my-secret-token, got %s", stored.Token)
	}
	if stored.Expiry != expiry {
		t.Errorf("expected expiry %d, got %d", expiry, stored.Expiry)
	}
}

func TestLoadStoredToken_InvalidJSON(t *testing.T) {
	tmpDir := t.TempDir()
	tokenFile := filepath.Join(tmpDir, "bad-token")

	os.WriteFile(tokenFile, []byte("not json"), 0600)

	_, err := loadStoredToken(tokenFile)
	if err == nil {
		t.Error("expected error for invalid JSON")
	}
}

func TestLoadStoredToken_EmptyToken(t *testing.T) {
	tmpDir := t.TempDir()
	tokenFile := filepath.Join(tmpDir, "empty-token")

	os.WriteFile(tokenFile, []byte(`{"token":"","expiry":12345}`), 0600)

	_, err := loadStoredToken(tokenFile)
	if err == nil {
		t.Error("expected error for empty token")
	}
}
