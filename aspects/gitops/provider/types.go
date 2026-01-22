package main

// DeployRequest is the input format for the deploy capability
type DeployRequest struct {
	SHA string `json:"sha"`
}

// DeployResponse is the output format for the deploy capability
type DeployResponse struct {
	Status        string `json:"status,omitempty"`
	SHA           string `json:"sha,omitempty"`
	Output        string `json:"output,omitempty"`
	Note          string `json:"note,omitempty"`
	Error         string `json:"error,omitempty"`
	Expected      string `json:"expected,omitempty"`
	Pending       string `json:"pending,omitempty"`
	Details       string `json:"details,omitempty"`
	CommitMessage string `json:"commit_message,omitempty"`
}
