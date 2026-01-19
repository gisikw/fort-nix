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
	NeedsGC       bool          `json:"needsGC"`
	TTL           int           `json:"ttl"`           // seconds, 0 means no expiry
	Mode          string        `json:"mode"`          // "rpc" or "async"
	CacheResponse bool          `json:"cacheResponse"` // persist responses for reuse
	Triggers      TriggerConfig `json:"triggers"`      // boot/systemd triggers
	Format        string        `json:"format"`        // "legacy" or "symmetric"
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
	// Check for --trigger mode (systemd trigger invocation)
	if len(os.Args) >= 3 && os.Args[1] == "--trigger" {
		capability := os.Args[2]
		if err := runTrigger(capability); err != nil {
			fmt.Fprintf(os.Stderr, "trigger failed: %v\n", err)
			os.Exit(1)
		}
		os.Exit(0)
	}

	// Check for --gc mode (garbage collection sweep)
	if len(os.Args) >= 2 && os.Args[1] == "--gc" {
		if err := runGC(); err != nil {
			fmt.Fprintf(os.Stderr, "gc failed: %v\n", err)
			os.Exit(1)
		}
		os.Exit(0)
	}

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

	// Run boot-time initialization for capabilities with triggers.initialize = true
	h.initializeCapabilities()

	return h, nil
}

// initializeCapabilities runs handlers for capabilities with triggers.initialize = true
func (h *AgentHandler) initializeCapabilities() {
	for capName, capConfig := range h.capabilities {
		if !capConfig.Triggers.Initialize {
			continue
		}

		// Get existing state for this capability
		state := h.getProviderState(capName)
		if len(state) == 0 {
			fmt.Fprintf(os.Stderr, "[init] %s: no persisted state, skipping\n", capName)
			continue
		}

		fmt.Fprintf(os.Stderr, "[init] %s: initializing with %d entries\n", capName, len(state))

		// Build aggregate input from all state entries
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
			fmt.Fprintf(os.Stderr, "[init] %s: failed to marshal input: %v\n", capName, err)
			continue
		}

		// Invoke handler
		handlerPath := filepath.Join(handlersDir, capName)
		if _, err := os.Stat(handlerPath); os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "[init] %s: handler not found at %s\n", capName, handlerPath)
			continue
		}

		cmd := exec.Command(handlerPath)
		cmd.Stdin = bytes.NewReader(inputBytes)
		cmd.Env = append(os.Environ(),
			"FORT_CAPABILITY="+capName,
			"FORT_MODE=async",
			"FORT_TRIGGER=initialize",
		)

		output, err := cmd.Output()
		if err != nil {
			if exitErr, ok := err.(*exec.ExitError); ok {
				fmt.Fprintf(os.Stderr, "[init] %s: handler failed: %s\n", capName, strings.TrimSpace(string(exitErr.Stderr)))
			} else {
				fmt.Fprintf(os.Stderr, "[init] %s: handler exec failed: %v\n", capName, err)
			}
			continue
		}

		// Parse aggregate output (format-aware)
		handlerOutput, err := parseHandlerOutput(output, capConfig.Format)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[init] %s: handler returned invalid JSON: %v\n", capName, err)
			continue
		}

		// Process responses and detect changes
		var changedKeys []string
		for key, response := range handlerOutput {
			previousResponse := state[key].Response
			if !bytes.Equal(previousResponse, response) {
				changedKeys = append(changedKeys, key)
			}
			h.updateProviderResponse(capName, key, response)
		}

		// Persist updated state
		if err := h.saveProviderState(); err != nil {
			fmt.Fprintf(os.Stderr, "[init] %s: warning: failed to save provider state: %v\n", capName, err)
		}

		// Dispatch callbacks for all entries (at boot, we want to ensure all consumers have current data)
		if len(handlerOutput) > 0 {
			// At boot, dispatch callbacks for ALL entries, not just changed ones
			// This ensures consumers get current state even if provider restarted
			allKeys := make([]string, 0, len(handlerOutput))
			for key := range handlerOutput {
				allKeys = append(allKeys, key)
			}
			fmt.Fprintf(os.Stderr, "[init] %s: dispatching callbacks for %d entries\n", capName, len(allKeys))
			h.dispatchCallbacks(capName, allKeys, handlerOutput)
		}

		fmt.Fprintf(os.Stderr, "[init] %s: initialization complete\n", capName)
	}
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

