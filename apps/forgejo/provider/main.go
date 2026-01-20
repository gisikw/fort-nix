package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Configuration - can be overridden via ldflags at build time
var (
	defaultForgejoPackage = "/run/current-system/sw"
	defaultSuPath         = "/run/current-system/sw/bin/su"
	defaultSqlite3Path    = "/run/current-system/sw/bin/sqlite3"
	tokenTTL              = int64(86400) // 24 hours
	rotationThreshold     = int64(7200)  // Regenerate when < 2 hours remain
)

const (
	tokenDir = "/var/lib/forgejo/tokens"
	username = "forge-admin"
)

func main() {
	// Read configuration from environment
	forgejoPackage := getEnv("FORGEJO_PACKAGE", defaultForgejoPackage)
	suPath := getEnv("SU_PATH", defaultSuPath)
	sqlite3Path := getEnv("SQLITE3_PATH", defaultSqlite3Path)

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

	// Ensure token directory exists
	if err := os.MkdirAll(tokenDir, 0700); err != nil {
		fmt.Fprintf(os.Stderr, "failed to create token dir: %v\n", err)
		os.Exit(1)
	}

	// Create Forgejo client
	client := NewForgejoClient(forgejoPackage, suPath, sqlite3Path)

	// Process entries and handle GC
	output, err := processEntries(client, input)
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

// processEntries handles all token requests and garbage collection
func processEntries(client *ForgejoClient, input HandlerInput) (HandlerOutput, error) {
	output := make(HandlerOutput)
	now := time.Now().Unix()

	// Track which token files should exist (for GC)
	expectedFiles := make(map[string]bool)

	for key, entry := range input {
		// Extract origin from key (format: "origin:needID" or just "origin")
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

		// Default to read-only
		access := req.Access
		if access == "" {
			access = "ro"
		}

		// Validate access level
		if access != "ro" && access != "rw" {
			resp := TokenResponse{Error: "access must be ro or rw"}
			respBytes, _ := json.Marshal(resp)
			output[key] = OutputEntry{
				Request:  entry.Request,
				Response: respBytes,
			}
			continue
		}

		// RBAC: Only dev-sandbox host (ratched) can request rw access
		if access == "rw" && origin != "ratched" {
			resp := TokenResponse{Error: "rw access requires dev-sandbox host (ratched)"}
			respBytes, _ := json.Marshal(resp)
			output[key] = OutputEntry{
				Request:  entry.Request,
				Response: respBytes,
			}
			continue
		}

		// Process the token request
		tokenFile := filepath.Join(tokenDir, fmt.Sprintf("%s-%s", origin, access))
		expectedFiles[tokenFile] = true

		resp := processToken(client, origin, access, tokenFile, now)
		respBytes, _ := json.Marshal(resp)
		output[key] = OutputEntry{
			Request:  entry.Request,
			Response: respBytes,
		}
	}

	// Garbage collection: revoke tokens for files that shouldn't exist
	garbageCollect(client, expectedFiles)

	return output, nil
}

// processToken handles a single token request
func processToken(client *ForgejoClient, origin, access, tokenFile string, now int64) TokenResponse {
	tokenName := fmt.Sprintf("%s-%s", origin, access)
	scopes := "read:repository"
	if access == "rw" {
		scopes = "read:repository,write:repository"
	}

	// Check if we have a valid cached token
	if stored, err := loadStoredToken(tokenFile); err == nil {
		remaining := stored.Expiry - now
		if remaining > rotationThreshold {
			// Token still valid, reuse it
			return TokenResponse{
				Token:    stored.Token,
				Username: username,
				TTL:      remaining,
			}
		}
		fmt.Fprintf(os.Stderr, "Rotating token %s (%ds remaining)\n", tokenName, remaining)
	}

	// Need to generate new token
	fmt.Fprintf(os.Stderr, "Regenerating token: %s with scopes: %s\n", tokenName, scopes)

	// Revoke old token first (if exists)
	client.RevokeToken(tokenName)

	// Generate new token
	token, err := client.GenerateToken(tokenName, scopes)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Generate token failed: %v\n", err)
		return TokenResponse{Error: "failed to generate token"}
	}

	// Store token with expiry
	expiry := now + tokenTTL
	if err := saveStoredToken(tokenFile, token, expiry); err != nil {
		fmt.Fprintf(os.Stderr, "Warning: failed to save token file: %v\n", err)
	}

	return TokenResponse{
		Token:    token,
		Username: username,
		TTL:      tokenTTL,
	}
}

// loadStoredToken reads a token from disk
func loadStoredToken(path string) (*StoredToken, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var stored StoredToken
	if err := json.Unmarshal(data, &stored); err != nil {
		// Try to handle old plain-text format
		return nil, fmt.Errorf("invalid token format")
	}

	if stored.Token == "" {
		return nil, fmt.Errorf("empty token")
	}

	return &stored, nil
}

// saveStoredToken writes a token to disk
func saveStoredToken(path, token string, expiry int64) error {
	stored := StoredToken{
		Token:  token,
		Expiry: expiry,
	}
	data, err := json.Marshal(stored)
	if err != nil {
		return err
	}

	// Write atomically via temp file
	tmpPath := path + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0600); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}

// garbageCollect removes orphaned tokens
func garbageCollect(client *ForgejoClient, expectedFiles map[string]bool) {
	entries, err := os.ReadDir(tokenDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "GC: failed to read token dir: %v\n", err)
		return
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		tokenFile := filepath.Join(tokenDir, entry.Name())
		if !expectedFiles[tokenFile] {
			tokenName := entry.Name()
			fmt.Fprintf(os.Stderr, "GC: revoking orphaned token %s\n", tokenName)
			client.RevokeToken(tokenName)
			if err := os.Remove(tokenFile); err != nil {
				fmt.Fprintf(os.Stderr, "GC: failed to remove %s: %v\n", tokenFile, err)
			}
		}
	}
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
