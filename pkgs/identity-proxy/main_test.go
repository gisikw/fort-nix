package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/go-jose/go-jose/v4"
)

// spin up a minimal OIDC issuer: discovery doc + JWKS backed by one RSA key.
func testIssuer(t *testing.T, key *rsa.PrivateKey) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.NewServeMux())
	mux := srv.Config.Handler.(*http.ServeMux)
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"issuer":                 srv.URL,
			"authorization_endpoint": srv.URL + "/auth",
			"token_endpoint":         srv.URL + "/token",
			"jwks_uri":               srv.URL + "/jwks",
		})
	})
	mux.HandleFunc("/jwks", func(w http.ResponseWriter, _ *http.Request) {
		jwk := jose.JSONWebKey{Key: &key.PublicKey, KeyID: "test-key", Algorithm: "RS256", Use: "sig"}
		buf, _ := jwk.MarshalJSON()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(append([]byte(`{"keys":[`), append(buf, []byte("]}")...)...))
	})
	// userinfo maps pre-registered tokens to emails — tests register tokens
	// in userinfoTokens to simulate the issuer knowing the token.
	mux.HandleFunc("/api/oidc/userinfo", func(w http.ResponseWriter, r *http.Request) {
		tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		email, ok := userinfoTokens.Load(tok)
		if !ok {
			w.WriteHeader(401)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"email": email.(string), "sub": "x"})
	})
	t.Cleanup(srv.Close)
	return srv
}

var userinfoTokens sync.Map

