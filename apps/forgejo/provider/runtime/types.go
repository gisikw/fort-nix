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

// PackageRequest is the request payload from consumers
type PackageRequest struct {
	Repo       string `json:"repo"`       // e.g., "infra/bz"
	Constraint string `json:"constraint"` // branch/tag, default "main" (kept for backward compat)
}

// PackageResponse is the response payload to consumers
type PackageResponse struct {
	Repo      string `json:"repo,omitempty"`
	Rev       string `json:"rev,omitempty"`
	StorePath string `json:"storePath,omitempty"`
	UpdatedAt int64  `json:"updatedAt,omitempty"`
	Error     string `json:"error,omitempty"`
}

// Registry is the package registry keyed by repo
// Written by runtime-package-register, read by this provider
type Registry map[string]PackageEntry

// PackageEntry represents a single package in the registry
type PackageEntry struct {
	StorePath string `json:"storePath"`
	Rev       string `json:"rev,omitempty"`
	UpdatedAt int64  `json:"updatedAt"`
}
