// Fort Provider - FastCGI capability handler
//
// Authenticates incoming requests using SSH signatures, enforces RBAC,
// and dispatches to handler scripts.
//
// Headers expected:
//   X-Fort-Origin: hostname of caller
//   X-Fort-Timestamp: unix timestamp of request
//   X-Fort-Signature: base64-encoded SSH signature (armor stripped)
//
// Signature format: ssh-keygen -Y sign over "METHOD\nPATH\nTIMESTAMP\nSHA256(body)"
//
// Handlers are pure workers: stdin=request JSON, stdout=response JSON.
// The wrapper handles persistence/GC based on capability config.

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/fcgi"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	configDir             = "/etc/fort"
	hostsFile             = configDir + "/hosts.json"
	rbacFile              = configDir + "/rbac.json"
	capabilitiesFile      = configDir + "/capabilities.json"
	needsFile             = configDir + "/needs.json"
	handlersDir           = configDir + "/handlers"
	handlesDir            = "/var/lib/fort/handles"
	fulfillmentStateFile  = "/var/lib/fort/fulfillment-state.json"
	providerStateFile     = "/var/lib/fort/provider-state.json"
	maxTimestampDrift     = 5 * time.Minute
	signatureNamespace    = "fort-agent" // Keep for signing compatibility during rollout
)

// HostInfo contains public key info for a peer host
type HostInfo struct {
	Pubkey string `json:"pubkey"`
}

// CapabilityConfig contains settings for a capability
type CapabilityConfig struct {
	NeedsGC       bool           `json:"needsGC"`
	TTL           int            `json:"ttl"` // seconds, 0 means no expiry
	Mode          string         `json:"mode"`          // "rpc" or "async"
	CacheResponse bool           `json:"cacheResponse"` // persist responses for reuse
	Triggers      TriggerConfig  `json:"triggers"`      // boot/systemd triggers
}

// TriggerConfig defines when to automatically invoke a capability handler
type TriggerConfig struct {
	Initialize bool     `json:"initialize"` // run on boot
	Systemd    []string `json:"systemd"`    // units that trigger re-run
}

// ProviderStateEntry tracks state for a single origin:need request
type ProviderStateEntry struct {
	Request   json.RawMessage `json:"request"`             // original request payload
	Response  json.RawMessage `json:"response,omitempty"`  // handler response (if fulfilled)
	UpdatedAt int64           `json:"updated_at"`          // unix timestamp of last update
}

// ProviderState is the full provider state: capability -> origin:need -> entry
type ProviderState map[string]map[string]ProviderStateEntry

// NeedConfig contains configuration for a declared need
type NeedConfig struct {
	ID         string                 `json:"id"`
	Capability string                 `json:"capability"`
	From       string                 `json:"from"`
	Request    map[string]interface{} `json:"request"`
	Handler    string                 `json:"handler"`
	NagSeconds int                    `json:"nag_seconds"`
}

// FulfillmentState tracks the state of a need
type FulfillmentState struct {
	Satisfied  bool  `json:"satisfied"`
	LastSought int64 `json:"last_sought"`
}

// AgentHandler implements http.Handler for the agent FastCGI
type AgentHandler struct {
	hosts         map[string]HostInfo         // hostname -> pubkey
	rbac          map[string][]string         // capability -> allowed hostnames
	capabilities  map[string]CapabilityConfig // capability -> config
	needs         map[string]NeedConfig       // need id -> config
	providerState ProviderState               // async capability state
}

func main() {
	handler, err := NewAgentHandler()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to initialize: %v\n", err)
		os.Exit(1)
	}

	// For socket activation, stdin is the connected socket
	listener, err := net.FileListener(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create listener from stdin: %v\n", err)
		os.Exit(1)
	}

	if err := fcgi.Serve(listener, handler); err != nil {
		fmt.Fprintf(os.Stderr, "fcgi serve error: %v\n", err)
		os.Exit(1)
	}
}

