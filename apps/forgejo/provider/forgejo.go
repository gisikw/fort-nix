package main

import (
	"fmt"
	"os/exec"
	"strings"
)

// ForgejoClient handles interactions with Forgejo via CLI and sqlite
type ForgejoClient struct {
	forgejoPackage string
	suPath         string
	sqlite3Path    string
	workDir        string
	customDir      string
	dbPath         string
}

// NewForgejoClient creates a new client with paths to required binaries
func NewForgejoClient(forgejoPackage, suPath, sqlite3Path string) *ForgejoClient {
	return &ForgejoClient{
		forgejoPackage: forgejoPackage,
		suPath:         suPath,
		sqlite3Path:    sqlite3Path,
		workDir:        "/var/lib/forgejo",
		customDir:      "/var/lib/forgejo/custom",
		dbPath:         "/var/lib/forgejo/data/forgejo.db",
	}
}

// GenerateToken creates a new access token for forge-admin with given name and scopes
func (c *ForgejoClient) GenerateToken(tokenName, scopes string) (string, error) {
	// Build the command to run as forgejo user
	forgejoCmd := fmt.Sprintf(
		"GITEA_WORK_DIR=%s GITEA_CUSTOM=%s %s/bin/forgejo admin user generate-access-token --username forge-admin --token-name %s --scopes %s --raw",
		c.workDir, c.customDir, c.forgejoPackage, tokenName, scopes,
	)

	cmd := exec.Command(c.suPath, "-s", "/bin/sh", "forgejo", "-c", forgejoCmd)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("generate token failed: %w (output: %s)", err, string(output))
	}

	result := strings.TrimSpace(string(output))
	if strings.Contains(strings.ToLower(result), "error") {
		return "", fmt.Errorf("generate token failed: %s", result)
	}

	return result, nil
}

// RevokeToken deletes a token by name using sqlite directly
// The Forgejo API requires site admin but rejects token auth for this endpoint
func (c *ForgejoClient) RevokeToken(tokenName string) error {
	query := fmt.Sprintf("DELETE FROM access_token WHERE name = '%s';", tokenName)
	cmd := exec.Command(c.sqlite3Path, c.dbPath, query)
	output, err := cmd.CombinedOutput()
	if err != nil {
		// Log but don't fail - token may not exist
		fmt.Printf("revoke token warning: %v (output: %s)\n", err, string(output))
	}
	return nil
}
