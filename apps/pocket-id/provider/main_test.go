package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// mockPocketID creates a test server that simulates pocket-id API
type mockPocketID struct {
	clients       map[string]PocketIDClient // id -> client
	groups        map[string]string         // name -> id
	clientSecrets map[string]string         // clientID -> secret
	nextClientID  int
}

func newMockPocketID() *mockPocketID {
	return &mockPocketID{
		clients:       make(map[string]PocketIDClient),
		groups:        make(map[string]string),
		clientSecrets: make(map[string]string),
		nextClientID:  1,
	}
}

func (m *mockPocketID) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.Method == "GET" && r.URL.Path == "/api/oidc/clients":
		var data []PocketIDClient
		for _, c := range m.clients {
			data = append(data, c)
		}
		resp := PocketIDClientList{Data: data}
		resp.Pagination.CurrentPage = 1
		resp.Pagination.TotalPages = 1
		json.NewEncoder(w).Encode(resp)

	case r.Method == "POST" && r.URL.Path == "/api/oidc/clients":
		var req CreateClientRequest
		json.NewDecoder(r.Body).Decode(&req)
		id := string(rune('a'+m.nextClientID)) + "-id"
		m.nextClientID++
		client := PocketIDClient{ID: id, Name: req.Name}
		m.clients[id] = client
		json.NewEncoder(w).Encode(client)

	case r.Method == "DELETE" && strings.HasPrefix(r.URL.Path, "/api/oidc/clients/"):
		id := strings.TrimPrefix(r.URL.Path, "/api/oidc/clients/")
		delete(m.clients, id)
		w.WriteHeader(http.StatusOK)

	case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/secret"):
		parts := strings.Split(r.URL.Path, "/")
		clientID := parts[len(parts)-2]
		secret := "secret-for-" + clientID
		m.clientSecrets[clientID] = secret
		json.NewEncoder(w).Encode(SecretResponse{Secret: secret})

	case r.Method == "PUT" && strings.HasSuffix(r.URL.Path, "/allowed-user-groups"):
		w.WriteHeader(http.StatusOK)

	case r.Method == "GET" && r.URL.Path == "/api/user-groups":
		var data []PocketIDGroup
		for name, id := range m.groups {
			data = append(data, PocketIDGroup{ID: id, Name: name})
		}
		json.NewEncoder(w).Encode(PocketIDGroupList{Data: data})

	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func TestProcessEntries_NewClient(t *testing.T) {
	mock := newMockPocketID()
	mock.groups["users"] = "users-uuid"
	server := httptest.NewServer(mock)
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")

	input := HandlerInput{
		"joker:oidc-register-outline": InputEntry{
			Request: json.RawMessage(`{"client_name":"outline.example.com","groups":["users"]}`),
		},
	}

	output, err := processEntries(api, input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	entry, ok := output["joker:oidc-register-outline"]
	if !ok {
		t.Fatal("expected output for joker:oidc-register-outline")
	}

	var resp OIDCResponse
	if err := json.Unmarshal(entry.Response, &resp); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}

	if resp.Error != "" {
		t.Errorf("unexpected error: %s", resp.Error)
	}
	if resp.ClientID == "" {
		t.Error("expected client_id to be set")
	}
	if resp.ClientSecret == "" {
		t.Error("expected client_secret to be set")
	}
}

