package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

// Default URL, can be overridden via ldflags at build time
var defaultPocketIDURL = "https://id.example.com"

func main() {
	// Read environment
	serviceKeyFile := os.Getenv("SERVICE_KEY_FILE")
	if serviceKeyFile == "" {
		serviceKeyFile = "/var/lib/pocket-id/service-key"
	}

	pocketIDURL := os.Getenv("POCKETID_URL")
	if pocketIDURL == "" {
		pocketIDURL = defaultPocketIDURL
	}

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

	// Read service key
	apiKey, err := os.ReadFile(serviceKeyFile)
	if err != nil || len(strings.TrimSpace(string(apiKey))) == 0 {
		// Service key not available - return error for all entries
		output := outputServiceKeyError(input)
		writeOutput(output)
		return
	}

	// Create API client
	api := NewPocketIDAPI(pocketIDURL, strings.TrimSpace(string(apiKey)))

	// Process all entries
	output, err := processEntries(api, input)
	if err != nil {
		fmt.Fprintf(os.Stderr, "processing failed: %v\n", err)
		os.Exit(1)
	}

	writeOutput(output)
}

// outputServiceKeyError returns error responses for all entries when service key is unavailable
func outputServiceKeyError(input HandlerInput) HandlerOutput {
	output := make(HandlerOutput)
	for key, entry := range input {
		resp := OIDCResponse{Error: "Service key not yet created"}
		respBytes, _ := json.Marshal(resp)
		output[key] = OutputEntry{
			Request:  entry.Request,
			Response: respBytes,
		}
	}
	return output
}

// writeOutput marshals and writes the handler output to stdout
func writeOutput(output HandlerOutput) {
	outputData, err := json.Marshal(output)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to marshal output: %v\n", err)
		os.Exit(1)
	}
	os.Stdout.Write(outputData)
}

// processEntries processes all input entries and returns the output
func processEntries(api *PocketIDAPI, input HandlerInput) (HandlerOutput, error) {
	// Get all existing clients upfront
	existingClients, err := api.GetAllClients()
	if err != nil {
		return nil, fmt.Errorf("failed to fetch clients: %w", err)
	}

	output := make(HandlerOutput)
	keptIDs := make(map[string]bool)

	for key, entry := range input {
		var req OIDCRequest
		if err := json.Unmarshal(entry.Request, &req); err != nil {
			resp := OIDCResponse{Error: "invalid request format"}
			respBytes, _ := json.Marshal(resp)
			output[key] = OutputEntry{
				Request:  entry.Request,
				Response: respBytes,
			}
			continue
		}

		if req.ClientName == "" {
			resp := OIDCResponse{Error: "client_name required in request"}
			respBytes, _ := json.Marshal(resp)
			output[key] = OutputEntry{
				Request:  entry.Request,
				Response: respBytes,
			}
			continue
		}

		resp := processClient(api, existingClients, req, entry.Response, keptIDs)
		respBytes, _ := json.Marshal(resp)
		output[key] = OutputEntry{
			Request:  entry.Request,
			Response: respBytes,
		}
	}

	// GC: Delete clients not in keptIDs
	if err := garbageCollect(api, keptIDs); err != nil {
		fmt.Fprintf(os.Stderr, "GC warning: %v\n", err)
	}

	return output, nil
}

