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

// Configuration - can be overridden via ldflags at build time
var (
	defaultAtticClientPath = "/run/current-system/sw/bin/attic"
	cacheURL               = "https://cache.fort.example"
	cacheName              = "fort"
)

const (
	bootstrapDir  = "/var/lib/atticd/bootstrap"
	ciTokenFile   = bootstrapDir + "/ci-token"
	adminTokenFile = bootstrapDir + "/admin-token"
	publicKeyFile = bootstrapDir + "/public-key"
)

func main() {
	atticClientPath := getEnv("ATTIC_CLIENT_PATH", defaultAtticClientPath)

	// Read input from stdin
	inputData, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read stdin: %v\n", err)
		os.Exit(1)
	}

	var input HandlerInput
	if err := json.Unmarshal(inputData, &input); err != nil {
		fmt.Fprintf(os.Stderr, "invalid input JSON: %v\n", err)
		os.Exit(1)
	}

	output, err := processEntries(atticClientPath, input)
	if err != nil {
		fmt.Fprintf(os.Stderr, "processing failed: %v\n", err)
		os.Exit(1)
	}

	writeOutput(output)
}

func getEnv(key, defaultVal string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultVal
}

// processEntries handles all token requests
func processEntries(atticClientPath string, input HandlerInput) (HandlerOutput, error) {
	output := make(HandlerOutput)

	// Get the cache config (same for all requesters)
	resp := getCacheConfig(atticClientPath)
	respBytes, _ := json.Marshal(resp)

	// Return same response for all keys
	for key, entry := range input {
		output[key] = OutputEntry{
			Request:  entry.Request,
			Response: respBytes,
		}
	}

	return output, nil
}

// getCacheConfig returns the binary cache configuration
func getCacheConfig(atticClientPath string) TokenResponse {
	// Check for CI token
	ciToken, err := readFile(ciTokenFile)
	if err != nil {
		return TokenResponse{Error: "CI token not yet created"}
	}

	// Get or fetch public key
	publicKey, err := getPublicKey(atticClientPath)
	if err != nil {
		return TokenResponse{Error: err.Error()}
	}

	return TokenResponse{
		CacheURL:  cacheURL,
		CacheName: cacheName,
		PublicKey: publicKey,
		PushToken: ciToken,
	}
}

// getPublicKey returns the cached public key or fetches it from attic
func getPublicKey(atticClientPath string) (string, error) {
	// Try cached public key first
	if pk, err := readFile(publicKeyFile); err == nil && pk != "" {
		return pk, nil
	}

	// Need to fetch via attic client
	adminToken, err := readFile(adminTokenFile)
	if err != nil {
		return "", fmt.Errorf("admin token not yet created")
	}

	// Create temp config directory
	tmpDir, err := os.MkdirTemp("", "attic-")
	if err != nil {
		return "", fmt.Errorf("failed to create temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	configDir := tmpDir + "/.config/attic"
	if err := os.MkdirAll(configDir, 0700); err != nil {
		return "", fmt.Errorf("failed to create config dir: %w", err)
	}

	configContent := fmt.Sprintf(`default-server = "local"

[servers.local]
endpoint = "%s"
token = "%s"
`, cacheURL, adminToken)

	if err := os.WriteFile(configDir+"/config.toml", []byte(configContent), 0600); err != nil {
		return "", fmt.Errorf("failed to write config: %w", err)
	}

	// Run attic cache info
	cmd := exec.Command(atticClientPath, "cache", "info", cacheName)
	cmd.Env = append(os.Environ(), "HOME="+tmpDir)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("attic cache info failed: %w (output: %s)", err, string(output))
	}

	// Parse public key from output
	publicKey := parsePublicKey(string(output))
	if publicKey == "" {
		return "", fmt.Errorf("could not parse public key from output: %s", string(output))
	}

	// Cache the public key
	if err := os.WriteFile(publicKeyFile, []byte(publicKey), 0600); err != nil {
		fmt.Fprintf(os.Stderr, "warning: failed to cache public key: %v\n", err)
	}

	return publicKey, nil
}

// parsePublicKey extracts the public key from attic cache info output
func parsePublicKey(output string) string {
	// Output format: "Public Key: <key>"
	re := regexp.MustCompile(`Public Key:\s*(\S+)`)
	matches := re.FindStringSubmatch(output)
	if len(matches) >= 2 {
		return matches[1]
	}
	return ""
}

// readFile reads a file and returns trimmed content
func readFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	content := strings.TrimSpace(string(data))
	if content == "" {
		return "", fmt.Errorf("file is empty")
	}
	return content, nil
}

// writeOutput marshals and writes the handler output to stdout
func writeOutput(output HandlerOutput) {
	data, err := json.Marshal(output)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to marshal output: %v\n", err)
		os.Exit(1)
	}
	os.Stdout.Write(data)
}