// NewAgentHandler loads configuration and returns a ready handler
func NewAgentHandler() (*AgentHandler, error) {
	h := &AgentHandler{
		hosts:         make(map[string]HostInfo),
		rbac:          make(map[string][]string),
		capabilities:  make(map[string]CapabilityConfig),
		needs:         make(map[string]NeedConfig),
		providerState: make(ProviderState),
	}

	// Load hosts.json
	hostsData, err := os.ReadFile(hostsFile)
	if err != nil {
		return nil, fmt.Errorf("read hosts.json: %w", err)
	}
	if err := json.Unmarshal(hostsData, &h.hosts); err != nil {
		return nil, fmt.Errorf("parse hosts.json: %w", err)
	}

	// Load rbac.json (optional - may not exist if no capabilities declared)
	rbacData, err := os.ReadFile(rbacFile)
	if err == nil {
		if err := json.Unmarshal(rbacData, &h.rbac); err != nil {
			return nil, fmt.Errorf("parse rbac.json: %w", err)
		}
	}

	// Load capabilities.json (optional)
	capData, err := os.ReadFile(capabilitiesFile)
	if err == nil {
		if err := json.Unmarshal(capData, &h.capabilities); err != nil {
			return nil, fmt.Errorf("parse capabilities.json: %w", err)
		}
	}

	// Load needs.json (optional - array of needs, indexed by id)
	needsData, err := os.ReadFile(needsFile)
	if err == nil {
		var needsList []NeedConfig
		if err := json.Unmarshal(needsData, &needsList); err != nil {
			return nil, fmt.Errorf("parse needs.json: %w", err)
		}
		for _, need := range needsList {
			h.needs[need.ID] = need
		}
	}

	// Load provider state (optional - persists across restarts)
	stateData, err := os.ReadFile(providerStateFile)
	if err == nil {
		if err := json.Unmarshal(stateData, &h.providerState); err != nil {
			return nil, fmt.Errorf("parse provider-state.json: %w", err)
		}
	}

	// Ensure handles directory exists
	os.MkdirAll(handlesDir, 0700)

	return h, nil
}

func (h *AgentHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path

	// Route: /fort/needs/<type>/<id> - callback from provider fulfilling a need
	if strings.HasPrefix(path, "/fort/needs/") {
		h.handleCallback(w, r, path)
		return
	}

	// Route: /fort/<capability> or /agent/<capability> (deprecated) - capability call
	var capability string
	switch {
	case strings.HasPrefix(path, "/fort/"):
		capability = strings.TrimPrefix(path, "/fort/")
	case strings.HasPrefix(path, "/agent/"):
		capability = strings.TrimPrefix(path, "/agent/")
	default:
		h.errorResponse(w, http.StatusNotFound, "invalid path")
		return
	}
	if capability == "" || strings.Contains(capability, "/") {
		h.errorResponse(w, http.StatusNotFound, "invalid capability")
		return
	}

	// Read request body
	body, err := io.ReadAll(r.Body)
	if err != nil {
		h.errorResponse(w, http.StatusBadRequest, "failed to read body")
		return
	}

	// Extract auth headers
	origin := r.Header.Get("X-Fort-Origin")
	timestampStr := r.Header.Get("X-Fort-Timestamp")
	signatureB64 := r.Header.Get("X-Fort-Signature")

	if origin == "" || timestampStr == "" || signatureB64 == "" {
		h.errorResponse(w, http.StatusUnauthorized, "missing auth headers")
		return
	}

	// Validate timestamp
	timestamp, err := strconv.ParseInt(timestampStr, 10, 64)
	if err != nil {
		h.errorResponse(w, http.StatusUnauthorized, "invalid timestamp")
		return
	}
	requestTime := time.Unix(timestamp, 0)
	drift := time.Since(requestTime)
	if drift < 0 {
		drift = -drift
	}
	if drift > maxTimestampDrift {
		h.errorResponse(w, http.StatusUnauthorized, "timestamp drift too large")
		return
	}

	// Look up origin's public key
	hostInfo, ok := h.hosts[origin]
	if !ok {
		h.errorResponse(w, http.StatusUnauthorized, "unknown origin")
		return
	}

	// Verify signature
	if err := h.verifySignature(r.Method, path, timestampStr, body, signatureB64, origin, hostInfo.Pubkey); err != nil {
		h.errorResponse(w, http.StatusUnauthorized, fmt.Sprintf("signature verification failed: %v", err))
		return
	}

	// Check RBAC
	allowedHosts, ok := h.rbac[capability]
	if !ok {
		h.errorResponse(w, http.StatusNotFound, "capability not found")
		return
	}
	allowed := false
	for _, host := range allowedHosts {
		if host == origin {
			allowed = true
			break
		}
	}
	if !allowed {
		h.errorResponse(w, http.StatusForbidden, "not authorized for this capability")
		return
	}

	// Execute handler
	handlerPath := filepath.Join(handlersDir, capability)
	if _, err := os.Stat(handlerPath); os.IsNotExist(err) {
		h.errorResponse(w, http.StatusNotFound, "handler not found")
		return
	}

	// Get capability config for GC handling
	capConfig := h.capabilities[capability]

	h.executeHandler(w, handlerPath, capability, origin, body, capConfig)
}

