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
	configDir          = "/etc/fort"
	hostsFile          = configDir + "/hosts.json"
	rbacFile           = configDir + "/rbac.json"
	capabilitiesFile   = configDir + "/capabilities.json"
	handlersDir        = configDir + "/handlers"
	handlesDir         = "/var/lib/fort/handles"
	maxTimestampDrift  = 5 * time.Minute
	signatureNamespace = "fort-agent" // Keep for signing compatibility during rollout
)

// HostInfo contains public key info for a peer host
type HostInfo struct {
	Pubkey string `json:"pubkey"`
}

// CapabilityConfig contains settings for a capability
type CapabilityConfig struct {
	NeedsGC bool `json:"needsGC"`
	TTL     int  `json:"ttl"` // seconds, 0 means no expiry
}

// AgentHandler implements http.Handler for the agent FastCGI
type AgentHandler struct {
	hosts        map[string]HostInfo        // hostname -> pubkey
	rbac         map[string][]string        // capability -> allowed hostnames
	capabilities map[string]CapabilityConfig // capability -> config
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
		hosts:        make(map[string]HostInfo),
		rbac:         make(map[string][]string),
		capabilities: make(map[string]CapabilityConfig),
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

	// Ensure handles directory exists
	os.MkdirAll(handlesDir, 0700)

	return h, nil
}

func (h *AgentHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Extract capability from path: /fort/<capability> or /agent/<capability> (deprecated)
	path := r.URL.Path
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

	// If capability needs GC, compute handle and persist
	if capConfig.NeedsGC {
		handle := computeHandle(output)
		if err := h.persistHandle(handle, output, capConfig.TTL); err != nil {
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
	w.Write(output)
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
