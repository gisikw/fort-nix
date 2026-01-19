package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestGetAllClients_SinglePage(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/oidc/clients" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		resp := PocketIDClientList{
			Data: []PocketIDClient{
				{ID: "id1", Name: "client1"},
				{ID: "id2", Name: "client2"},
			},
		}
		resp.Pagination.CurrentPage = 1
		resp.Pagination.TotalPages = 1
		json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")
	clients, err := api.GetAllClients()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(clients) != 2 {
		t.Errorf("expected 2 clients, got %d", len(clients))
	}
	if clients[0].Name != "client1" {
		t.Errorf("expected client1, got %s", clients[0].Name)
	}
}

func TestGetAllClients_MultiplePages(t *testing.T) {
	callCount := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		var resp PocketIDClientList
		if callCount == 1 {
			resp.Data = []PocketIDClient{{ID: "id1", Name: "client1"}}
			resp.Pagination.CurrentPage = 1
			resp.Pagination.TotalPages = 2
		} else {
			resp.Data = []PocketIDClient{{ID: "id2", Name: "client2"}}
			resp.Pagination.CurrentPage = 2
			resp.Pagination.TotalPages = 2
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")
	clients, err := api.GetAllClients()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(clients) != 2 {
		t.Errorf("expected 2 clients from 2 pages, got %d", len(clients))
	}
	if callCount != 2 {
		t.Errorf("expected 2 API calls, got %d", callCount)
	}
}

func TestCreateClient(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			t.Errorf("expected POST, got %s", r.Method)
		}
		if r.URL.Path != "/api/oidc/clients" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		if r.Header.Get("X-API-KEY") != "test-key" {
			t.Errorf("missing or wrong API key")
		}

		var req CreateClientRequest
		json.NewDecoder(r.Body).Decode(&req)
		if req.Name != "test-client" {
			t.Errorf("expected name test-client, got %s", req.Name)
		}

		json.NewEncoder(w).Encode(PocketIDClient{ID: "new-id", Name: "test-client"})
	}))
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")
	client, err := api.CreateClient("test-client")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if client.ID != "new-id" {
		t.Errorf("expected id new-id, got %s", client.ID)
	}
}

func TestRegenerateSecret(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			t.Errorf("expected POST, got %s", r.Method)
		}
		if r.URL.Path != "/api/oidc/clients/client-id/secret" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		json.NewEncoder(w).Encode(SecretResponse{Secret: "new-secret-value"})
	}))
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")
	secret, err := api.RegenerateSecret("client-id")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if secret != "new-secret-value" {
		t.Errorf("expected new-secret-value, got %s", secret)
	}
}

func TestGetGroupID(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/user-groups" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		resp := PocketIDGroupList{
			Data: []PocketIDGroup{
				{ID: "group-uuid", Name: "users"},
				{ID: "other-uuid", Name: "admins"},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")

	id, err := api.GetGroupID("users")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if id != "group-uuid" {
		t.Errorf("expected group-uuid, got %s", id)
	}

	// Test not found
	id, err = api.GetGroupID("nonexistent")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if id != "" {
		t.Errorf("expected empty string for not found, got %s", id)
	}
}

func TestSetAllowedGroups(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "PUT" {
			t.Errorf("expected PUT, got %s", r.Method)
		}
		if r.URL.Path != "/api/oidc/clients/client-id/allowed-user-groups" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}

		var req AllowedGroupsRequest
		json.NewDecoder(r.Body).Decode(&req)
		if len(req.UserGroupIDs) != 2 {
			t.Errorf("expected 2 group IDs, got %d", len(req.UserGroupIDs))
		}

		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")
	err := api.SetAllowedGroups("client-id", []string{"group1", "group2"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDeleteClient(t *testing.T) {
	called := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		if r.Method != "DELETE" {
			t.Errorf("expected DELETE, got %s", r.Method)
		}
		if r.URL.Path != "/api/oidc/clients/client-to-delete" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	api := NewPocketIDAPI(server.URL, "test-key")
	err := api.DeleteClient("client-to-delete")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !called {
		t.Error("expected delete endpoint to be called")
	}
}

func TestFindClientByName(t *testing.T) {
	clients := []PocketIDClient{
		{ID: "id1", Name: "client1"},
		{ID: "id2", Name: "client2"},
	}

	found := FindClientByName(clients, "client2")
	if found == nil {
		t.Fatal("expected to find client2")
	}
	if found.ID != "id2" {
		t.Errorf("expected id2, got %s", found.ID)
	}

	notFound := FindClientByName(clients, "nonexistent")
	if notFound != nil {
		t.Error("expected nil for nonexistent client")
	}
}

func TestFindClientByID(t *testing.T) {
	clients := []PocketIDClient{
		{ID: "id1", Name: "client1"},
		{ID: "id2", Name: "client2"},
	}

	found := FindClientByID(clients, "id1")
	if found == nil {
		t.Fatal("expected to find id1")
	}
	if found.Name != "client1" {
		t.Errorf("expected client1, got %s", found.Name)
	}

	notFound := FindClientByID(clients, "nonexistent")
	if notFound != nil {
		t.Error("expected nil for nonexistent ID")
	}
}