// verifySignature checks the SSH signature against the canonical request string
func (h *AgentHandler) verifySignature(method, path, timestamp string, body []byte, signatureB64, origin, pubkey string) error {
	// Build canonical string: METHOD\nPATH\nTIMESTAMP\nSHA256(body)
	bodyHash := sha256.Sum256(body)
	canonical := fmt.Sprintf("%s\n%s\n%s\n%s", method, path, timestamp, hex.EncodeToString(bodyHash[:]))

	// Decode signature from base64
	sigBytes, err := base64.StdEncoding.DecodeString(signatureB64)
	if err != nil {
		return fmt.Errorf("decode signature: %w", err)
	}

	// Create temp files for ssh-keygen -Y verify
	tmpDir, err := os.MkdirTemp("", "fort-agent-verify-")
	if err != nil {
		return fmt.Errorf("create temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	// Write allowed_signers file
	allowedSignersPath := filepath.Join(tmpDir, "allowed_signers")
	allowedSigners := fmt.Sprintf("%s %s\n", origin, pubkey)
	if err := os.WriteFile(allowedSignersPath, []byte(allowedSigners), 0600); err != nil {
		return fmt.Errorf("write allowed_signers: %w", err)
	}

	// Write signature file (re-armor it)
	sigPath := filepath.Join(tmpDir, "signature")
	armoredSig := armorSignature(sigBytes)
	if err := os.WriteFile(sigPath, []byte(armoredSig), 0600); err != nil {
		return fmt.Errorf("write signature: %w", err)
	}

	// Run ssh-keygen -Y verify
	cmd := exec.Command("ssh-keygen", "-Y", "verify",
		"-f", allowedSignersPath,
		"-n", signatureNamespace,
		"-I", origin,
		"-s", sigPath,
	)
	cmd.Stdin = strings.NewReader(canonical)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ssh-keygen verify: %s", strings.TrimSpace(string(output)))
	}

	return nil
}

// armorSignature wraps raw signature bytes in SSH signature armor
func armorSignature(sig []byte) string {
	encoded := base64.StdEncoding.EncodeToString(sig)
	var lines []string
	for i := 0; i < len(encoded); i += 70 {
		end := i + 70
		if end > len(encoded) {
			end = len(encoded)
		}
		lines = append(lines, encoded[i:end])
	}
	return "-----BEGIN SSH SIGNATURE-----\n" +
		strings.Join(lines, "\n") +
		"\n-----END SSH SIGNATURE-----\n"
}

// executeHandler runs the handler script and manages response/persistence
func (h *AgentHandler) executeHandler(w http.ResponseWriter, handlerPath, capability, origin string, body []byte, capConfig CapabilityConfig) {
	isAsync := capConfig.Mode == "async" || capConfig.NeedsGC

	if isAsync {
		h.executeAsyncHandler(w, handlerPath, capability, origin, body, capConfig)
	} else {
		h.executeRpcHandler(w, handlerPath, capability, origin, body)
	}
}

// executeRpcHandler runs a synchronous RPC-style handler (single request/response)
func (h *AgentHandler) executeRpcHandler(w http.ResponseWriter, handlerPath, capability, origin string, body []byte) {
	cmd := exec.Command(handlerPath)
	cmd.Stdin = strings.NewReader(string(body))
	cmd.Env = append(os.Environ(),
		"FORT_ORIGIN="+origin,
		"FORT_CAPABILITY="+capability,
	)

	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			h.errorResponse(w, http.StatusInternalServerError,
				fmt.Sprintf("handler failed: %s", strings.TrimSpace(string(exitErr.Stderr))))
		} else {
			h.errorResponse(w, http.StatusInternalServerError,
				fmt.Sprintf("handler exec failed: %v", err))
		}
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write(output)
}