// AsyncHandlerOutput is the aggregate output format from async handlers (legacy format)
// Key is origin, value is the response for that origin
type AsyncHandlerOutput map[string]json.RawMessage

// SymmetricHandlerOutput is the symmetric output format from async handlers
// Key is origin, value contains both request (echoed) and response
type SymmetricHandlerOutput map[string]struct {
	Request  json.RawMessage `json:"request"`
	Response json.RawMessage `json:"response"`
}

// parseHandlerOutput parses handler output based on format configuration
// Returns responses in the internal AsyncHandlerOutput format regardless of input format
func parseHandlerOutput(data []byte, format string) (AsyncHandlerOutput, error) {
	if format == "symmetric" {
		var sym SymmetricHandlerOutput
		if err := json.Unmarshal(data, &sym); err != nil {
			return nil, err
		}
		// Extract just responses for internal use
		result := make(AsyncHandlerOutput)
		for key, entry := range sym {
			result[key] = entry.Response
		}
		return result, nil
	}

	// Legacy format: key -> response directly
	var legacy AsyncHandlerOutput
	if err := json.Unmarshal(data, &legacy); err != nil {
		return nil, err
	}
	return legacy, nil
}

// executeAsyncHandler runs an async handler with aggregate state
func (h *AgentHandler) executeAsyncHandler(w http.ResponseWriter, handlerPath, capability, origin string, body []byte, capConfig CapabilityConfig) {
	// Record the new/updated request in state, get the state key for this request
	triggerKey := h.recordProviderRequest(capability, origin, json.RawMessage(body))

	// Build aggregate input from all state entries for this capability
	// Keys are in "origin:needID" format
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

	// Parse aggregate output (format-aware, keys are "origin:needID" format)
	handlerOutput, err := parseHandlerOutput(output, capConfig.Format)
	if err != nil {
		h.errorResponse(w, http.StatusInternalServerError,
			fmt.Sprintf("handler returned invalid JSON: %v", err))
		return
	}

	// Process responses and detect changes
	var changedKeys []string
	for key, response := range handlerOutput {
		previousResponse := state[key].Response
		if !bytes.Equal(previousResponse, response) {
			changedKeys = append(changedKeys, key)
		}
		h.updateProviderResponse(capability, key, response)
	}

	// Detect revocations: keys that had responses but are now absent from handler output
	var revokedKeys []string
	for key, entry := range state {
		if len(entry.Response) > 0 {
			if _, stillPresent := handlerOutput[key]; !stillPresent {
				revokedKeys = append(revokedKeys, key)
			}
		}
	}

	// Persist updated state
	if err := h.saveProviderState(); err != nil {
		fmt.Fprintf(os.Stderr, "warning: failed to save provider state: %v\n", err)
	}

	// Dispatch callbacks for changed responses (fire-and-forget)
	if len(changedKeys) > 0 {
		fmt.Fprintf(os.Stderr, "[%s] responses changed for: %v\n", capability, changedKeys)
		h.dispatchCallbacks(capability, changedKeys, handlerOutput)
	}

	// Dispatch revocation callbacks with empty payload
	if len(revokedKeys) > 0 {
		fmt.Fprintf(os.Stderr, "[%s] revoking: %v\n", capability, revokedKeys)
		emptyResponses := make(AsyncHandlerOutput)
		for _, key := range revokedKeys {
			emptyResponses[key] = json.RawMessage("{}")
		}
		h.dispatchCallbacks(capability, revokedKeys, emptyResponses)
	}

	// Get response for the triggering request (using full key, not just origin)
	triggerResponse, ok := handlerOutput[triggerKey]
	if !ok {
		// Handler didn't return response for this key - use empty object
		triggerResponse = json.RawMessage("{}")
	}

	// If capability needs GC, compute handle for the triggering request's response
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

	// Return 202 Accepted for async capabilities
	// Credentials are delivered via callback, not in sync response
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	w.Write([]byte(`{"status":"accepted"}`))
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

		var stderr bytes.Buffer
		cmd.Stderr = &stderr

		if err := cmd.Run(); err != nil {
			// Handler failed - need becomes unsatisfied
			fmt.Fprintf(os.Stderr, "[callback] handler failed for %s: %v\n", needID, err)
			if stderr.Len() > 0 {
				fmt.Fprintf(os.Stderr, "[callback] handler stderr: %s\n", stderr.String())
			}
			satisfied = false
		} else {
			// Handler succeeded - need is satisfied
			fmt.Fprintf(os.Stderr, "[callback] handler succeeded for %s\n", needID)
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
	fmt.Fprintf(os.Stderr, "[state] updating %s to satisfied=%v\n", needID, satisfied)

	// Read current state
	state := make(map[string]FulfillmentState)
	data, err := os.ReadFile(fulfillmentStateFile)
	if err == nil {
		json.Unmarshal(data, &state)
	} else {
		fmt.Fprintf(os.Stderr, "[state] no existing state file, starting fresh\n")
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

	fmt.Fprintf(os.Stderr, "[state] wrote %s satisfied=%v to %s\n", needID, satisfied, fulfillmentStateFile)
	return nil
}

// extractNeedID extracts _fort_need_id from a request, returns empty string if not present
func extractNeedID(request json.RawMessage) string {
	var req map[string]interface{}
	if err := json.Unmarshal(request, &req); err != nil {
		return ""
	}
	if needID, ok := req["_fort_need_id"].(string); ok {
		return needID
	}
	return ""
}

// makeStateKey creates the provider state key from origin and request
// Format: "origin:needID" if needID present, otherwise just "origin"
func makeStateKey(origin string, request json.RawMessage) string {
	needID := extractNeedID(request)
	if needID != "" {
		return origin + ":" + needID
	}
	return origin
}

// parseStateKey splits a state key into origin and needID
func parseStateKey(key string) (origin, needID string) {
	parts := strings.SplitN(key, ":", 2)
	origin = parts[0]
	if len(parts) > 1 {
		needID = parts[1]
	}
	return
}

// recordProviderRequest records an async capability request from an origin
// The key is "origin:needID" where needID comes from _fort_need_id in request
func (h *AgentHandler) recordProviderRequest(capability, origin string, request json.RawMessage) string {
	// Ensure capability map exists
	if h.providerState[capability] == nil {
		h.providerState[capability] = make(map[string]ProviderStateEntry)
	}

	key := makeStateKey(origin, request)

	h.providerState[capability][key] = ProviderStateEntry{
		Request:   request,
		UpdatedAt: time.Now().Unix(),
	}

	return key
}

// updateProviderResponse updates the response for a state key
// Skips caching if the response contains an "error" field
func (h *AgentHandler) updateProviderResponse(capability, key string, response json.RawMessage) {
	if h.providerState[capability] == nil {
		fmt.Fprintf(os.Stderr, "[%s] updateProviderResponse: capability state is nil for key %s\n", capability, key)
		return
	}

	// Check if response contains an error field - don't cache errors
	var respObj map[string]interface{}
	if err := json.Unmarshal(response, &respObj); err == nil {
		if _, hasError := respObj["error"]; hasError {
			fmt.Fprintf(os.Stderr, "[%s] skipping cache for %s: response contains error\n", capability, key)
			return
		}
	}

	if entry, ok := h.providerState[capability][key]; ok {
		entry.Response = response
		entry.UpdatedAt = time.Now().Unix()
		h.providerState[capability][key] = entry
		fmt.Fprintf(os.Stderr, "[%s] cached response for %s\n", capability, key)
	} else {
		fmt.Fprintf(os.Stderr, "[%s] updateProviderResponse: entry not found for key %s\n", capability, key)
	}
}

// saveProviderState persists the provider state to disk
func (h *AgentHandler) saveProviderState() error {
	// Debug: log state before save
	for cap, entries := range h.providerState {
		for key, entry := range entries {
			if len(entry.Response) > 0 {
				preview := string(entry.Response)
				if len(preview) > 50 {
					preview = preview[:50] + "..."
				}
				fmt.Fprintf(os.Stderr, "[save] %s/%s has response: %s\n", cap, key, preview)
			} else {
				fmt.Fprintf(os.Stderr, "[save] %s/%s has NO response\n", cap, key)
			}
		}
	}

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

// dispatchCallbacks sends responses to consumer callback endpoints (fire-and-forget)
// changedKeys is a list of state keys (origin:needID format) that have new responses
func (h *AgentHandler) dispatchCallbacks(capability string, changedKeys []string, responses AsyncHandlerOutput) {
	for _, key := range changedKeys {
		origin, needID := parseStateKey(key)
		if needID == "" {
			// No need ID, can't construct callback path
			fmt.Fprintf(os.Stderr, "[callback] skipping %s: no need ID\n", key)
			continue
		}

		response, ok := responses[key]
		if !ok {
			continue
		}

		// Construct callback URL: https://<origin>.fort.<domain>/fort/needs/<capability>/<name>
		// needID format is "<capability>-<name>", extract name
		name := strings.TrimPrefix(needID, capability+"-")
		callbackPath := fmt.Sprintf("/fort/needs/%s/%s", capability, name)

		// Fire-and-forget callback in goroutine
		go h.sendCallback(origin, callbackPath, response)
	}
}

// sendCallback POSTs a response to a consumer's callback endpoint
// This is fire-and-forget - errors are logged but not retried
func (h *AgentHandler) sendCallback(origin, path string, response json.RawMessage) {
	// Use fort CLI to send callback (it handles signing)
	// path is like "/fort/needs/oidc/outline" -> capability is "needs/oidc/outline"
	capability := strings.TrimPrefix(path, "/fort/")

	cmd := exec.Command("fort", origin, capability, string(response))
	output, err := cmd.CombinedOutput()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[callback] failed POST to %s%s: %v\n%s\n", origin, path, err, string(output))
		return
	}

	fmt.Fprintf(os.Stderr, "[callback] sent to %s%s\n", origin, path)
}

// runTrigger runs a capability handler in response to a systemd trigger
// This is invoked via: fort-provider --trigger <capability>
func runTrigger(capability string) error {
	fmt.Fprintf(os.Stderr, "[trigger] starting for capability: %s\n", capability)

	// Load capabilities config
	capData, err := os.ReadFile(capabilitiesFile)
	if err != nil {
		return fmt.Errorf("read capabilities.json: %w", err)
	}
	var capabilities map[string]CapabilityConfig
	if err := json.Unmarshal(capData, &capabilities); err != nil {
		return fmt.Errorf("parse capabilities.json: %w", err)
	}

	if _, ok := capabilities[capability]; !ok {
		return fmt.Errorf("capability %q not found in config", capability)
	}

	// Load provider state
	var providerState ProviderState
	stateData, err := os.ReadFile(providerStateFile)
	if err == nil {
		if err := json.Unmarshal(stateData, &providerState); err != nil {
			return fmt.Errorf("parse provider-state.json: %w", err)
		}
	} else {
		providerState = make(ProviderState)
	}

	// Get state for this capability
	state := providerState[capability]
	if state == nil || len(state) == 0 {
		fmt.Fprintf(os.Stderr, "[trigger] %s: no state entries, nothing to do\n", capability)
		return nil
	}

	fmt.Fprintf(os.Stderr, "[trigger] %s: processing %d entries\n", capability, len(state))

	// Build aggregate input from all state entries
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
		return fmt.Errorf("marshal input: %w", err)
	}

	// Invoke handler
	handlerPath := filepath.Join(handlersDir, capability)
	if _, err := os.Stat(handlerPath); os.IsNotExist(err) {
		return fmt.Errorf("handler not found: %s", handlerPath)
	}

	cmd := exec.Command(handlerPath)
	cmd.Stdin = bytes.NewReader(inputBytes)
	cmd.Env = append(os.Environ(),
		"FORT_CAPABILITY="+capability,
		"FORT_MODE=async",
		"FORT_TRIGGER=systemd",
	)

	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return fmt.Errorf("handler failed: %s", strings.TrimSpace(string(exitErr.Stderr)))
		}
		return fmt.Errorf("handler exec failed: %w", err)
	}

	// Parse aggregate output (format-aware)
	handlerOutput, err := parseHandlerOutput(output, capabilities[capability].Format)
	if err != nil {
		return fmt.Errorf("handler returned invalid JSON: %w", err)
	}

	// Process responses and detect changes
	var changedKeys []string
	for key, response := range handlerOutput {
		previousResponse := state[key].Response
		if !bytes.Equal(previousResponse, response) {
			changedKeys = append(changedKeys, key)
			fmt.Fprintf(os.Stderr, "[trigger] %s: response changed for %s\n", capability, key)
		}

		// Update state entry
		entry := state[key]
		entry.Response = response
		entry.UpdatedAt = time.Now().Unix()
		state[key] = entry
	}

	// Detect revocations: keys that had responses but are now absent from handler output
	var revokedKeys []string
	for key, entry := range state {
		if len(entry.Response) > 0 {
			if _, stillPresent := handlerOutput[key]; !stillPresent {
				revokedKeys = append(revokedKeys, key)
				fmt.Fprintf(os.Stderr, "[trigger] %s: revoking %s\n", capability, key)
			}
		}
	}

	providerState[capability] = state

	// Persist updated state
	stateBytes, err := json.MarshalIndent(providerState, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal provider state: %w", err)
	}
	if err := os.WriteFile(providerStateFile, stateBytes, 0644); err != nil {
		return fmt.Errorf("write provider state: %w", err)
	}

	// Create handler for callback dispatch
	h := &AgentHandler{
		providerState: providerState,
		capabilities:  capabilities,
	}

	// Dispatch callbacks for changed responses
	if len(changedKeys) > 0 {
		fmt.Fprintf(os.Stderr, "[trigger] %s: dispatching callbacks for %d changed entries\n", capability, len(changedKeys))
		h.dispatchCallbacks(capability, changedKeys, handlerOutput)
	}

	// Dispatch revocation callbacks with empty payload
	if len(revokedKeys) > 0 {
		fmt.Fprintf(os.Stderr, "[trigger] %s: dispatching revocations for %d entries\n", capability, len(revokedKeys))
		emptyResponses := make(AsyncHandlerOutput)
		for _, key := range revokedKeys {
			emptyResponses[key] = json.RawMessage("{}")
		}
		h.dispatchCallbacks(capability, revokedKeys, emptyResponses)
	}

	if len(changedKeys) == 0 && len(revokedKeys) == 0 {
		fmt.Fprintf(os.Stderr, "[trigger] %s: no changes\n", capability)
	}

	fmt.Fprintf(os.Stderr, "[trigger] %s: complete\n", capability)
	return nil
}

