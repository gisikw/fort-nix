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

// TokenRequest is the request payload from consumers
type TokenRequest struct {
	Access     string `json:"access"` // "ro" or "rw"
	FortNeedID string `json:"_fort_need_id,omitempty"`
}

// TokenResponse is the response payload to consumers
type TokenResponse struct {
	Token    string `json:"token,omitempty"`
	Username string `json:"username,omitempty"`
	TTL      int64  `json:"ttl,omitempty"`
	Error    string `json:"error,omitempty"`
}

// StoredToken represents a token stored on disk with expiry
type StoredToken struct {
	Token  string `json:"token"`
	Expiry int64  `json:"expiry"`
}
