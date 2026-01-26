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
	Constraint string `json:"constraint"` // branch/tag, default "main"
}

// PackageResponse is the response payload to consumers
type PackageResponse struct {
	Repo      string `json:"repo,omitempty"`
	Rev       string `json:"rev,omitempty"`
	StorePath string `json:"storePath,omitempty"`
	UpdatedAt int64  `json:"updatedAt,omitempty"`
	Error     string `json:"error,omitempty"`
}

// Forgejo API types for workflow runs

// WorkflowRunsResponse is the response from GET /api/v1/repos/{owner}/{repo}/actions/runs
type WorkflowRunsResponse struct {
	TotalCount   int           `json:"total_count"`
	WorkflowRuns []WorkflowRun `json:"workflow_runs"`
}

// WorkflowRun represents a single workflow run
type WorkflowRun struct {
	ID         int64  `json:"id"`
	Status     string `json:"status"`     // "completed", "in_progress", etc.
	Conclusion string `json:"conclusion"` // "success", "failure", etc.
	HeadSHA    string `json:"head_sha"`
	HeadBranch string `json:"head_branch"`
	CreatedAt  string `json:"created_at"`
	UpdatedAt  string `json:"updated_at"`
}

// ArtifactsResponse is the response from GET /api/v1/repos/{owner}/{repo}/actions/runs/{run_id}/artifacts
type ArtifactsResponse struct {
	TotalCount int        `json:"total_count"`
	Artifacts  []Artifact `json:"artifacts"`
}

// Artifact represents a workflow artifact
type Artifact struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
	Size int64  `json:"size_in_bytes"`
}

// ProviderState tracks subscriptions for garbage collection
type ProviderState struct {
	Subscriptions map[string]SubscriptionEntry `json:"subscriptions"`
}

// SubscriptionEntry tracks a single subscription's state
type SubscriptionEntry struct {
	Repo       string `json:"repo"`
	Constraint string `json:"constraint"`
	Rev        string `json:"rev"`
	StorePath  string `json:"storePath"`
}