// runGC performs garbage collection sweep for async capabilities
// This is invoked via: fort-provider --gc
func runGC() error {
	fmt.Fprintf(os.Stderr, "[gc] starting garbage collection sweep\n")

	// Load capabilities config
	capData, err := os.ReadFile(capabilitiesFile)
	if err != nil {
		return fmt.Errorf("read capabilities.json: %w", err)
	}
	var capabilities map[string]CapabilityConfig
	if err := json.Unmarshal(capData, &capabilities); err != nil {
		return fmt.Errorf("parse capabilities.json: %w", err)
	}

	// Load provider state
	var providerState ProviderState
	stateData, err := os.ReadFile(providerStateFile)
	if err == nil {
		if err := json.Unmarshal(stateData, &providerState); err != nil {
			return fmt.Errorf("parse provider-state.json: %w", err)
		}
	} else {
		// No state file = nothing to GC
		fmt.Fprintf(os.Stderr, "[gc] no provider state, nothing to clean\n")
		return nil
	}

	if len(providerState) == 0 {
		fmt.Fprintf(os.Stderr, "[gc] provider state empty, nothing to clean\n")
		return nil
	}

	// Track which capabilities had entries removed (need handler re-invocation)
	modifiedCapabilities := make(map[string]bool)
	totalRemoved := 0

	// For each capability that needs GC (async mode)
	for capName, capConfig := range capabilities {
		if capConfig.Mode == "rpc" && !capConfig.NeedsGC {
			continue // RPC mode without needsGC doesn't need garbage collection
		}

		state := providerState[capName]
		if state == nil || len(state) == 0 {
			continue // No state for this capability
		}

		fmt.Fprintf(os.Stderr, "[gc] %s: checking %d entries\n", capName, len(state))

		// Collect unique origins from state entries
		origins := make(map[string]bool)
		for key := range state {
			origin, _ := parseStateKey(key)
			origins[origin] = true
		}

		// Query each origin for their declared needs
		originNeeds := make(map[string]map[string]bool) // origin -> set of need paths
		originReachable := make(map[string]bool)

		for origin := range origins {
			needs, err := queryOriginNeeds(origin)
			if err != nil {
				// Network failure - assume still in use, skip this origin
				fmt.Fprintf(os.Stderr, "[gc] %s: origin %s unreachable (%v), skipping\n", capName, origin, err)
				originReachable[origin] = false
				continue
			}
			originReachable[origin] = true
			originNeeds[origin] = needs
			fmt.Fprintf(os.Stderr, "[gc] %s: origin %s has %d declared needs\n", capName, origin, len(needs))
		}

		// Check each state entry against declared needs
		var keysToRemove []string
		for key := range state {
			origin, needID := parseStateKey(key)

			// Skip if origin was unreachable
			if !originReachable[origin] {
				continue
			}

			// Convert need_id "<capability>-<name>" to path "<capability>/<name>"
			needPath := needIDToPath(capName, needID)

			// Check if need is still declared
			if needs, ok := originNeeds[origin]; ok {
				if !needs[needPath] {
					// Positive absence: origin responded 200 but need not in list
					fmt.Fprintf(os.Stderr, "[gc] %s: removing orphaned entry %s (need %s not declared by %s)\n",
						capName, key, needPath, origin)
					keysToRemove = append(keysToRemove, key)
				}
			}
		}

		// Remove orphaned entries
		for _, key := range keysToRemove {
			delete(state, key)
			totalRemoved++
		}

		if len(keysToRemove) > 0 {
			providerState[capName] = state
			modifiedCapabilities[capName] = true
		}
	}

	// Persist updated state
	if totalRemoved > 0 {
		fmt.Fprintf(os.Stderr, "[gc] removed %d orphaned entries, saving state\n", totalRemoved)
		stateBytes, err := json.MarshalIndent(providerState, "", "  ")
		if err != nil {
			return fmt.Errorf("marshal provider state: %w", err)
		}
		if err := os.WriteFile(providerStateFile, stateBytes, 0644); err != nil {
			return fmt.Errorf("write provider state: %w", err)
		}
	}

	// Invoke handlers for modified capabilities (so they can clean up resources)
	for capName := range modifiedCapabilities {
		fmt.Fprintf(os.Stderr, "[gc] %s: invoking handler for cleanup\n", capName)
		if err := invokeHandlerForGC(capName, capabilities[capName], providerState[capName], false); err != nil {
			fmt.Fprintf(os.Stderr, "[gc] %s: handler invocation failed: %v\n", capName, err)
			// Continue with other capabilities, don't fail the whole GC
		}
	}

	// Check for entries nearing TTL expiry and rotate them
	// Rotation threshold: 2 hours (twice the GC interval)
	rotationThreshold := int64(2 * 60 * 60) // 2 hours in seconds
	now := time.Now().Unix()
	rotationNeeded := make(map[string]bool)

	for capName, capConfig := range capabilities {
		if capConfig.TTL <= 0 {
			continue // No TTL, no rotation needed
		}

		state := providerState[capName]
		if state == nil || len(state) == 0 {
			continue
		}

		// Check each entry for approaching expiry
		for key, entry := range state {
			if len(entry.Response) == 0 {
				continue // No response yet, nothing to rotate
			}

			expiry := entry.UpdatedAt + int64(capConfig.TTL)
			timeUntilExpiry := expiry - now

			if timeUntilExpiry <= rotationThreshold {
				fmt.Fprintf(os.Stderr, "[gc] %s: entry %s expires in %ds, scheduling rotation\n",
					capName, key, timeUntilExpiry)
				rotationNeeded[capName] = true
				break // One expiring entry is enough to trigger rotation for the capability
			}
		}
	}

	// Invoke handlers for capabilities needing rotation (with callback dispatch)
	for capName := range rotationNeeded {
		if modifiedCapabilities[capName] {
			continue // Already handled above
		}
		fmt.Fprintf(os.Stderr, "[gc] %s: invoking handler for TTL rotation\n", capName)
		if err := invokeHandlerForGC(capName, capabilities[capName], providerState[capName], true); err != nil {
			fmt.Fprintf(os.Stderr, "[gc] %s: rotation handler failed: %v\n", capName, err)
		}
	}

	fmt.Fprintf(os.Stderr, "[gc] complete, removed %d entries, rotated %d capabilities\n", totalRemoved, len(rotationNeeded))
	return nil
}

