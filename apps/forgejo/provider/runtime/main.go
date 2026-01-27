package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

const (
	defaultRegistryFile = "/var/lib/forgejo/runtime-packages.json"
)

func main() {
	registryFile := getEnv("REGISTRY_FILE", defaultRegistryFile)

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

	// Load registry
	registry, err := loadRegistry(registryFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Warning: registry not found or invalid: %v\n", err)
		registry = make(Registry)
	}

	// Process entries
	output := processEntries(registry, input)

	writeOutput(output)
}

func getEnv(key, defaultVal string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultVal
}

// processEntries handles all runtime package requests
func processEntries(registry Registry, input HandlerInput) HandlerOutput {
	output := make(HandlerOutput)
	now := time.Now().Unix()

	for key, entry := range input {
		var req PackageRequest
		if err := json.Unmarshal(entry.Request, &req); err != nil {
			resp := PackageResponse{Error: "invalid request format"}
			respBytes, _ := json.Marshal(resp)
			output[key] = OutputEntry{
				Request:  entry.Request,
				Response: respBytes,
			}
			continue
		}

		// Default constraint to "main" (for backward compatibility, though we ignore it now)
		if req.Constraint == "" {
			req.Constraint = "main"
		}

		// Validate repo format (owner/repo)
		parts := strings.Split(req.Repo, "/")
		if len(parts) != 2 {
			resp := PackageResponse{Error: "repo must be in owner/repo format"}
			respBytes, _ := json.Marshal(resp)
			output[key] = OutputEntry{
				Request:  entry.Request,
				Response: respBytes,
			}
			continue
		}

		// Look up in registry
		pkgEntry, found := registry[req.Repo]
		if !found {
			resp := PackageResponse{Error: fmt.Sprintf("package not registered: %s", req.Repo)}
			respBytes, _ := json.Marshal(resp)
			output[key] = OutputEntry{
				Request:  entry.Request,
				Response: respBytes,
			}
			fmt.Fprintf(os.Stderr, "Package not found: %s\n", req.Repo)
			continue
		}

		// Check if cached response is still valid
		if entry.Response != nil {
			var cached PackageResponse
			if err := json.Unmarshal(entry.Response, &cached); err == nil && cached.Error == "" {
				// Check if registry entry is newer
				if pkgEntry.Rev == cached.Rev && pkgEntry.StorePath == cached.StorePath {
					// Cache is still valid
					fmt.Fprintf(os.Stderr, "Cache hit for %s (rev %s)\n", req.Repo, pkgEntry.Rev)
					output[key] = OutputEntry{
						Request:  entry.Request,
						Response: entry.Response,
					}
					continue
				}
			}
		}

		// Build response from registry
		resp := PackageResponse{
			Repo:      req.Repo,
			Rev:       pkgEntry.Rev,
			StorePath: pkgEntry.StorePath,
			UpdatedAt: now,
		}
		respBytes, _ := json.Marshal(resp)
		output[key] = OutputEntry{
			Request:  entry.Request,
			Response: respBytes,
		}

		fmt.Fprintf(os.Stderr, "Served %s -> rev %s, store path: %s\n",
			req.Repo, pkgEntry.Rev, pkgEntry.StorePath)
	}

	return output
}

// loadRegistry reads the package registry from disk
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

// writeOutput marshals and writes the handler output to stdout
func writeOutput(output HandlerOutput) {
	data, err := json.Marshal(output)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to marshal output: %v\n", err)
		os.Exit(1)
	}
	os.Stdout.Write(data)
}
