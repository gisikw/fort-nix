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
	gmailScope      = "https://mail.google.com/"
)

// ErrReauth means Google refused the refresh token (revoked, expired —
// e.g. the 7-day limit on apps left in "Testing"). Only a human can fix it.
var ErrReauth = errors.New("refresh token rejected; reconnect the account")

type Google struct {
	ClientID     string
	ClientSecret string
	RedirectURI  string
	HTTP         *http.Client
	TokenURL     string // overridable in tests

	mu     sync.Mutex
	states map[string]time.Time
	cache  map[string]cachedToken
}

type cachedToken struct {
	token  string
	expiry time.Time
}

func newGoogle(id, secret, redirect string) *Google {
	return &Google{
		ClientID: id, ClientSecret: secret, RedirectURI: redirect,
		HTTP:     &http.Client{Timeout: 30 * time.Second},
		TokenURL: googleTokenURL,
		states:   map[string]time.Time{}, cache: map[string]cachedToken{},
	}
}

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// AuthURL starts a consent flow. prompt=consent + access_type=offline make
// Google hand back a refresh token every time, which is what reauth needs.
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
		"scope":                  {gmailScope + " openid email"},
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
	IDToken      string `json:"id_token"`
	Error        string `json:"error"`
	ErrorDesc    string `json:"error_description"`
}

func (g *Google) post(form url.Values) (*tokenResp, int, error) {
	form.Set("client_id", g.ClientID)
	form.Set("client_secret", g.ClientSecret)
	resp, err := g.HTTP.PostForm(g.TokenURL, form)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var tr tokenResp
	if err := json.Unmarshal(body, &tr); err != nil {
		return nil, resp.StatusCode, fmt.Errorf("token endpoint: HTTP %d", resp.StatusCode)
	}
	if tr.Error != "" {
		return &tr, resp.StatusCode, fmt.Errorf("google: %s: %s", tr.Error, tr.ErrorDesc)
	}
	return &tr, resp.StatusCode, nil
}

// Exchange trades an auth code for tokens and returns the verified email.
// The id_token arrives directly from Google over TLS in response to our
// authenticated request, so reading its payload without a signature check
// is the documented-safe case.
func (g *Google) Exchange(code string) (email, refresh, scope string, err error) {
	tr, _, err := g.post(url.Values{
		"grant_type":   {"authorization_code"},
		"code":         {code},
		"redirect_uri": {g.RedirectURI},
	})
	if err != nil {
		return "", "", "", err
	}
	if tr.RefreshToken == "" {
		return "", "", "", errors.New("google returned no refresh token")
	}
	if !hasScope(tr.Scope, gmailScope) {
		return "", "", "", errors.New("mail access was not granted (tick the Gmail box on the consent screen)")
	}
	email, verified, err := idTokenEmail(tr.IDToken)
	if err != nil {
		return "", "", "", err
	}
	if !verified || !validEmail(email) {
		return "", "", "", fmt.Errorf("unusable account email %q", email)
	}
	g.remember(email, tr)
	return strings.ToLower(email), tr.RefreshToken, tr.Scope, nil
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
	v := claims.Verified == true || claims.Verified == "true"
	return claims.Email, v, nil
}

func (g *Google) remember(email string, tr *tokenResp) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.cache[strings.ToLower(email)] = cachedToken{
		token:  tr.AccessToken,
		expiry: time.Now().Add(time.Duration(tr.ExpiresIn) * time.Second),
	}
}

// AccessToken returns a token valid for at least five more minutes,
// refreshing as needed.
func (g *Google) AccessToken(a Account) (string, error) {
	key := strings.ToLower(a.Email)
	g.mu.Lock()
	c, ok := g.cache[key]
	g.mu.Unlock()
	if ok && time.Until(c.expiry) > 5*time.Minute {
		return c.token, nil
	}
	tr, status, err := g.post(url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {a.RefreshToken},
	})
	if err != nil {
		if tr != nil && (tr.Error == "invalid_grant" || tr.Error == "unauthorized_client") {
			return "", ErrReauth
		}
		_ = status
		return "", err
	}
	g.remember(key, tr)
	return tr.AccessToken, nil
}

func (g *Google) Forget(email string) {
	g.mu.Lock()
	delete(g.cache, strings.ToLower(email))
	g.mu.Unlock()
}

// Revoke is best-effort: the local token is deleted regardless.
func (g *Google) Revoke(refresh string) {
	resp, err := g.HTTP.PostForm(googleRevokeURL, url.Values{"token": {refresh}})
	if err == nil {
		resp.Body.Close()
	}
}
