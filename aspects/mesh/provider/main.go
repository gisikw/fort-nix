package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
)

// CommandRunner interface for testing
type CommandRunner interface {
	Run(name string, args ...string) ([]byte, error)
}

// RealCommandRunner executes actual system commands
type RealCommandRunner struct{}

func (r *RealCommandRunner) Run(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).CombinedOutput()
}

var cmdRunner CommandRunner = &RealCommandRunner{}

// ipPath can be overridden via ldflags at build time
var ipPath = "ip"

func main() {
	// Read stdin (ignored for this handler, but follow the protocol)
	_, err := io.ReadAll(os.Stdin)
	if err != nil {
		writeResponse(LanIPResponse{Error: fmt.Sprintf("failed to read stdin: %v", err)})
		os.Exit(1)
	}

	response := getLanIP()
	writeResponse(response)

	if response.Error != "" {
		os.Exit(1)
	}
}

// getLanIP returns the LAN IP address (source IP for default route)
// Separated from main() for testability
func getLanIP() LanIPResponse {
	output, err := cmdRunner.Run(ipPath, "-4", "route", "get", "1.1.1.1")
	if err != nil {
		return LanIPResponse{Error: fmt.Sprintf("ip route failed: %v", err)}
	}

	ip := parseSourceIP(string(output))
	if ip == "" {
		return LanIPResponse{Error: "no default route"}
	}

	return LanIPResponse{LanIP: ip}
}

// parseSourceIP extracts the source IP from ip route output
// Example output: "1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.100 uid 1000"
func parseSourceIP(output string) string {
	// Match "src" followed by an IPv4 address
	re := regexp.MustCompile(`src\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})`)
	matches := re.FindStringSubmatch(output)
	if len(matches) < 2 {
		return ""
	}
	return strings.TrimSpace(matches[1])
}

// writeResponse marshals and writes the response to stdout
func writeResponse(resp LanIPResponse) {
	data, err := json.Marshal(resp)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to marshal response: %v\n", err)
		os.Exit(1)
	}
	os.Stdout.Write(data)
}
