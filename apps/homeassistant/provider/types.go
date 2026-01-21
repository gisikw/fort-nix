package main

// NotifyRequest is the input format for the notify capability
type NotifyRequest struct {
	Title   string         `json:"title,omitempty"`
	Message string         `json:"message"`
	URL     string         `json:"url,omitempty"`
	Actions []NotifyAction `json:"actions,omitempty"`
}

// NotifyAction represents an actionable button in a notification
type NotifyAction struct {
	Action string `json:"action"`
	Title  string `json:"title"`
	URI    string `json:"uri,omitempty"`
}

// NotifyResponse is the output format for the notify capability
type NotifyResponse struct {
	Status string `json:"status,omitempty"`
	Error  string `json:"error,omitempty"`
}
