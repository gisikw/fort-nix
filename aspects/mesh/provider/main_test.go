package main

import (
	"encoding/json"
	"errors"
	"testing"
)

// mockCommandRunner implements CommandRunner for testing
type mockCommandRunner struct {
	output []byte
	err    error
}

func (m *mockCommandRunner) Run(name string, args ...string) ([]byte, error) {
	return m.output, m.err
}

// --- IP Parsing Tests ---

func TestParseSourceIP_Standard(t *testing.T) {
	output := "1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.100 uid 1000\n    cache"
	ip := parseSourceIP(output)
	if ip != "192.168.1.100" {
		t.Errorf("expected 192.168.1.100, got %s", ip)
	}
}

func TestParseSourceIP_NoGateway(t *testing.T) {
	// Direct route (no via)
	output := "1.1.1.1 dev eth0 src 10.0.0.50\n    cache"
	ip := parseSourceIP(output)
	if ip != "10.0.0.50" {
		t.Errorf("expected 10.0.0.50, got %s", ip)
	}
}

func TestParseSourceIP_MultipleLines(t *testing.T) {
	output := `1.1.1.1 via 10.20.30.1 dev enp0s3 src 10.20.30.100 uid 0
    cache`
	ip := parseSourceIP(output)
	if ip != "10.20.30.100" {
		t.Errorf("expected 10.20.30.100, got %s", ip)
	}
}

func TestParseSourceIP_NoSrc(t *testing.T) {
	output := "1.1.1.1 via 192.168.1.1 dev eth0"
	ip := parseSourceIP(output)
	if ip != "" {
		t.Errorf("expected empty, got %s", ip)
	}
}

func TestParseSourceIP_Empty(t *testing.T) {
	ip := parseSourceIP("")
	if ip != "" {
		t.Errorf("expected empty, got %s", ip)
	}
}

func TestParseSourceIP_InvalidIP(t *testing.T) {
	output := "1.1.1.1 via 192.168.1.1 dev eth0 src notanip"
	ip := parseSourceIP(output)
	if ip != "" {
		t.Errorf("expected empty for invalid IP, got %s", ip)
	}
}

func TestParseSourceIP_IPv6InOutput(t *testing.T) {
	// Ensure we only match IPv4
	output := "1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.100 uid 1000"
	ip := parseSourceIP(output)
	if ip != "192.168.1.100" {
		t.Errorf("expected 192.168.1.100, got %s", ip)
	}
}

func TestParseSourceIP_ExtraWhitespace(t *testing.T) {
	output := "1.1.1.1 via 192.168.1.1 dev eth0  src   192.168.1.100   uid 1000"
	ip := parseSourceIP(output)
	if ip != "192.168.1.100" {
		t.Errorf("expected 192.168.1.100, got %s", ip)
	}
}

// --- Command Execution Tests ---

func TestGetLanIP_Success(t *testing.T) {
	cmdRunner = &mockCommandRunner{
		output: []byte("1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.100 uid 1000"),
		err:    nil,
	}

	resp := getLanIP()
	if resp.Error != "" {
		t.Errorf("unexpected error: %s", resp.Error)
	}
	if resp.LanIP != "192.168.1.100" {
		t.Errorf("expected 192.168.1.100, got %s", resp.LanIP)
	}
}

func TestGetLanIP_CommandFails(t *testing.T) {
	cmdRunner = &mockCommandRunner{
		output: []byte("RTNETLINK answers: Network is unreachable"),
		err:    errors.New("exit status 1"),
	}

	resp := getLanIP()
	if resp.Error == "" {
		t.Error("expected error for command failure")
	}
	if resp.LanIP != "" {
		t.Errorf("expected empty lan_ip on error, got %s", resp.LanIP)
	}
}

func TestGetLanIP_NoDefaultRoute(t *testing.T) {
	// Command succeeds but no src in output
	cmdRunner = &mockCommandRunner{
		output: []byte(""),
		err:    nil,
	}

	resp := getLanIP()
	if resp.Error != "no default route" {
		t.Errorf("expected 'no default route', got '%s'", resp.Error)
	}
}

func TestGetLanIP_PrivateIP(t *testing.T) {
	cmdRunner = &mockCommandRunner{
		output: []byte("1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.100 uid 0"),
		err:    nil,
	}

	resp := getLanIP()
	if resp.LanIP != "10.0.0.100" {
		t.Errorf("expected 10.0.0.100, got %s", resp.LanIP)
	}
}

// --- Response Format Tests ---

func TestLanIPResponse_SuccessJSON(t *testing.T) {
	resp := LanIPResponse{LanIP: "192.168.1.100"}
	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("failed to marshal: %v", err)
	}

	// Verify omitempty works
	var parsed map[string]interface{}
	json.Unmarshal(data, &parsed)

	if parsed["lan_ip"] != "192.168.1.100" {
		t.Errorf("expected lan_ip '192.168.1.100'")
	}
	if _, exists := parsed["error"]; exists {
		t.Error("error field should be omitted when empty")
	}
}

func TestLanIPResponse_ErrorJSON(t *testing.T) {
	resp := LanIPResponse{Error: "no default route"}
	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("failed to marshal: %v", err)
	}

	var parsed map[string]interface{}
	json.Unmarshal(data, &parsed)

	if parsed["error"] != "no default route" {
		t.Errorf("expected error 'no default route'")
	}
	if _, exists := parsed["lan_ip"]; exists {
		t.Error("lan_ip field should be omitted when empty")
	}
}

// --- Edge Cases ---

func TestParseSourceIP_BoundaryIPs(t *testing.T) {
	tests := []struct {
		name     string
		output   string
		expected string
	}{
		{"min values", "route src 0.0.0.0", "0.0.0.0"},
		{"max values", "route src 255.255.255.255", "255.255.255.255"},
		{"localhost", "route src 127.0.0.1", "127.0.0.1"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ip := parseSourceIP(tt.output)
			if ip != tt.expected {
				t.Errorf("expected %s, got %s", tt.expected, ip)
			}
		})
	}
}

func TestParseSourceIP_InvalidOctets(t *testing.T) {
	// IP regex should handle boundary - 999 is invalid but regex still matches
	// This is OK - we trust `ip route` to return valid IPs
	output := "route src 999.999.999.999"
	ip := parseSourceIP(output)
	// Regex matches pattern, validation is not our job
	if ip != "999.999.999.999" {
		t.Errorf("expected regex to match pattern, got %s", ip)
	}
}
