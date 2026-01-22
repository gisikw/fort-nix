package main

import (
	"encoding/json"
	"errors"
	"testing"
)

// mockCommandRunner implements CommandRunner for testing
type mockCommandRunner struct {
	// Map of command name to result
	responses map[string]struct {
		output []byte
		err    error
	}
	// Record of commands called
	calls [][]string
}

func newMockRunner() *mockCommandRunner {
	return &mockCommandRunner{
		responses: make(map[string]struct {
			output []byte
			err    error
		}),
	}
}

func (m *mockCommandRunner) Run(name string, args ...string) ([]byte, error) {
	m.calls = append(m.calls, append([]string{name}, args...))
	if r, ok := m.responses[name]; ok {
		return r.output, r.err
	}
	return nil, errors.New("no mock response")
}

func (m *mockCommandRunner) setResponse(cmd string, output string, err error) {
	m.responses[cmd] = struct {
		output []byte
		err    error
	}{[]byte(output), err}
}

// --- SHA Parsing Tests ---

func TestParsePendingSHA_Standard(t *testing.T) {
	msg := "release: 5563ac2 - 2025-12-31T19:44:27+00:00"
	sha := parsePendingSHA(msg)
	if sha != "5563ac2" {
		t.Errorf("expected 5563ac2, got %s", sha)
	}
}

func TestParsePendingSHA_FullSHA(t *testing.T) {
	msg := "release: 5563ac2b4e1f8a9c7d2e3b4c5a6f7e8d9c0b1a2f - 2025-12-31T19:44:27+00:00"
	sha := parsePendingSHA(msg)
	if sha != "5563ac2b4e1f8a9c7d2e3b4c5a6f7e8d9c0b1a2f" {
		t.Errorf("expected full SHA, got %s", sha)
	}
}

func TestParsePendingSHA_NoMatch(t *testing.T) {
	msg := "initial commit"
	sha := parsePendingSHA(msg)
	if sha != "" {
		t.Errorf("expected empty, got %s", sha)
	}
}

func TestParsePendingSHA_Empty(t *testing.T) {
	sha := parsePendingSHA("")
	if sha != "" {
		t.Errorf("expected empty, got %s", sha)
	}
}

func TestParsePendingSHA_Whitespace(t *testing.T) {
	msg := "release:   abc123   - 2025-01-01"
	sha := parsePendingSHA(msg)
	if sha != "abc123" {
		t.Errorf("expected abc123, got %s", sha)
	}
}

// --- SHA Matching Tests ---

func TestShaMatches_Exact(t *testing.T) {
	if !shaMatches("abc123", "abc123") {
		t.Error("exact match should succeed")
	}
}

func TestShaMatches_ExpectedPrefix(t *testing.T) {
	if !shaMatches("abc", "abc123def") {
		t.Error("expected prefix should match")
	}
}

func TestShaMatches_PendingPrefix(t *testing.T) {
	if !shaMatches("abc123def", "abc") {
		t.Error("pending prefix should match")
	}
}

func TestShaMatches_NoMatch(t *testing.T) {
	if shaMatches("abc", "def") {
		t.Error("non-matching SHAs should not match")
	}
}

func TestShaMatches_PartialOverlap(t *testing.T) {
	if shaMatches("abc123", "abc456") {
		t.Error("partial overlap without prefix should not match")
	}
}

// --- Request Processing Tests ---

func TestProcessRequest_InvalidJSON(t *testing.T) {
	resp := processRequest([]byte(`{not valid json}`))
	if resp.Error == "" || resp.Error == "sha_mismatch" {
		t.Error("expected error for invalid JSON")
	}
}

func TestProcessRequest_EmptyInput(t *testing.T) {
	resp := processRequest([]byte(``))
	if resp.Error == "" {
		t.Error("expected error for empty input")
	}
}

func TestProcessRequest_MissingSHA(t *testing.T) {
	resp := processRequest([]byte(`{}`))
	if resp.Error != "sha parameter required" {
		t.Errorf("expected 'sha parameter required', got '%s'", resp.Error)
	}
}

func TestProcessRequest_EmptySHA(t *testing.T) {
	resp := processRequest([]byte(`{"sha": ""}`))
	if resp.Error != "sha parameter required" {
		t.Errorf("expected 'sha parameter required', got '%s'", resp.Error)
	}
}

func TestProcessRequest_GitFails(t *testing.T) {
	mock := newMockRunner()
	mock.setResponse(gitPath, "fatal: not a git repository", errors.New("exit 128"))
	cmdRunner = mock

	resp := processRequest([]byte(`{"sha": "abc123"}`))
	if resp.Error != "failed to read release HEAD" {
		t.Errorf("expected git error, got '%s'", resp.Error)
	}
	if resp.Details != "fatal: not a git repository" {
		t.Errorf("expected git output in details, got '%s'", resp.Details)
	}
}

func TestProcessRequest_ParseFails(t *testing.T) {
	mock := newMockRunner()
	mock.setResponse(gitPath, "some random commit message", nil)
	cmdRunner = mock

	resp := processRequest([]byte(`{"sha": "abc123"}`))
	if resp.Error != "could not parse SHA from release commit" {
		t.Errorf("expected parse error, got '%s'", resp.Error)
	}
	if resp.CommitMessage != "some random commit message" {
		t.Errorf("expected commit message in response")
	}
}

func TestProcessRequest_SHAMismatch(t *testing.T) {
	mock := newMockRunner()
	mock.setResponse(gitPath, "release: def456 - 2025-01-01", nil)
	cmdRunner = mock

	resp := processRequest([]byte(`{"sha": "abc123"}`))
	if resp.Error != "sha_mismatch" {
		t.Errorf("expected sha_mismatch, got '%s'", resp.Error)
	}
	if resp.Expected != "abc123" {
		t.Errorf("expected 'abc123' in expected field")
	}
	if resp.Pending != "def456" {
		t.Errorf("expected 'def456' in pending field")
	}
}

