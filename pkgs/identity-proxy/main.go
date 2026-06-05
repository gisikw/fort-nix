package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/BurntSushi/toml"
	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"
)

// Config holds runtime configuration loaded from environment variables.
type Config struct {
	ListenSocket     string
	IdentityDoc      string
	CookieSigningKey []byte
	CookieDomain     string
	SessionMaxAge    time.Duration
	OIDCIssuer       string
	OIDCClientID     string
	OIDCClientSecret string
}

// User represents an entry in the identity TOML document.
type User struct {
	HeadscaleID int      `toml:"headscale_id"`
	Emails      []string `toml:"emails"`
	Groups      []string `toml:"groups"`
}

// IdentityDoc maps display names to user records.
type IdentityDoc struct {
	Users map[string]User
	// Derived indexes for fast lookup
	byHeadscaleID map[int]*resolvedUser
	byEmail       map[string]*resolvedUser
}

type resolvedUser struct {
	Name   string
	Email  string // primary email (first in list), empty if none
	Groups []string
}

// SessionPayload is the signed cookie content.
type SessionPayload struct {
	Sub    string   `json:"sub"`
	Email  string   `json:"email"`
	Groups []string `json:"groups"`
	Exp    int64    `json:"exp"`
}

// WhoisCache caches tailscale whois results.
type WhoisCache struct {
	mu      sync.RWMutex
	entries map[string]*whoisEntry
	ttl     time.Duration
}

type whoisEntry struct {
	user      *resolvedUser
	err       error
	fetchedAt time.Time
}

func main() {
	cfg := loadConfig()
	doc := loadIdentityDoc(cfg.IdentityDoc)

	cache := &WhoisCache{
		entries: make(map[string]*whoisEntry),
		ttl:     5 * time.Minute,
	}

	// Set up OIDC provider
	ctx := context.Background()
	provider, err := oidc.NewProvider(ctx, cfg.OIDCIssuer)
	if err != nil {
		log.Fatalf("OIDC provider discovery failed: %v", err)
	}
	oauth2Config := &oauth2.Config{
		ClientID:     cfg.OIDCClientID,
		ClientSecret: cfg.OIDCClientSecret,
		Endpoint:     provider.Endpoint(),
		Scopes:       []string{oidc.ScopeOpenID, "email", "profile"},
	}
	verifier := provider.Verifier(&oidc.Config{ClientID: cfg.OIDCClientID})

	srv := &Server{
		cfg:          cfg,
		doc:          doc,
		cache:        cache,
		oauth2Config: oauth2Config,
		verifier:     verifier,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/_identity/validate", srv.handleValidate)
	mux.HandleFunc("/_identity/login", srv.handleLogin)
	mux.HandleFunc("/_identity/callback", srv.handleCallback)

	// Remove stale socket
	os.Remove(cfg.ListenSocket)

	listener, err := net.Listen("unix", cfg.ListenSocket)
	if err != nil {
		log.Fatalf("listen %s: %v", cfg.ListenSocket, err)
	}
	// nginx needs to connect
	os.Chmod(cfg.ListenSocket, 0660)

	httpServer := &http.Server{Handler: mux}

	go func() {
		log.Printf("identity-proxy listening on %s (%d users loaded)", cfg.ListenSocket, len(doc.Users))
		if err := httpServer.Serve(listener); err != http.ErrServerClosed {
			log.Fatalf("serve: %v", err)
		}
	}()

	// Graceful shutdown
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Println("shutting down")
	httpServer.Shutdown(context.Background())
}

func loadConfig() *Config {
	socket := envOr("LISTEN_SOCKET", "/run/identity-proxy/identity-proxy.sock")
	identityDoc := envRequired("IDENTITY_DOC")
	cookieDomain := envOr("COOKIE_DOMAIN", ".gisi.network")
	issuer := envOr("OIDC_ISSUER", "https://id.gisi.network")
	maxAge := envOr("SESSION_MAX_AGE", "86400")

	keyPath := envRequired("COOKIE_SIGNING_KEY")
	keyBytes, err := os.ReadFile(keyPath)
	if err != nil {
		log.Fatalf("read cookie signing key %s: %v", keyPath, err)
	}

	clientID, err := os.ReadFile(envRequired("OIDC_CLIENT_ID_FILE"))
	if err != nil {
		log.Fatalf("read client id: %v", err)
	}
	clientSecret, err := os.ReadFile(envRequired("OIDC_CLIENT_SECRET_FILE"))
	if err != nil {
		log.Fatalf("read client secret: %v", err)
	}

	dur, err := time.ParseDuration(maxAge + "s")
	if err != nil {
		dur = 24 * time.Hour
	}

	return &Config{
		ListenSocket:     socket,
		IdentityDoc:      identityDoc,
		CookieSigningKey: keyBytes,
		CookieDomain:     cookieDomain,
		SessionMaxAge:    dur,
		OIDCIssuer:       issuer,
		OIDCClientID:     strings.TrimSpace(string(clientID)),
		OIDCClientSecret: strings.TrimSpace(string(clientSecret)),
	}
}

func loadIdentityDoc(path string) *IdentityDoc {
	raw := make(map[string]User)
	if _, err := toml.DecodeFile(path, &raw); err != nil {
		log.Fatalf("load identity doc %s: %v", path, err)
	}

	doc := &IdentityDoc{
		Users:         raw,
		byHeadscaleID: make(map[int]*resolvedUser),
		byEmail:       make(map[string]*resolvedUser),
	}

	for name, u := range raw {
		ru := &resolvedUser{
			Name:   name,
			Groups: u.Groups,
		}
		if len(u.Emails) > 0 {
			ru.Email = u.Emails[0]
		}
		doc.byHeadscaleID[u.HeadscaleID] = ru
		for _, email := range u.Emails {
			doc.byEmail[strings.ToLower(email)] = ru
		}
	}

	return doc
}

func envRequired(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("required env var %s not set", key)
	}
	return v
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// Server holds all handler dependencies.
type Server struct {
	cfg          *Config
	doc          *IdentityDoc
	cache        *WhoisCache
	oauth2Config *oauth2.Config
	verifier     *oidc.IDTokenVerifier
}

// handleValidate is the nginx auth_request target.
func (s *Server) handleValidate(w http.ResponseWriter, r *http.Request) {
	requiredGroups := parseGroups(r.Header.Get("X-Identity-Required-Groups"))
	realIP := r.Header.Get("X-Real-IP")

	// Path 1: VPN — tailscale whois
	if isTailscaleIP(realIP) {
		user, err := s.cache.Lookup(realIP, s.doc)
		if err != nil {
			log.Printf("whois %s: %v", realIP, err)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if !checkGroups(user.Groups, requiredGroups) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		setIdentityHeaders(w, user)
		w.WriteHeader(http.StatusOK)
		return
	}

	// Path 2: Cookie session
	cookie, err := r.Cookie("_fort_identity")
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	payload, err := validateSession(cookie.Value, s.cfg.CookieSigningKey)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	if !checkGroups(payload.Groups, requiredGroups) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}

	setIdentityHeaders(w, &resolvedUser{
		Name:   payload.Sub,
		Email:  payload.Email,
		Groups: payload.Groups,
	})
	w.WriteHeader(http.StatusOK)
}

// handleLogin redirects to the OIDC authorization endpoint.
func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	rd := r.URL.Query().Get("rd")
	if rd == "" {
		rd = "https://" + r.Header.Get("X-Original-Host") + "/"
	}

	host := r.Header.Get("X-Original-Host")
	if host == "" {
		host = r.Host
	}

	// Build per-host callback URL
	cfg := *s.oauth2Config
	cfg.RedirectURL = "https://" + host + "/_identity/callback"

	authURL := cfg.AuthCodeURL(rd)
	http.Redirect(w, r, authURL, http.StatusFound)
}

