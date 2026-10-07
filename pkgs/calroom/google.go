package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	googleAuthURL   = "https://accounts.google.com/o/oauth2/v2/auth"
	googleTokenURL  = "https://oauth2.googleapis.com/token"
	googleRevokeURL = "https://oauth2.googleapis.com/revoke"
	// vdirsyncer talks to Google over CalDAV, which wants the full calendar
	// scope. Remote storages are configured read_only, so nothing is written.
	calendarScope = "https://www.googleapis.com/auth/calendar"
)

type Google struct {
	ClientID     string
	ClientSecret string
	RedirectURI  string
	HTTP         *http.Client
	TokenURL     string // overridable in tests

	mu     sync.Mutex
	states map[string]time.Time
}

func newGoogle(id, secret, redirect string) *Google {
	return &Google{
		ClientID: id, ClientSecret: secret, RedirectURI: redirect,
		HTTP:     &http.Client{Timeout: 30 * time.Second},
		TokenURL: googleTokenURL,
		states:   map[string]time.Time{},
	}
}

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func (g *Google) AuthURL(loginHint string) string {
	state := randHex(16)
	g.mu.Lock()
	now := time.Now()
	for k, t := range g.states {
		if now.Sub(t) > 15*time.Minute {
			delete(g.states, k)
		}
	}
	g.states[state] = now
	g.mu.Unlock()
	q := url.Values{
		"client_id":              {g.ClientID},
		"redirect_uri":           {g.RedirectURI},
		"response_type":          {"code"},
		"scope":                  {calendarScope + " openid email"},
		"access_type":            {"offline"},
		"prompt":                 {"consent select_account"},
		"include_granted_scopes": {"false"},
		"state":                  {state},
	}
	if loginHint != "" {
		q.Set("login_hint", loginHint)
	}
	return googleAuthURL + "?" + q.Encode()
}

func (g *Google) consumeState(state string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	t, ok := g.states[state]
	delete(g.states, state)
	return ok && time.Since(t) < 15*time.Minute
}

type tokenResp struct {
	AccessToken  string `json:"access_token"`
	ExpiresIn    int    `json:"expires_in"`
	RefreshToken string `json:"refresh_token"`
	Scope        string `json:"scope"`
	TokenType    string `json:"token_type"`
	IDToken      string `json:"id_token"`
	Error        string `json:"error"`
	ErrorDesc    string `json:"error_description"`
}

// Exchange trades an auth code for tokens and returns the verified email.
// The id_token comes straight from Google over TLS in answer to our own
// authenticated request, so reading its payload unverified is the
// documented-safe case.
func (g *Google) Exchange(code string) (string, *tokenResp, error) {
	form := url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {g.RedirectURI},
		"client_id":     {g.ClientID},
		"client_secret": {g.ClientSecret},
	}
	resp, err := g.HTTP.PostForm(g.TokenURL, form)
	if err != nil {
		return "", nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var tr tokenResp
	if err := json.Unmarshal(body, &tr); err != nil {
		return "", nil, fmt.Errorf("token endpoint: HTTP %d", resp.StatusCode)
	}
	if tr.Error != "" {
		return "", nil, fmt.Errorf("google: %s: %s", tr.Error, tr.ErrorDesc)
	}
	if tr.RefreshToken == "" {
		return "", nil, errors.New("google returned no refresh token")
	}
	if !hasScope(tr.Scope, calendarScope) {
		return "", nil, errors.New("calendar access was not granted (tick the Calendar box on the consent screen)")
	}
	email, verified, err := idTokenEmail(tr.IDToken)
	if err != nil {
		return "", nil, err
	}
	email = strings.ToLower(email)
	if !verified || !validEmail(email) {
		return "", nil, fmt.Errorf("unusable account email %q", email)
	}
	return email, &tr, nil
}

func hasScope(scopes, want string) bool {
	for _, s := range strings.Fields(scopes) {
		if s == want {
			return true
		}
	}
	return false
}

func idTokenEmail(idt string) (string, bool, error) {
	parts := strings.Split(idt, ".")
	if len(parts) != 3 {
		return "", false, errors.New("missing id_token")
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", false, fmt.Errorf("id_token: %w", err)
	}
	var claims struct {
		Email    string `json:"email"`
		Verified any    `json:"email_verified"`
	}
	if err := json.Unmarshal(raw, &claims); err != nil {
		return "", false, fmt.Errorf("id_token: %w", err)
	}
	return claims.Email, claims.Verified == true || claims.Verified == "true", nil
}

// Revoke is best-effort: the local token is deleted regardless.
func (g *Google) Revoke(refresh string) {
	resp, err := g.HTTP.PostForm(googleRevokeURL, url.Values{"token": {refresh}})
	if err == nil {
		resp.Body.Close()
	}
}