// AsyncHandlerInput is the aggregate input format for async handlers
// Key is origin, value contains request and previous response (if any)
type AsyncHandlerInput map[string]struct {
	Request  json.RawMessage `json:"request"`
	Response json.RawMessage `json:"response,omitempty"`
}

// AsyncHandlerOutput is the aggregate output format from async handlers
// Key is origin, value is the response for that origin
type AsyncHandlerOutput map[string]json.RawMessage

// executeAsyncHandler runs an async handler with aggregate state
func (h *AgentHandler) executeAsyncHandler(w http.ResponseWriter, handlerPath, capability, origin string, body []byte, capConfig CapabilityConfig) {
	// Record the new/updated request in state
	h.recordProviderRequest(capability, origin, json.RawMessage(body))

	// Build aggregate input from all state entries for this capability
	state := h.getProviderState(capability)
	input := make(AsyncHandlerInput)
	for key, entry := range state {
		input[key] = struct {
			Request  json.RawMessage `json:"request"`
			Response json.RawMessage `json:"response,omitempty"`
		}{
			Request:  entry.Request,
			Response: entry.Response,
		}
	}

	inputBytes, err := json.Marshal(input)
	if err != nil {
		h.errorResponse(w, http.StatusInternalServerError, "failed to marshal handler input")
		return
	}

	// Invoke handler with aggregate input
	cmd := exec.Command(handlerPath)
	cmd.Stdin = bytes.NewReader(inputBytes)
	cmd.Env = append(os.Environ(),
		"FORT_ORIGIN="+origin,
		"FORT_CAPABILITY="+capability,
		"FORT_MODE=async",
	)

	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			h.errorResponse(w, http.StatusInternalServerError,
				fmt.Sprintf("handler failed: %s", strings.TrimSpace(string(exitErr.Stderr))))
		} else {
			h.errorResponse(w, http.StatusInternalServerError,
				fmt.Sprintf("handler exec failed: %v", err))
		}
		return
	}

	// Parse aggregate output
	var handlerOutput AsyncHandlerOutput
	if err := json.Unmarshal(output, &handlerOutput); err != nil {
		h.errorResponse(w, http.StatusInternalServerError,
			fmt.Sprintf("handler returned invalid JSON: %v", err))
		return
	}

	// Process responses and detect changes
	var changedOrigins []string
	for respOrigin, response := range handlerOutput {
		previousResponse := state[respOrigin].Response
		if !bytes.Equal(previousResponse, response) {
			changedOrigins = append(changedOrigins, respOrigin)
		}
		h.updateProviderResponse(capability, respOrigin, response)
	}

	// Persist updated state
	if err := h.saveProviderState(); err != nil {
		fmt.Fprintf(os.Stderr, "warning: failed to save provider state: %v\n", err)
	}

	// Log changed origins for debugging (callback dispatch is fort-c8y.12)
	if len(changedOrigins) > 0 {
		fmt.Fprintf(os.Stderr, "[%s] responses changed for: %v\n", capability, changedOrigins)
	}

	// Get response for the triggering origin
	triggerResponse, ok := handlerOutput[origin]
	if !ok {
		// Handler didn't return response for this origin - use empty object
		triggerResponse = json.RawMessage("{}")
	}

	// If capability needs GC, compute handle for the triggering origin's response
	if capConfig.NeedsGC {
		handle := computeHandle(triggerResponse)
		if err := h.persistHandle(handle, triggerResponse, capConfig.TTL); err != nil {
			h.errorResponse(w, http.StatusInternalServerError,
				fmt.Sprintf("failed to persist handle: %v", err))
			return
		}

		w.Header().Set("X-Fort-Handle", handle)
		if capConfig.TTL > 0 {
			w.Header().Set("X-Fort-TTL", strconv.Itoa(capConfig.TTL))
		}
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write(triggerResponse)
}

