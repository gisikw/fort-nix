package main

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// Configuration - can be overridden via ldflags or environment
var (
	defaultForgejoURL = "http://localhost:3001"
	defaultTokenFile  = "/var/lib/forgejo/bootstrap/admin-token"
	storePathArtifact = "store-path" // Name of artifact containing the store path
)

func main() {
	forgejoURL := getEnv("FORGEJO_URL", defaultForgejoURL)
	tokenFile := getEnv("TOKEN_FILE", defaultTokenFile)

	// Read admin token
	tokenBytes, err := os.ReadFile(tokenFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to read token file: %v\n", err)
		os.Exit(1)
	}
	token := strings.TrimSpace(string(tokenBytes))

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

	// Create API client
	client := &ForgejoClient{
		baseURL:    forgejoURL,
		token:      token,
		httpClient: &http.Client{Timeout: 30 * time.Second},
	}

	// Process entries
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

// ForgejoClient handles HTTP API interactions
type ForgejoClient struct {
	baseURL    string
	token      string
	httpClient *http.Client
}

// processEntries handles all runtime package requests
func processEntries(client *ForgejoClient, input HandlerInput) (HandlerOutput, error) {
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

		// Default constraint to "main"
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

		// Check if cached response is still valid
		if entry.Response != nil {
			var cached PackageResponse
			if err := json.Unmarshal(entry.Response, &cached); err == nil && cached.Error == "" {
				// Check if there's a newer build
				latestRev, _ := client.getLatestSuccessfulRev(parts[0], parts[1], req.Constraint)
				if latestRev == cached.Rev && cached.StorePath != "" {
					// Cache is still valid
					fmt.Fprintf(os.Stderr, "Cache hit for %s@%s (rev %s)\n", req.Repo, req.Constraint, latestRev)
					output[key] = OutputEntry{
						Request:  entry.Request,
						Response: entry.Response,
					}
					continue
				}
			}
		}

		// Fetch latest build info
		resp := fetchPackageInfo(client, parts[0], parts[1], req.Constraint, now)
		respBytes, _ := json.Marshal(resp)
		output[key] = OutputEntry{
			Request:  entry.Request,
			Response: respBytes,
		}

		if resp.Error == "" {
			fmt.Fprintf(os.Stderr, "Fetched %s@%s -> rev %s, store path: %s\n",
				req.Repo, req.Constraint, resp.Rev, resp.StorePath)
		} else {
			fmt.Fprintf(os.Stderr, "Error fetching %s@%s: %s\n", req.Repo, req.Constraint, resp.Error)
		}
	}

	return output, nil
}

// fetchPackageInfo queries Forgejo for latest build info
func fetchPackageInfo(client *ForgejoClient, owner, repo, branch string, now int64) PackageResponse {
	// Get latest successful workflow run
	run, err := client.getLatestSuccessfulRun(owner, repo, branch)
	if err != nil {
		return PackageResponse{Error: fmt.Sprintf("failed to get workflow runs: %v", err)}
	}
	if run == nil {
		return PackageResponse{Error: "no successful workflow runs found"}
	}

	// Get store path from artifact
	storePath, err := client.getStorePathArtifact(owner, repo, run.ID)
	if err != nil {
		return PackageResponse{Error: fmt.Sprintf("failed to get store path artifact: %v", err)}
	}

	return PackageResponse{
		Repo:      fmt.Sprintf("%s/%s", owner, repo),
		Rev:       run.HeadSHA,
		StorePath: storePath,
		UpdatedAt: now,
	}
}

// getLatestSuccessfulRev returns just the rev of the latest successful run (for cache checking)
func (c *ForgejoClient) getLatestSuccessfulRev(owner, repo, branch string) (string, error) {
	run, err := c.getLatestSuccessfulRun(owner, repo, branch)
	if err != nil || run == nil {
		return "", err
	}
	return run.HeadSHA, nil
}

// getLatestSuccessfulRun fetches the most recent successful workflow run for a branch
func (c *ForgejoClient) getLatestSuccessfulRun(owner, repo, branch string) (*WorkflowRun, error) {
	url := fmt.Sprintf("%s/api/v1/repos/%s/%s/actions/runs?status=success&branch=%s&limit=1",
		c.baseURL, owner, repo, branch)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "token "+c.token)
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("API error %d: %s", resp.StatusCode, string(body))
	}

	var runsResp WorkflowRunsResponse
	if err := json.NewDecoder(resp.Body).Decode(&runsResp); err != nil {
		return nil, err
	}

	if len(runsResp.WorkflowRuns) == 0 {
		return nil, nil
	}

	return &runsResp.WorkflowRuns[0], nil
}

// getStorePathArtifact downloads and extracts the store-path artifact
func (c *ForgejoClient) getStorePathArtifact(owner, repo string, runID int64) (string, error) {
	// First, list artifacts to find the store-path one
	listURL := fmt.Sprintf("%s/api/v1/repos/%s/%s/actions/runs/%d/artifacts",
		c.baseURL, owner, repo, runID)

	req, err := http.NewRequest("GET", listURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "token "+c.token)
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("list artifacts error %d: %s", resp.StatusCode, string(body))
	}

	var artifactsResp ArtifactsResponse
	if err := json.NewDecoder(resp.Body).Decode(&artifactsResp); err != nil {
		return "", err
	}

	// Find the store-path artifact
	var artifactID int64
	for _, a := range artifactsResp.Artifacts {
		if a.Name == storePathArtifact {
			artifactID = a.ID
			break
		}
	}

	if artifactID == 0 {
		return "", fmt.Errorf("artifact '%s' not found", storePathArtifact)
	}

	// Download the artifact (returns a zip file)
	downloadURL := fmt.Sprintf("%s/api/v1/repos/%s/%s/actions/artifacts/%d",
		c.baseURL, owner, repo, artifactID)

	req, err = http.NewRequest("GET", downloadURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "token "+c.token)

	resp, err = c.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("download artifact error %d: %s", resp.StatusCode, string(body))
	}

	// Read the zip content
	zipData, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	// Extract the store path from the zip
	storePath, err := extractStorePathFromZip(zipData)
	if err != nil {
		return "", err
	}

	return storePath, nil
}

// extractStorePathFromZip extracts the store path from a zip archive
func extractStorePathFromZip(data []byte) (string, error) {
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return "", fmt.Errorf("failed to read zip: %w", err)
	}

	// Look for a file containing the store path
	// The artifact could be a single file or directory structure
	for _, f := range reader.File {
		// Skip directories
		if f.FileInfo().IsDir() {
			continue
		}

		// Read the file content
		rc, err := f.Open()
		if err != nil {
			continue
		}
		content, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			continue
		}

		storePath := strings.TrimSpace(string(content))

		// Validate it looks like a store path
		if strings.HasPrefix(storePath, "/nix/store/") {
			return storePath, nil
		}
	}

	return "", fmt.Errorf("no valid store path found in artifact")
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
