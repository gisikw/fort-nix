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

// Paths can be overridden via ldflags at build time
var (
	gitPath     = "git"
	cominPath   = "comin"
	cominRepoPath = "/var/lib/comin/repository"
)

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		writeResponse(DeployResponse{Error: fmt.Sprintf("failed to read stdin: %v", err)})
		os.Exit(1)
	}

	response := processRequest(input)
	writeResponse(response)

	if response.Error != "" && response.Error != "sha_mismatch" {
		os.Exit(1)
	}
}

// processRequest handles the deploy request
// Separated from main() for testability
func processRequest(input []byte) DeployResponse {
	var req DeployRequest
	if err := json.Unmarshal(input, &req); err != nil {
		return DeployResponse{Error: fmt.Sprintf("invalid JSON: %v", err)}
	}

	if req.SHA == "" {
		return DeployResponse{Error: "sha parameter required"}
	}

	// Get release branch HEAD commit message
	output, err := cmdRunner.Run(gitPath, "-C", cominRepoPath, "log", "-1", "--format=%s", "HEAD")
	if err != nil {
		return DeployResponse{
			Error:   "failed to read release HEAD",
			Details: strings.TrimSpace(string(output)),
		}
	}

	releaseMsg := strings.TrimSpace(string(output))

	// Parse the SHA from commit message (format: "release: <sha> - <timestamp>")
	pendingSHA := parsePendingSHA(releaseMsg)
	if pendingSHA == "" {
		return DeployResponse{
			Error:         "could not parse SHA from release commit",
			CommitMessage: releaseMsg,
		}
	}

	// Verify SHA matches (allow prefix match for short SHAs)
	if !shaMatches(req.SHA, pendingSHA) {
		return DeployResponse{
			Error:    "sha_mismatch",
			Expected: req.SHA,
			Pending:  pendingSHA,
		}
	}

	// SHA matches - trigger confirmation
	return triggerConfirmation(pendingSHA)
}

// parsePendingSHA extracts the SHA from a release commit message
// Format: "release: 5563ac2 - 2025-12-31T19:44:27+00:00"
func parsePendingSHA(commitMsg string) string {
	re := regexp.MustCompile(`^release:\s*([a-f0-9]+)\s*-`)
	matches := re.FindStringSubmatch(commitMsg)
	if len(matches) < 2 {
		return ""
	}
	return matches[1]
}

// shaMatches checks if two SHAs match (allows prefix matching)
func shaMatches(expected, pending string) bool {
	return strings.HasPrefix(pending, expected) || strings.HasPrefix(expected, pending)
}

// triggerConfirmation runs comin confirmation accept and returns appropriate response
func triggerConfirmation(sha string) DeployResponse {
	output, err := cmdRunner.Run(cominPath, "confirmation", "accept")
	outputStr := strings.TrimSpace(string(output))

	if err != nil {
		// Command failed - likely no confirmation was pending
		return DeployResponse{
			Status: "confirmed",
			SHA:    sha,
			Note:   "no confirmation was pending (may have auto-deployed)",
			Output: outputStr,
		}
	}

	// Command succeeded - check if confirmation was actually accepted
	if strings.Contains(outputStr, "accepted for deploying") {
		return DeployResponse{
			Status: "deployed",
			SHA:    sha,
			Output: outputStr,
		}
	}

	// Command succeeded but nothing was accepted (generation still building?)
	return DeployResponse{
		Error:  "building",
		SHA:    sha,
		Note:   "generation not ready for confirmation yet",
		Output: outputStr,
	}
}

// writeResponse marshals and writes the response to stdout
func writeResponse(resp DeployResponse) {
	data, err := json.Marshal(resp)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to marshal response: %v\n", err)
		os.Exit(1)
	}
	os.Stdout.Write(data)
}
