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

// TokenRequest is the request payload from consumers (empty for attic-token)
type TokenRequest struct {
	FortNeedID string `json:"_fort_need_id,omitempty"`
}

// TokenResponse is the response payload to consumers
type TokenResponse struct {
	CacheURL   string `json:"cacheUrl,omitempty"`
	CacheName  string `json:"cacheName,omitempty"`
	PublicKey  string `json:"publicKey,omitempty"`
	PushToken  string `json:"pushToken,omitempty"`
	Error      string `json:"error,omitempty"`
}