// queryOriginNeeds queries a host's /fort/needs endpoint and returns set of declared need paths
func queryOriginNeeds(origin string) (map[string]bool, error) {
	// Use fort CLI to query the needs endpoint
	cmd := exec.Command("fort", origin, "needs", "{}")
	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("fort command failed: %s", strings.TrimSpace(string(exitErr.Stderr)))
		}
		return nil, fmt.Errorf("fort command exec failed: %w", err)
	}

	// Parse the response envelope
	var envelope struct {
		Body   json.RawMessage `json:"body"`
		Status int             `json:"status"`
	}
	if err := json.Unmarshal(output, &envelope); err != nil {
		return nil, fmt.Errorf("parse fort response: %w", err)
	}

	// Check for successful response
	if envelope.Status < 200 || envelope.Status >= 300 {
		return nil, fmt.Errorf("origin returned HTTP %d", envelope.Status)
	}

	// Parse the needs list from body
	var needsResponse struct {
		Needs []string `json:"needs"`
	}
	if err := json.Unmarshal(envelope.Body, &needsResponse); err != nil {
		return nil, fmt.Errorf("parse needs response: %w", err)
	}

	// Convert to set for O(1) lookup
	needsSet := make(map[string]bool)
	for _, need := range needsResponse.Needs {
		needsSet[need] = true
	}

	return needsSet, nil
}