// computeHandle generates a content-addressed handle for the response
func computeHandle(data []byte) string {
	hash := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(hash[:])
}

// persistHandle stores the response data under the given handle
func (h *AgentHandler) persistHandle(handle string, data []byte, ttl int) error {
	// Use handle as filename (replace : with -)
	filename := strings.ReplaceAll(handle, ":", "-")
	handlePath := filepath.Join(handlesDir, filename)

	// Write data
	if err := os.WriteFile(handlePath, data, 0600); err != nil {
		return err
	}

	// Write metadata (expiry time)
	if ttl > 0 {
		expiry := time.Now().Add(time.Duration(ttl) * time.Second)
		metaPath := handlePath + ".meta"
		meta := map[string]interface{}{
			"expiry": expiry.Unix(),
			"ttl":    ttl,
		}
		metaData, _ := json.Marshal(meta)
		if err := os.WriteFile(metaPath, metaData, 0600); err != nil {
			return err
		}
	}

	return nil
}

func (h *AgentHandler) errorResponse(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": message})
}

// handleCallback processes POST /fort/needs/<type>/<id> - provider fulfilling a need
func (h *AgentHandler) handleCallback(w http.ResponseWriter, r *http.Request, path string) {
	// Parse path: /fort/needs/<capability>/<name> -> need id "<capability>-<name>"
	suffix := strings.TrimPrefix(path, "/fort/needs/")
	parts := strings.SplitN(suffix, "/", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		h.errorResponse(w, http.StatusNotFound, "invalid callback path")
		return
	}
	capability := parts[0]
	name := parts[1]
	needID := capability + "-" + name

	// Read request body
	body, err := io.ReadAll(r.Body)
	if err != nil {
		h.errorResponse(w, http.StatusBadRequest, "failed to read body")
		return
	}

	// Extract and validate auth headers
	origin := r.Header.Get("X-Fort-Origin")
	timestampStr := r.Header.Get("X-Fort-Timestamp")
	signatureB64 := r.Header.Get("X-Fort-Signature")

	if origin == "" || timestampStr == "" || signatureB64 == "" {
		h.errorResponse(w, http.StatusUnauthorized, "missing auth headers")
		return
	}

	// Validate timestamp
	timestamp, err := strconv.ParseInt(timestampStr, 10, 64)
	if err != nil {
		h.errorResponse(w, http.StatusUnauthorized, "invalid timestamp")
		return
	}
	requestTime := time.Unix(timestamp, 0)
	drift := time.Since(requestTime)
	if drift < 0 {
		drift = -drift
	}
	if drift > maxTimestampDrift {
		h.errorResponse(w, http.StatusUnauthorized, "timestamp drift too large")
		return
	}

	// Look up origin's public key
	hostInfo, ok := h.hosts[origin]
	if !ok {
		h.errorResponse(w, http.StatusUnauthorized, "unknown origin")
		return
	}

	// Verify signature
	if err := h.verifySignature(r.Method, path, timestampStr, body, signatureB64, origin, hostInfo.Pubkey); err != nil {
		h.errorResponse(w, http.StatusUnauthorized, fmt.Sprintf("signature verification failed: %v", err))
		return
	}

	// Look up the need configuration
	need, ok := h.needs[needID]
	if !ok {
		h.errorResponse(w, http.StatusNotFound, "need not found")
		return
	}

	// Verify caller is the declared provider for this need
	if origin != need.From {
		h.errorResponse(w, http.StatusForbidden, fmt.Sprintf("caller %s is not the declared provider %s", origin, need.From))
		return
	}

	// Determine satisfaction based on handler or payload
	var satisfied bool

	if need.Handler != "" {
		// Handler specified: invoke it with payload on stdin
		cmd := exec.Command(need.Handler)
		cmd.Stdin = strings.NewReader(string(body))
		cmd.Env = append(os.Environ(),
			"FORT_ORIGIN="+origin,
			"FORT_NEED_ID="+needID,
			"FORT_CAPABILITY="+capability,
		)

		if err := cmd.Run(); err != nil {
			// Handler failed - need becomes unsatisfied
			satisfied = false
		} else {
			// Handler succeeded - need is satisfied
			satisfied = true
		}
	} else {
		// No handler: interpret payload directly
		// Non-empty payload = satisfied, empty = unsatisfied (revocation)
		satisfied = len(bytes.TrimSpace(body)) > 0
	}

	// Update fulfillment state
	if err := h.updateFulfillmentState(needID, satisfied); err != nil {
		h.errorResponse(w, http.StatusInternalServerError, fmt.Sprintf("failed to update state: %v", err))
		return
	}

	// Return success
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"need_id":   needID,
		"satisfied": satisfied,
	})
}