func TestProcessEntries_CachedCredentials(t *testing.T) {
	mock := newMockPocketID()
	// Pre-populate an existing client
	mock.clients["existing-id"] = PocketIDClient{ID: "existing-id", Name: "outline.example.com"}
	server := httptest.NewServer(mock)
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")

	// Input includes cached response with valid credentials
	cachedResp, _ := json.Marshal(OIDCResponse{
		ClientID:     "existing-id",
		ClientSecret: "cached-secret",
	})

	input := HandlerInput{
		"joker:oidc-register-outline": InputEntry{
			Request:  json.RawMessage(`{"client_name":"outline.example.com"}`),
			Response: cachedResp,
		},
	}

	output, err := processEntries(api, input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp OIDCResponse
	json.Unmarshal(output["joker:oidc-register-outline"].Response, &resp)

	// Should reuse cached credentials
	if resp.ClientID != "existing-id" {
		t.Errorf("expected cached client_id, got %s", resp.ClientID)
	}
	if resp.ClientSecret != "cached-secret" {
		t.Errorf("expected cached secret, got %s", resp.ClientSecret)
	}
}

func TestProcessEntries_CachedClientDeleted(t *testing.T) {
	mock := newMockPocketID()
	// Client does NOT exist (was deleted)
	server := httptest.NewServer(mock)
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")

	// Input has cached response but client no longer exists
	cachedResp, _ := json.Marshal(OIDCResponse{
		ClientID:     "deleted-id",
		ClientSecret: "old-secret",
	})

	input := HandlerInput{
		"joker:oidc-register-outline": InputEntry{
			Request:  json.RawMessage(`{"client_name":"outline.example.com"}`),
			Response: cachedResp,
		},
	}

	output, err := processEntries(api, input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp OIDCResponse
	json.Unmarshal(output["joker:oidc-register-outline"].Response, &resp)

	// Should have created new client
	if resp.Error != "" {
		t.Errorf("unexpected error: %s", resp.Error)
	}
	if resp.ClientID == "deleted-id" {
		t.Error("should have new client_id, not old one")
	}
	if resp.ClientID == "" {
		t.Error("expected new client_id")
	}
}

func TestProcessEntries_ExistingByName(t *testing.T) {
	mock := newMockPocketID()
	// Client exists by name, but we don't have cached credentials
	mock.clients["name-match-id"] = PocketIDClient{ID: "name-match-id", Name: "outline.example.com"}
	server := httptest.NewServer(mock)
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")

	input := HandlerInput{
		"joker:oidc-register-outline": InputEntry{
			Request: json.RawMessage(`{"client_name":"outline.example.com"}`),
			// No cached response
		},
	}

	output, err := processEntries(api, input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp OIDCResponse
	json.Unmarshal(output["joker:oidc-register-outline"].Response, &resp)

	// Should reuse existing client and regenerate secret
	if resp.ClientID != "name-match-id" {
		t.Errorf("expected existing client_id, got %s", resp.ClientID)
	}
	if resp.ClientSecret == "" {
		t.Error("expected regenerated secret")
	}
}

func TestProcessEntries_GarbageCollection(t *testing.T) {
	mock := newMockPocketID()
	// Pre-populate with an orphan client
	mock.clients["orphan-id"] = PocketIDClient{ID: "orphan-id", Name: "orphan.example.com"}
	mock.clients["active-id"] = PocketIDClient{ID: "active-id", Name: "active.example.com"}
	server := httptest.NewServer(mock)
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")

	// Only request the active client
	cachedResp, _ := json.Marshal(OIDCResponse{
		ClientID:     "active-id",
		ClientSecret: "active-secret",
	})

	input := HandlerInput{
		"joker:oidc-register-active": InputEntry{
			Request:  json.RawMessage(`{"client_name":"active.example.com"}`),
			Response: cachedResp,
		},
	}

	_, err := processEntries(api, input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Orphan should be deleted
	if _, exists := mock.clients["orphan-id"]; exists {
		t.Error("orphan client should have been garbage collected")
	}
	// Active should remain
	if _, exists := mock.clients["active-id"]; !exists {
		t.Error("active client should still exist")
	}
}

func TestProcessEntries_InvalidRequest(t *testing.T) {
	mock := newMockPocketID()
	server := httptest.NewServer(mock)
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")

	input := HandlerInput{
		"bad-key": InputEntry{
			Request: json.RawMessage(`{invalid json`),
		},
	}

	output, err := processEntries(api, input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp OIDCResponse
	json.Unmarshal(output["bad-key"].Response, &resp)

	if resp.Error == "" {
		t.Error("expected error for invalid JSON")
	}
}

func TestProcessEntries_MissingClientName(t *testing.T) {
	mock := newMockPocketID()
	server := httptest.NewServer(mock)
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")

	input := HandlerInput{
		"no-name": InputEntry{
			Request: json.RawMessage(`{"groups":["users"]}`),
		},
	}

	output, err := processEntries(api, input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var resp OIDCResponse
	json.Unmarshal(output["no-name"].Response, &resp)

	if resp.Error == "" {
		t.Error("expected error for missing client_name")
	}
	if !strings.Contains(resp.Error, "client_name") {
		t.Errorf("error should mention client_name: %s", resp.Error)
	}
}

func TestOutputServiceKeyError(t *testing.T) {
	input := HandlerInput{
		"key1": InputEntry{Request: json.RawMessage(`{"client_name":"c1"}`)},
		"key2": InputEntry{Request: json.RawMessage(`{"client_name":"c2"}`)},
	}

	output := outputServiceKeyError(input)

	if len(output) != 2 {
		t.Errorf("expected 2 outputs, got %d", len(output))
	}

	for key, entry := range output {
		var resp OIDCResponse
		json.Unmarshal(entry.Response, &resp)
		if resp.Error == "" {
			t.Errorf("expected error for %s", key)
		}
		if !strings.Contains(resp.Error, "Service key") {
			t.Errorf("error should mention service key: %s", resp.Error)
		}
	}
}

func TestSymmetricOutputFormat(t *testing.T) {
	mock := newMockPocketID()
	server := httptest.NewServer(mock)
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")

	originalRequest := json.RawMessage(`{"client_name":"test.example.com"}`)
	input := HandlerInput{
		"host:need": InputEntry{
			Request: originalRequest,
		},
	}

	output, err := processEntries(api, input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	entry := output["host:need"]

	// Verify symmetric format: request is echoed back
	if string(entry.Request) != string(originalRequest) {
		t.Errorf("request not echoed: got %s, want %s", string(entry.Request), string(originalRequest))
	}

	// Verify response is present
	if len(entry.Response) == 0 {
		t.Error("expected response to be present")
	}
}