// needIDToPath converts a need ID (e.g., "oidc-register-outline") to path format (e.g., "oidc-register/outline")
// capName is the capability name, used to correctly split IDs where the capability contains hyphens
func needIDToPath(capName, needID string) string {
	// Need ID format: "<capability>-<name>"
	// Path format: "<capability>/<name>"
	// We use capName to find the correct split point since capabilities can contain hyphens
	prefix := capName + "-"
	if strings.HasPrefix(needID, prefix) {
		name := strings.TrimPrefix(needID, prefix)
		return capName + "/" + name
	}
	// Fallback for unexpected format: use last hyphen
	idx := strings.LastIndex(needID, "-")
	if idx == -1 {
		return needID // No hyphen, return as-is
	}
	return needID[:idx] + "/" + needID[idx+1:]
}

// invokeHandlerForGC invokes a capability handler after GC cleanup or for TTL rotation
// When dispatchCallbacks is true, sends callbacks for changed responses (used for rotation)
// When false, just updates state (used for cleanup after orphan removal)
func invokeHandlerForGC(capName string, capConfig CapabilityConfig, state map[string]ProviderStateEntry, dispatchCallbacks bool) error {
	handlerPath := filepath.Join(handlersDir, capName)
	if _, err := os.Stat(handlerPath); os.IsNotExist(err) {
		return fmt.Errorf("handler not found: %s", handlerPath)
	}

	// Build aggregate input from remaining state entries
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
		return fmt.Errorf("marshal input: %w", err)
	}

	cmd := exec.Command(handlerPath)
	cmd.Stdin = bytes.NewReader(inputBytes)
	cmd.Env = append(os.Environ(),
		"FORT_CAPABILITY="+capName,
		"FORT_MODE=async",
		"FORT_TRIGGER=gc",
	)

	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return fmt.Errorf("handler failed: %s", strings.TrimSpace(string(exitErr.Stderr)))
		}
		return fmt.Errorf("handler exec failed: %w", err)
	}

	// Parse handler output (format-aware)
	handlerOutput, err := parseHandlerOutput(output, capConfig.Format)
	if err != nil {
		return fmt.Errorf("handler returned invalid JSON: %w", err)
	}

	// Track changed responses for callback dispatch
	var changedKeys []string

	// Update state with any new responses from handler
	for key, response := range handlerOutput {
		if entry, ok := state[key]; ok {
			// Check if response changed
			if dispatchCallbacks && !bytes.Equal(entry.Response, response) {
				changedKeys = append(changedKeys, key)
			}
			entry.Response = response
			entry.UpdatedAt = time.Now().Unix()
			state[key] = entry
		}
	}

	// Dispatch callbacks for changed responses (rotation)
	if dispatchCallbacks && len(changedKeys) > 0 {
		fmt.Fprintf(os.Stderr, "[gc] %s: dispatching callbacks for %d rotated entries\n", capName, len(changedKeys))
		h := &AgentHandler{} // Minimal handler for dispatch
		h.dispatchCallbacks(capName, changedKeys, handlerOutput)
	}

	return nil
}