func TestProcessRequest_DeploySuccess(t *testing.T) {
	mock := newMockRunner()
	mock.setResponse(gitPath, "release: abc123 - 2025-01-01", nil)
	mock.setResponse(cominPath, "generation 42 accepted for deploying", nil)
	cmdRunner = mock

	resp := processRequest([]byte(`{"sha": "abc123"}`))
	if resp.Status != "deployed" {
		t.Errorf("expected status 'deployed', got '%s'", resp.Status)
	}
	if resp.SHA != "abc123" {
		t.Errorf("expected SHA 'abc123', got '%s'", resp.SHA)
	}
	if resp.Error != "" {
		t.Errorf("unexpected error: %s", resp.Error)
	}
}

func TestProcessRequest_DeployStillBuilding(t *testing.T) {
	mock := newMockRunner()
	mock.setResponse(gitPath, "release: abc123 - 2025-01-01", nil)
	mock.setResponse(cominPath, "no pending generation to confirm", nil)
	cmdRunner = mock

	resp := processRequest([]byte(`{"sha": "abc123"}`))
	if resp.Error != "building" {
		t.Errorf("expected error 'building', got '%s'", resp.Error)
	}
	if resp.Note != "generation not ready for confirmation yet" {
		t.Errorf("expected building note, got '%s'", resp.Note)
	}
}

func TestProcessRequest_AlreadyDeployed(t *testing.T) {
	mock := newMockRunner()
	mock.setResponse(gitPath, "release: abc123 - 2025-01-01", nil)
	mock.setResponse(cominPath, "error: no confirmation pending", errors.New("exit 1"))
	cmdRunner = mock

	resp := processRequest([]byte(`{"sha": "abc123"}`))
	if resp.Status != "confirmed" {
		t.Errorf("expected status 'confirmed', got '%s'", resp.Status)
	}
	if resp.Note != "no confirmation was pending (may have auto-deployed)" {
		t.Errorf("expected auto-deploy note, got '%s'", resp.Note)
	}
}

func TestProcessRequest_PrefixMatch(t *testing.T) {
	mock := newMockRunner()
	mock.setResponse(gitPath, "release: abc123def456 - 2025-01-01", nil)
	mock.setResponse(cominPath, "generation 42 accepted for deploying", nil)
	cmdRunner = mock

	// Short SHA should match long pending SHA
	resp := processRequest([]byte(`{"sha": "abc123"}`))
	if resp.Status != "deployed" {
		t.Errorf("expected prefix match to deploy, got error: %s", resp.Error)
	}
}

// --- Response Format Tests ---

func TestDeployResponse_SuccessJSON(t *testing.T) {
	resp := DeployResponse{Status: "deployed", SHA: "abc123"}
	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("failed to marshal: %v", err)
	}

	var parsed map[string]interface{}
	json.Unmarshal(data, &parsed)

	if parsed["status"] != "deployed" {
		t.Error("expected status 'deployed'")
	}
	if parsed["sha"] != "abc123" {
		t.Error("expected sha 'abc123'")
	}
	// Check omitempty
	if _, exists := parsed["error"]; exists {
		t.Error("error field should be omitted when empty")
	}
}

func TestDeployResponse_MismatchJSON(t *testing.T) {
	resp := DeployResponse{Error: "sha_mismatch", Expected: "abc", Pending: "def"}
	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("failed to marshal: %v", err)
	}

	var parsed map[string]interface{}
	json.Unmarshal(data, &parsed)

	if parsed["error"] != "sha_mismatch" {
		t.Error("expected error 'sha_mismatch'")
	}
	if parsed["expected"] != "abc" {
		t.Error("expected 'abc' in expected field")
	}
	if parsed["pending"] != "def" {
		t.Error("expected 'def' in pending field")
	}
}

// --- Command Recording Tests ---

func TestProcessRequest_CommandsAreCalled(t *testing.T) {
	mock := newMockRunner()
	mock.setResponse(gitPath, "release: abc123 - 2025-01-01", nil)
	mock.setResponse(cominPath, "generation 42 accepted for deploying", nil)
	cmdRunner = mock

	processRequest([]byte(`{"sha": "abc123"}`))

	if len(mock.calls) != 2 {
		t.Fatalf("expected 2 commands, got %d", len(mock.calls))
	}

	// Verify git command
	gitCall := mock.calls[0]
	if gitCall[0] != gitPath {
		t.Errorf("expected git command first, got %s", gitCall[0])
	}
	if gitCall[1] != "-C" || gitCall[2] != cominRepoPath {
		t.Error("expected git -C /var/lib/comin/repository")
	}

	// Verify comin command
	cominCall := mock.calls[1]
	if cominCall[0] != cominPath {
		t.Errorf("expected comin command, got %s", cominCall[0])
	}
	if cominCall[1] != "confirmation" || cominCall[2] != "accept" {
		t.Error("expected comin confirmation accept")
	}
}

func TestProcessRequest_NoComin_OnMismatch(t *testing.T) {
	mock := newMockRunner()
	mock.setResponse(gitPath, "release: def456 - 2025-01-01", nil)
	cmdRunner = mock

	processRequest([]byte(`{"sha": "abc123"}`))

	// Only git should be called, not comin
	if len(mock.calls) != 1 {
		t.Errorf("expected only git command on mismatch, got %d commands", len(mock.calls))
	}
}
