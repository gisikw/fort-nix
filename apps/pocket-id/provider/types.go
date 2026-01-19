package main

import "encoding/json"

// HandlerInput is the input format from fort-provider (symmetric format)
type HandlerInput map[string]InputEntry

// InputEntry contains the request and optional cached response for a single key
type InputEntry struct {
	Request  json.RawMessage `json:"request"`
	Response json.RawMessage `json:"response,omitempty"`
}

// HandlerOutput is the output format to fort-provider (symmetric format)
type HandlerOutput map[string]OutputEntry

// OutputEntry contains the echoed request and new response for a single key
type OutputEntry struct {
	Request  json.RawMessage `json:"request"`
	Response json.RawMessage `json:"response"`
}

// OIDCRequest is the request payload from consumers
type OIDCRequest struct {
	ClientName string   `json:"client_name"`
	Groups     []string `json:"groups,omitempty"`
	FortNeedID string   `json:"_fort_need_id,omitempty"`
}

// OIDCResponse is the response payload to consumers
type OIDCResponse struct {
	ClientID     string `json:"client_id,omitempty"`
	ClientSecret string `json:"client_secret,omitempty"`
	Error        string `json:"error,omitempty"`
}

// PocketIDClient represents an OIDC client in pocket-id
type PocketIDClient struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// PocketIDClientList is the paginated response from pocket-id
type PocketIDClientList struct {
	Data       []PocketIDClient `json:"data"`
	Pagination struct {
		CurrentPage int `json:"currentPage"`
		TotalPages  int `json:"totalPages"`
	} `json:"pagination"`
}

// PocketIDGroup represents a user group in pocket-id
type PocketIDGroup struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// PocketIDGroupList is the response from pocket-id group search
type PocketIDGroupList struct {
	Data []PocketIDGroup `json:"data"`
}

// SecretResponse is the response from generating a client secret
type SecretResponse struct {
	Secret string `json:"secret"`
}

// CreateClientRequest is the request body for creating an OIDC client
type CreateClientRequest struct {
	Name                    string   `json:"name"`
	CallbackURLs            []string `json:"callbackURLs"`
	LogoutCallbackURLs      []string `json:"logoutCallbackURLs"`
	IsPublic                bool     `json:"isPublic"`
	PKCEEnabled             bool     `json:"pkceEnabled"`
	RequiresReauthentication bool    `json:"requiresReauthentication"`
}

// AllowedGroupsRequest is the request body for setting allowed user groups
type AllowedGroupsRequest struct {
	UserGroupIDs []string `json:"userGroupIds"`
}
