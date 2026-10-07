package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSlugMatchesShell(t *testing.T) {
	// cal-sync: printf %s "$email" | tr -c 'a-z0-9' '_'
	if got := Slug("kevin.gisi@gmail.com"); got != "kevin_gisi_gmail_com" {
		t.Fatal(got)
	}
}

func TestStoreWriteListDelete(t *testing.T) {
	d := t.TempDir()
	s := &Store{Dir: filepath.Join(d, "tokens"), LegacyFile: filepath.Join(d, "token"), LegacyEmail: "work@alpinesg.com",
		DataDir: filepath.Join(d, "google"), StatusDir: filepath.Join(d, "status")}
	os.WriteFile(s.LegacyFile, []byte(`{"refresh_token":"old"}`), 0o600)
	now := time.Unix(1000, 0)
	tr := &tokenResp{AccessToken: "a", RefreshToken: "r", ExpiresIn: 3600, Scope: calendarScope + " openid"}
	if err := s.Write("me@gmail.com", tr, now); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(s.Dir, "me@gmail.com.json"))
	var tok map[string]any
	json.Unmarshal(b, &tok)
	if tok["refresh_token"] != "r" || tok["expires_at"].(float64) != 4600 || tok["token_type"] != "Bearer" {
		t.Fatalf("token shape: %s", b)
	}
	if fi, _ := os.Stat(filepath.Join(s.Dir, "me@gmail.com.json")); fi.Mode().Perm() != 0o600 {
		t.Fatal("mode")
	}
	os.MkdirAll(filepath.Join(s.DataDir, "me@gmail.com", "cal1"), 0o700)
	os.MkdirAll(filepath.Join(s.StatusDir, "g_me_gmail_com"), 0o700)
	l := s.List()
	if len(l) != 2 || !l[0].Legacy || l[1].Email != "me@gmail.com" || l[1].Calendars != 1 {
		t.Fatalf("%+v", l)
	}
	// Reconnecting the work account replaces the legacy file in place.
	if err := s.Write("work@alpinesg.com", tr, now); err != nil {
		t.Fatal(err)
	}
	if s.RefreshToken("work@alpinesg.com") != "r" {
		t.Fatal("legacy not rewritten")
	}
	if err := s.Delete("work@alpinesg.com"); err == nil {
		t.Fatal("legacy delete must refuse")
	}
	if err := s.Delete("me@gmail.com"); err != nil {
		t.Fatal(err)
	}
	if s.Has("me@gmail.com") {
		t.Fatal("still there")
	}
	if _, err := os.Stat(filepath.Join(s.StatusDir, "g_me_gmail_com")); err == nil {
		t.Fatal("status kept")
	}
	if _, err := os.Stat(filepath.Join(s.DataDir, "me@gmail.com")); err == nil {
		t.Fatal("data kept")
	}
}

func idToken(email string) string {
	p, _ := json.Marshal(map[string]any{"email": email, "email_verified": true})
	return "h." + base64.RawURLEncoding.EncodeToString(p) + ".s"
}

func TestCallbackFlow(t *testing.T) {
	tokSrv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		if r.Form.Get("code") != "C" {
			rw.WriteHeader(400)
			rw.Write([]byte(`{"error":"invalid_grant"}`))
			return
		}
		json.NewEncoder(rw).Encode(map[string]any{"access_token": "A", "refresh_token": "R", "expires_in": 3600,
			"scope": calendarScope + " openid https://www.googleapis.com/auth/userinfo.email", "id_token": idToken("Me@Gmail.com")})
	}))
	defer tokSrv.Close()
	d := t.TempDir()
	g := newGoogle("id", "sec", "https://x/callback")
	g.TokenURL = tokSrv.URL
	w := &Web{Store: &Store{Dir: d}, Google: g, Syncer: &Syncer{}, Origin: "https://x"}
	h := w.Routes()

	u, _ := url.Parse(g.AuthURL(""))
	state := u.Query().Get("state")
	if !strings.Contains(u.Query().Get("scope"), calendarScope) {
		t.Fatal("scope")
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/callback?code=C&state="+state, nil))
	if loc := rec.Header().Get("Location"); !strings.Contains(loc, "Connected") {
		t.Fatalf("redirect %q", loc)
	}
	if _, err := os.Stat(filepath.Join(d, "me@gmail.com.json")); err != nil {
		t.Fatal(err)
	}
	// state is single-use
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/callback?code=C&state="+state, nil))
	if !strings.Contains(rec.Header().Get("Location"), "expired") {
		t.Fatal("state reuse accepted")
	}
	// cross-site POST refused
	rec = httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/act", strings.NewReader("action=sync"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	h.ServeHTTP(rec, req)
	if rec.Code != 403 {
		t.Fatal(rec.Code)
	}
	// index renders
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "me@gmail.com") {
		t.Fatal("index")
	}
}