// handleCallback handles the OIDC authorization code callback.
func (s *Server) handleCallback(w http.ResponseWriter, r *http.Request) {
	code := r.URL.Query().Get("code")
	state := r.URL.Query().Get("state") // contains the original rd URL

	if code == "" {
		http.Error(w, "missing code", http.StatusBadRequest)
		return
	}

	host := r.Host
	cfg := *s.oauth2Config
	cfg.RedirectURL = "https://" + host + "/_identity/callback"

	token, err := cfg.Exchange(r.Context(), code)
	if err != nil {
		log.Printf("OIDC token exchange: %v", err)
		http.Error(w, "authentication failed", http.StatusInternalServerError)
		return
	}

	rawIDToken, ok := token.Extra("id_token").(string)
	if !ok {
		http.Error(w, "missing id_token", http.StatusInternalServerError)
		return
	}

	idToken, err := s.verifier.Verify(r.Context(), rawIDToken)
	if err != nil {
		log.Printf("OIDC token verify: %v", err)
		http.Error(w, "token verification failed", http.StatusInternalServerError)
		return
	}

	var claims struct {
		Email             string `json:"email"`
		PreferredUsername string `json:"preferred_username"`
	}
	if err := idToken.Claims(&claims); err != nil {
		log.Printf("OIDC claims: %v", err)
		http.Error(w, "claims extraction failed", http.StatusInternalServerError)
		return
	}

	// Look up user by email
	user := s.doc.byEmail[strings.ToLower(claims.Email)]
	if user == nil {
		log.Printf("OIDC user not in identity doc: email=%s username=%s", claims.Email, claims.PreferredUsername)
		http.Error(w, "user not authorized", http.StatusForbidden)
		return
	}

	// Set session cookie
	sessionValue := createSession(user, s.cfg.SessionMaxAge, s.cfg.CookieSigningKey)
	http.SetCookie(w, &http.Cookie{
		Name:     "_fort_identity",
		Value:    sessionValue,
		Domain:   s.cfg.CookieDomain,
		Path:     "/",
		MaxAge:   int(s.cfg.SessionMaxAge.Seconds()),
		Secure:   true,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})

	log.Printf("OIDC login: %s (%s)", user.Name, claims.Email)

	rd := state
	if rd == "" {
		rd = "https://" + host + "/"
	}
	http.Redirect(w, r, rd, http.StatusFound)
}