// updateFulfillmentState updates the fulfillment state for a need
func (h *AgentHandler) updateFulfillmentState(needID string, satisfied bool) error {
	// Read current state
	state := make(map[string]FulfillmentState)
	data, err := os.ReadFile(fulfillmentStateFile)
	if err == nil {
		json.Unmarshal(data, &state)
	}

	// Update state for this need
	entry := state[needID]
	entry.Satisfied = satisfied
	// Keep last_sought unchanged - that's managed by the consumer
	state[needID] = entry

	// Write back
	newData, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal state: %w", err)
	}

	if err := os.WriteFile(fulfillmentStateFile, newData, 0644); err != nil {
		return fmt.Errorf("write state: %w", err)
	}

	return nil
}

// recordProviderRequest records an async capability request from an origin
// The key is "origin:needID" where needID comes from the request or is derived
func (h *AgentHandler) recordProviderRequest(capability, origin string, request json.RawMessage) {
	// Ensure capability map exists
	if h.providerState[capability] == nil {
		h.providerState[capability] = make(map[string]ProviderStateEntry)
	}

	// Key is just origin for now - could be origin:needID if request contains need identifier
	key := origin

	h.providerState[capability][key] = ProviderStateEntry{
		Request:   request,
		UpdatedAt: time.Now().Unix(),
	}
}

// updateProviderResponse updates the response for an origin's request
func (h *AgentHandler) updateProviderResponse(capability, origin string, response json.RawMessage) {
	if h.providerState[capability] == nil {
		return
	}

	key := origin
	if entry, ok := h.providerState[capability][key]; ok {
		entry.Response = response
		entry.UpdatedAt = time.Now().Unix()
		h.providerState[capability][key] = entry
	}
}

// saveProviderState persists the provider state to disk
func (h *AgentHandler) saveProviderState() error {
	data, err := json.MarshalIndent(h.providerState, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal provider state: %w", err)
	}

	if err := os.WriteFile(providerStateFile, data, 0644); err != nil {
		return fmt.Errorf("write provider state: %w", err)
	}

	return nil
}

// getProviderState returns the current state for a capability (for async handlers)
func (h *AgentHandler) getProviderState(capability string) map[string]ProviderStateEntry {
	if h.providerState[capability] == nil {
		return make(map[string]ProviderStateEntry)
	}
	return h.providerState[capability]
}