// processClient handles a single OIDC client request
func processClient(api *PocketIDAPI, existing []PocketIDClient, req OIDCRequest, cachedResp json.RawMessage, keptIDs map[string]bool) OIDCResponse {
	// Resolve group IDs from names
	groupIDs, err := resolveGroupIDs(api, req.Groups)
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: failed to resolve some groups: %v\n", err)
	}

	// Check if we have a valid cached response
	if len(cachedResp) > 0 {
		var cached OIDCResponse
		if err := json.Unmarshal(cachedResp, &cached); err == nil && cached.ClientID != "" && cached.ClientSecret != "" {
			// Verify client still exists
			if client := FindClientByID(existing, cached.ClientID); client != nil {
				// Client exists - sync groups and reuse cached credentials
				if err := api.SetAllowedGroups(cached.ClientID, groupIDs); err != nil {
					fmt.Fprintf(os.Stderr, "warning: failed to sync groups for %s: %v\n", req.ClientName, err)
				}
				keptIDs[cached.ClientID] = true
				return cached
			}
		}
	}

	// Check if client exists by name
	if client := FindClientByName(existing, req.ClientName); client != nil {
		// Client exists but we don't have the secret cached - regenerate it
		if err := api.SetAllowedGroups(client.ID, groupIDs); err != nil {
			fmt.Fprintf(os.Stderr, "warning: failed to sync groups for %s: %v\n", req.ClientName, err)
		}

		secret, err := api.RegenerateSecret(client.ID)
		if err != nil {
			// Secret regeneration failed - try delete and recreate
			fmt.Fprintf(os.Stderr, "warning: secret regeneration failed for %s, recreating: %v\n", req.ClientName, err)
			if err := api.DeleteClient(client.ID); err != nil {
				return OIDCResponse{Error: fmt.Sprintf("Failed to delete client for recreation: %v", err)}
			}
			return createNewClient(api, req.ClientName, groupIDs, keptIDs)
		}

		keptIDs[client.ID] = true
		return OIDCResponse{
			ClientID:     client.ID,
			ClientSecret: secret,
		}
	}

	// Create new client
	return createNewClient(api, req.ClientName, groupIDs, keptIDs)
}

// createNewClient creates a new OIDC client
func createNewClient(api *PocketIDAPI, name string, groupIDs []string, keptIDs map[string]bool) OIDCResponse {
	client, err := api.CreateClient(name)
	if err != nil {
		return OIDCResponse{Error: fmt.Sprintf("Failed to create client: %v", err)}
	}

	// Set allowed groups
	if len(groupIDs) > 0 {
		if err := api.SetAllowedGroups(client.ID, groupIDs); err != nil {
			fmt.Fprintf(os.Stderr, "warning: failed to set groups for new client %s: %v\n", name, err)
		}
	}

	// Generate secret
	secret, err := api.RegenerateSecret(client.ID)
	if err != nil {
		return OIDCResponse{Error: fmt.Sprintf("Failed to generate secret: %v", err)}
	}

	keptIDs[client.ID] = true
	return OIDCResponse{
		ClientID:     client.ID,
		ClientSecret: secret,
	}
}

// resolveGroupIDs converts group names to group UUIDs
func resolveGroupIDs(api *PocketIDAPI, groupNames []string) ([]string, error) {
	if len(groupNames) == 0 {
		return []string{}, nil
	}

	var groupIDs []string
	var errs []string

	for _, name := range groupNames {
		id, err := api.GetGroupID(name)
		if err != nil {
			errs = append(errs, fmt.Sprintf("%s: %v", name, err))
			continue
		}
		if id == "" {
			errs = append(errs, fmt.Sprintf("%s: not found", name))
			continue
		}
		groupIDs = append(groupIDs, id)
	}

	if len(errs) > 0 {
		return groupIDs, fmt.Errorf("group resolution errors: %s", strings.Join(errs, "; "))
	}

	return groupIDs, nil
}

// garbageCollect deletes clients that aren't in the kept set
func garbageCollect(api *PocketIDAPI, keptIDs map[string]bool) error {
	// Re-fetch current clients
	clients, err := api.GetAllClients()
	if err != nil {
		return fmt.Errorf("failed to fetch clients for GC: %w", err)
	}

	var errs []string
	for _, client := range clients {
		if !keptIDs[client.ID] {
			fmt.Fprintf(os.Stderr, "GC: Deleting client %s (id: %s)\n", client.Name, client.ID)
			if err := api.DeleteClient(client.ID); err != nil {
				errs = append(errs, fmt.Sprintf("%s: %v", client.Name, err))
			}
		}
	}

	if len(errs) > 0 {
		return fmt.Errorf("GC errors: %s", strings.Join(errs, "; "))
	}

	return nil
}