// Session helpers

func createSession(user *resolvedUser, maxAge time.Duration, key []byte) string {
	payload := SessionPayload{
		Sub:    user.Name,
		Email:  user.Email,
		Groups: user.Groups,
		Exp:    time.Now().Add(maxAge).Unix(),
	}
	data, _ := json.Marshal(payload)
	encoded := base64.RawURLEncoding.EncodeToString(data)
	sig := signHMAC(encoded, key)
	return encoded + "." + sig
}

func validateSession(value string, key []byte) (*SessionPayload, error) {
	parts := strings.SplitN(value, ".", 2)
	if len(parts) != 2 {
		return nil, fmt.Errorf("invalid session format")
	}

	expected := signHMAC(parts[0], key)
	if !hmac.Equal([]byte(parts[1]), []byte(expected)) {
		return nil, fmt.Errorf("invalid signature")
	}

	data, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, fmt.Errorf("decode payload: %w", err)
	}

	var payload SessionPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, fmt.Errorf("unmarshal payload: %w", err)
	}

	if time.Now().Unix() > payload.Exp {
		return nil, fmt.Errorf("session expired")
	}

	return &payload, nil
}

func signHMAC(data string, key []byte) string {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(data))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// Tailscale whois

func isTailscaleIP(ip string) bool {
	// Headscale/Tailscale uses 100.64.0.0/10 (CGNAT range)
	return strings.HasPrefix(ip, "100.")
}

func (c *WhoisCache) Lookup(ip string, doc *IdentityDoc) (*resolvedUser, error) {
	c.mu.RLock()
	if e, ok := c.entries[ip]; ok && time.Since(e.fetchedAt) < c.ttl {
		c.mu.RUnlock()
		return e.user, e.err
	}
	c.mu.RUnlock()

	user, err := tailscaleWhois(ip, doc)

	c.mu.Lock()
	c.entries[ip] = &whoisEntry{user: user, err: err, fetchedAt: time.Now()}
	c.mu.Unlock()

	return user, err
}

func tailscaleWhois(ip string, doc *IdentityDoc) (*resolvedUser, error) {
	conn, err := net.Dial("unix", "/var/run/tailscale/tailscaled.sock")
	if err != nil {
		return nil, fmt.Errorf("connect tailscaled: %w", err)
	}
	defer conn.Close()

	reqURL := fmt.Sprintf("http://local-tailscaled.sock/localapi/v0/whois?addr=%s:1", url.QueryEscape(ip))
	req, _ := http.NewRequest("GET", reqURL, nil)

	resp, err := (&http.Client{
		Transport: &http.Transport{
			DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
				return net.Dial("unix", "/var/run/tailscale/tailscaled.sock")
			},
		},
	}).Do(req)
	if err != nil {
		return nil, fmt.Errorf("whois request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("whois status %d", resp.StatusCode)
	}

	var result struct {
		UserProfile struct {
			ID        int    `json:"ID"`
			LoginName string `json:"LoginName"`
		} `json:"UserProfile"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode whois: %w", err)
	}

	user, ok := doc.byHeadscaleID[result.UserProfile.ID]
	if !ok {
		return nil, fmt.Errorf("headscale user %d (%s) not in identity doc", result.UserProfile.ID, result.UserProfile.LoginName)
	}

	return user, nil
}

// Group checking

func parseGroups(header string) []string {
	if header == "" {
		return nil
	}
	var groups []string
	for _, g := range strings.Split(header, ",") {
		g = strings.TrimSpace(g)
		if g != "" {
			groups = append(groups, g)
		}
	}
	return groups
}

func checkGroups(userGroups, requiredGroups []string) bool {
	if len(requiredGroups) == 0 {
		return true // no group requirement = any authed user
	}
	for _, req := range requiredGroups {
		for _, have := range userGroups {
			if req == have {
				return true
			}
		}
	}
	return false
}

func setIdentityHeaders(w http.ResponseWriter, user *resolvedUser) {
	w.Header().Set("X-Identity-User", user.Name)
	w.Header().Set("X-Identity-Email", user.Email)
	w.Header().Set("X-Identity-Groups", strings.Join(user.Groups, ","))
}