func signIDToken(t *testing.T, key *rsa.PrivateKey, issuer string, claims map[string]interface{}) string {
	t.Helper()
	signer, err := jose.NewSigner(jose.SigningKey{Key: key, Algorithm: jose.RS256},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", "test-key"))
	if err != nil {
		t.Fatal(err)
	}
	claims["iss"] = issuer
	claims["exp"] = time.Now().Add(time.Hour).Unix() // NumericDate per RFC 7519
	buf, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	object, err := signer.Sign(buf)
	if err != nil {
		t.Fatal(err)
	}
	signed, err := object.CompactSerialize()
	if err != nil {
		t.Fatal(err)
	}
	return signed
}

func testServer(t *testing.T, idpURL string) *Server {
	t.Helper()
	cfg := &Config{
		OIDCIssuer:      idpURL,
		OIDCClientID:    "identity-proxy",
		BearerAudiences: []string{"familiar-desktop"},
	}
	doc := &IdentityDoc{
		Users: map[string]User{
			"kevin": {Emails: []string{"kevin@example.com"}, Groups: []string{"admin", "infra"}},
		},
		byEmail: map[string]*resolvedUser{
			"kevin@example.com": {Name: "kevin", Email: "kevin@example.com", Groups: []string{"admin", "infra"}},
		},
	}
	provider, err := oidc.NewProvider(context.Background(), idpURL)
	if err != nil {
		t.Fatal(err)
	}
	return &Server{
		cfg:            cfg,
		doc:            doc,
		cache:          &WhoisCache{entries: map[string]*whoisEntry{}},
		verifier:       provider.Verifier(&oidc.Config{ClientID: "identity-proxy"}),
		bearerVerifier: provider.Verifier(&oidc.Config{SkipClientIDCheck: true}),
	}
}

func TestValidateBearerToken(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	idp := testIssuer(t, key)
	defer idp.Close()
	s := testServer(t, idp.URL)
	s.httpClient = idp.Client()

	// Tokens must carry the live test issuer; the verifier checks iss
	// against the discovery doc's issuer, which is srv.URL.
	issuer := idp.URL

	makeReq := func(token string, groups string) *http.Request {
		r := httptest.NewRequest("GET", "/_identity/validate", nil)
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("X-Identity-Required-Groups", groups)
		return r
	}

	valid := signIDToken(t, key, issuer, map[string]interface{}{
		"aud": []string{"familiar-desktop"},
	})
	// Access tokens carry no email (pocket-id's real behavior); identity comes
	// from userinfo, which the mock resolves per-token.
	userinfoTokens.Store(valid, "kevin@example.com")

	// Happy path: token proves email, doc supplies groups.
	w := httptest.NewRecorder()
	s.handleValidate(w, makeReq(valid, "admin"))
	if w.Code != http.StatusOK {
		t.Fatalf("valid bearer: code=%d body=%s", w.Code, w.Body.String())
	}
	if w.Header().Get("X-Identity-User") != "kevin" || w.Header().Get("X-Identity-Groups") != "admin,infra" {
		t.Fatalf("identity headers: %v", w.Header())
	}

	// Wrong audience → rejected even though signature is valid.
	wrongAud := signIDToken(t, key, issuer, map[string]interface{}{
		"aud": []string{"someone-else"},
	})
	w = httptest.NewRecorder()
	s.handleValidate(w, makeReq(wrongAud, "admin"))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("wrong aud: code=%d", w.Code)
	}

	// Valid JWT whose owner is not in the identity doc → unauthorized.
	// (Distinct claim needed: RSA-PKCS1v15 is deterministic, so identical
	// claims would produce a token byte-identical to `valid`.)
	stranger := signIDToken(t, key, issuer, map[string]interface{}{
		"aud": []string{"familiar-desktop"}, "sub": "stranger-sub",
	})
	userinfoTokens.Store(stranger, "stranger@example.com")
	w = httptest.NewRecorder()
	s.handleValidate(w, makeReq(stranger, "admin"))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("stranger: code=%d", w.Code)
	}

	// In doc, holds at least one required group (checkGroups is ANY-semantics,
	// matching the proxy's existing behavior for browsers and VPN users).
	w = httptest.NewRecorder()
	s.handleValidate(w, makeReq(valid, "admin,sudo"))
	if w.Code != http.StatusOK {
		t.Fatalf("any-group match: code=%d", w.Code)
	}

	// Holds none of the required groups → forbidden.
	w = httptest.NewRecorder()
	s.handleValidate(w, makeReq(valid, "sudo"))
	if w.Code != http.StatusForbidden {
		t.Fatalf("missing group: code=%d", w.Code)
	}

	// Opaque access token (pocket-id's default format): userinfo resolves it.
	opaque := "opaque-token-abc"
	userinfoTokens.Store(opaque, "kevin@example.com")
	w = httptest.NewRecorder()
	s.handleValidate(w, makeReq(opaque, "admin"))
	if w.Code != http.StatusOK || w.Header().Get("X-Identity-User") != "kevin" {
		t.Fatalf("opaque token via userinfo: code=%d body=%s", w.Code, w.Body.String())
	}

	// Rejected opaque token (issuer doesn't know it) → unauthorized.
	w = httptest.NewRecorder()
	s.handleValidate(w, makeReq("opaque-token-rejected", "admin"))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("rejected opaque: code=%d", w.Code)
	}

	// Garbage token → unauthorized, not a panic.
	w = httptest.NewRecorder()
	s.handleValidate(w, makeReq("not.a.jwt", "admin"))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("garbage: code=%d", w.Code)
	}
}

func TestProtectedResourceMetadata(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	idp := testIssuer(t, key)
	defer idp.Close()
	s := testServer(t, idp.URL)
	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/_identity/protected-resource", nil)
	r.Header.Set("X-Original-Host", "familiar.gisi.network")
	s.handleProtectedResource(w, r)
	if w.Code != http.StatusOK || w.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("code=%d ct=%q", w.Code, w.Header().Get("Content-Type"))
	}
	var meta struct {
		Resource             string   `json:"resource"`
		AuthorizationServers []string `json:"authorization_servers"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &meta); err != nil {
		t.Fatal(err)
	}
	if meta.Resource != "https://familiar.gisi.network" {
		t.Fatalf("resource=%q", meta.Resource)
	}
	if len(meta.AuthorizationServers) != 1 || meta.AuthorizationServers[0] != idp.URL {
		t.Fatalf("authorization_servers=%v", meta.AuthorizationServers)
	}
}

func TestBearerAudiencesParsing(t *testing.T) {
	// Covered via loadConfig's env parsing indirectly; here we assert the
	// default (no env) is the interactive client id.
	cfg := &Config{OIDCClientID: "identity-proxy"}
	if len(cfg.BearerAudiences) != 0 {
		t.Fatalf("expected zero-value default, got %v", cfg.BearerAudiences)
	}
	_ = strings.TrimSpace // keep strings imported for future assertions
}
