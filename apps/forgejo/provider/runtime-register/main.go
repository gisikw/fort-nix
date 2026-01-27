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

const (
	defaultRegistryFile = "/var/lib/forgejo/runtime-packages.json"
)

// RegisterRequest is the incoming request payload
type RegisterRequest struct {
	Repo      string `json:"repo"`      // e.g., "infra/bz"
	StorePath string `json:"storePath"` // e.g., "/nix/store/..."
	Rev       string `json:"rev"`       // optional commit SHA
}

// RegisterResponse is the response payload
type RegisterResponse struct {
	Status    string `json:"status"`
	Repo      string `json:"repo,omitempty"`
	StorePath string `json:"storePath,omitempty"`
	Error     string `json:"error,omitempty"`
}

// PackageEntry represents a single package in the registry
type PackageEntry struct {
	StorePath string `json:"storePath"`
	Rev       string `json:"rev,omitempty"`
	UpdatedAt int64  `json:"updatedAt"`
}

// Registry is the stored package registry keyed by repo
type Registry map[string]PackageEntry

func main() {
	registryFile := getEnv("REGISTRY_FILE", defaultRegistryFile)

	// Read input from stdin
	inputData, err := io.ReadAll(os.Stdin)
	if err != nil {
		writeError("failed to read stdin: " + err.Error())
		return
	}

	var req RegisterRequest
	if err := json.Unmarshal(inputData, &req); err != nil {
		writeError("invalid JSON: " + err.Error())
		return
	}

	// Validate request
	if req.Repo == "" {
		writeError("repo is required")
		return
	}
	if req.StorePath == "" {
		writeError("storePath is required")
		return
	}

	// Validate repo format (owner/repo)
	parts := strings.Split(req.Repo, "/")
	if len(parts) != 2 {
		writeError("repo must be in owner/repo format")
		return
	}

	// Validate store path format
	if !strings.HasPrefix(req.StorePath, "/nix/store/") {
		writeError("storePath must be a valid nix store path")
		return
	}

	// Load existing registry
	registry, err := loadRegistry(registryFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Warning: creating new registry: %v\n", err)
		registry = make(Registry)
	}

	// Update registry
	registry[req.Repo] = PackageEntry{
		StorePath: req.StorePath,
		Rev:       req.Rev,
		UpdatedAt: time.Now().Unix(),
	}

	// Save registry
	if err := saveRegistry(registryFile, registry); err != nil {
		writeError("failed to save registry: " + err.Error())
		return
	}

	// Success response
	resp := RegisterResponse{
		Status:    "registered",
		Repo:      req.Repo,
		StorePath: req.StorePath,
	}
	writeResponse(resp)

	fmt.Fprintf(os.Stderr, "Registered %s -> %s\n", req.Repo, req.StorePath)
}

func getEnv(key, defaultVal string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultVal
}

func loadRegistry(path string) (Registry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var registry Registry
	if err := json.Unmarshal(data, &registry); err != nil {
		return nil, err
	}
	return registry, nil
}

func saveRegistry(path string, registry Registry) error {
	// Ensure directory exists
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}

	data, err := json.MarshalIndent(registry, "", "  ")
	if err != nil {
		return err
	}

	// Write atomically via temp file
	tmpPath := path + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0644); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}

func writeError(msg string) {
	resp := RegisterResponse{
		Status: "error",
		Error:  msg,
	}
	writeResponse(resp)
}

func writeResponse(resp RegisterResponse) {
	data, _ := json.Marshal(resp)
	os.Stdout.Write(data)
}
