package main

// LanIPRequest is the input format for the lan-ip capability
// Currently empty - no parameters needed
type LanIPRequest struct{}

// LanIPResponse is the output format for the lan-ip capability
type LanIPResponse struct {
	LanIP string `json:"lan_ip,omitempty"`
	Error string `json:"error,omitempty"`
}
