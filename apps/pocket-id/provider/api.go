package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
)

// PocketIDAPI is the client for pocket-id REST API
type PocketIDAPI struct {
	baseURL    string
	apiKey     string
	httpClient *http.Client
}

// NewPocketIDAPI creates a new pocket-id API client
func NewPocketIDAPI(baseURL, apiKey string) *PocketIDAPI {
	return &PocketIDAPI{
		baseURL:    baseURL,
		apiKey:     apiKey,
		httpClient: &http.Client{},
	}
}

// SetHTTPClient allows injecting a mock client for testing
func (c *PocketIDAPI) SetHTTPClient(client *http.Client) {
	c.httpClient = client
}

// doRequest performs an authenticated API request
func (c *PocketIDAPI) doRequest(method, endpoint string, body interface{}) ([]byte, error) {
	var reqBody io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("marshal request body: %w", err)
		}
		reqBody = bytes.NewReader(data)
	}

	req, err := http.NewRequest(method, c.baseURL+endpoint, reqBody)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	req.Header.Set("X-API-KEY", c.apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("API error %d: %s", resp.StatusCode, string(respBody))
	}

	return respBody, nil
}

// GetAllClients fetches all OIDC clients with pagination
func (c *PocketIDAPI) GetAllClients() ([]PocketIDClient, error) {
	var allClients []PocketIDClient
	page := 1

	for {
		endpoint := fmt.Sprintf("/api/oidc/clients?pagination%%5Bpage%%5D=%d", page)
		body, err := c.doRequest("GET", endpoint, nil)
		if err != nil {
			return nil, fmt.Errorf("get clients page %d: %w", page, err)
		}

		var list PocketIDClientList
		if err := json.Unmarshal(body, &list); err != nil {
			return nil, fmt.Errorf("parse clients response: %w", err)
		}

		allClients = append(allClients, list.Data...)

		if list.Pagination.CurrentPage >= list.Pagination.TotalPages {
			break
		}
		page++
	}

	return allClients, nil
}

// CreateClient creates a new OIDC client and returns its info
func (c *PocketIDAPI) CreateClient(name string) (*PocketIDClient, error) {
	req := CreateClientRequest{
		Name:                    name,
		CallbackURLs:            []string{},
		LogoutCallbackURLs:      []string{},
		IsPublic:                false,
		PKCEEnabled:             false,
		RequiresReauthentication: false,
	}

	body, err := c.doRequest("POST", "/api/oidc/clients", req)
	if err != nil {
		return nil, fmt.Errorf("create client: %w", err)
	}

	var client PocketIDClient
	if err := json.Unmarshal(body, &client); err != nil {
		return nil, fmt.Errorf("parse create response: %w", err)
	}

	return &client, nil
}

// DeleteClient removes an OIDC client
func (c *PocketIDAPI) DeleteClient(clientID string) error {
	_, err := c.doRequest("DELETE", "/api/oidc/clients/"+clientID, nil)
	return err
}

// RegenerateSecret creates a new client secret and returns it
func (c *PocketIDAPI) RegenerateSecret(clientID string) (string, error) {
	body, err := c.doRequest("POST", "/api/oidc/clients/"+clientID+"/secret", struct{}{})
	if err != nil {
		return "", fmt.Errorf("regenerate secret: %w", err)
	}

	var resp SecretResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		return "", fmt.Errorf("parse secret response: %w", err)
	}

	return resp.Secret, nil
}

// GetGroupID looks up a group's UUID from its name
func (c *PocketIDAPI) GetGroupID(name string) (string, error) {
	endpoint := "/api/user-groups?search=" + url.QueryEscape(name)
	body, err := c.doRequest("GET", endpoint, nil)
	if err != nil {
		return "", fmt.Errorf("search groups: %w", err)
	}

	var list PocketIDGroupList
	if err := json.Unmarshal(body, &list); err != nil {
		return "", fmt.Errorf("parse groups response: %w", err)
	}

	// Find exact match by name
	for _, group := range list.Data {
		if group.Name == name {
			return group.ID, nil
		}
	}

	return "", nil // Not found
}

// SetAllowedGroups updates the allowed user groups for a client
func (c *PocketIDAPI) SetAllowedGroups(clientID string, groupIDs []string) error {
	req := AllowedGroupsRequest{UserGroupIDs: groupIDs}
	_, err := c.doRequest("PUT", "/api/oidc/clients/"+clientID+"/allowed-user-groups", req)
	return err
}

// FindClientByName finds a client by name in a list
func FindClientByName(clients []PocketIDClient, name string) *PocketIDClient {
	for i := range clients {
		if clients[i].Name == name {
			return &clients[i]
		}
	}
	return nil
}

// FindClientByID finds a client by ID in a list
func FindClientByID(clients []PocketIDClient, id string) *PocketIDClient {
	for i := range clients {
		if clients[i].ID == id {
			return &clients[i]
		}
	}
	return nil
}
