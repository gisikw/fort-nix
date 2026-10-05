package main

import (
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/smtp"
	"strings"
	"testing"
	"time"
)

func fakeIDToken(email string) string {
	p, _ := json.Marshal(map[string]any{"email": email, "email_verified": true})
	return "x." + base64.RawURLEncoding.EncodeToString(p) + ".y"
}

func TestStoreRoundTrip(t *testing.T) {
	dir := t.TempDir()
	s, _ := OpenStore(dir)
	if _, err := s.Upsert("Kevin.Gisi@Gmail.com", "r1", gmailScope); err != nil {
		t.Fatal(err)
	}
	_ = s.Update("kevin.gisi@gmail.com", func(a *Account) { a.Archive = true })
	s2, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	a, ok := s2.Get("kevin.gisi@gmail.com")
	if !ok || a.RefreshToken != "r1" || !a.Archive {
		t.Fatalf("got %+v", a)
	}
	// Reauth keeps settings.
	_, _ = s2.Upsert("kevin.gisi@gmail.com", "r2", gmailScope)
	a, _ = s2.Get("kevin.gisi@gmail.com")
	if a.RefreshToken != "r2" || !a.Archive {
		t.Fatalf("reauth lost settings: %+v", a)
	}
}

func TestGoogleExchangeAndRefresh(t *testing.T) {
	var refreshes int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		switch r.Form.Get("grant_type") {
		case "authorization_code":
			json.NewEncoder(w).Encode(map[string]any{
				"access_token": "a1", "expires_in": 3600, "refresh_token": "r1",
				"scope": "openid " + gmailScope + " email", "id_token": fakeIDToken("Kevin@KevinGisi.com"),
			})
		case "refresh_token":
			refreshes++
			if r.Form.Get("refresh_token") == "dead" {
				w.WriteHeader(400)
				json.NewEncoder(w).Encode(map[string]any{"error": "invalid_grant", "error_description": "Token has been expired or revoked."})
				return
			}
			json.NewEncoder(w).Encode(map[string]any{"access_token": "a2", "expires_in": 3600})
		}
	}))
	defer srv.Close()
	g := newGoogle("id", "secret", "https://mail.example/accounts/callback")
	g.TokenURL = srv.URL
	u := g.AuthURL("")
	state := strings.Split(strings.Split(u, "state=")[1], "&")[0]
	if !g.consumeState(state) || g.consumeState(state) {
		t.Fatal("state should be single-use")
	}
	email, refresh, _, err := g.Exchange("code")
	if err != nil || email != "kevin@kevingisi.com" || refresh != "r1" {
		t.Fatalf("exchange: %q %q %v", email, refresh, err)
	}
	tok, _ := g.AccessToken(Account{Email: email, RefreshToken: refresh})
	if tok != "a1" || refreshes != 0 {
		t.Fatalf("should use cached token, got %q after %d refreshes", tok, refreshes)
	}
	g.Forget(email)
	tok, _ = g.AccessToken(Account{Email: email, RefreshToken: refresh})
	if tok != "a2" || refreshes != 1 {
		t.Fatalf("refresh: %q %d", tok, refreshes)
	}
	if _, err := g.AccessToken(Account{Email: "x@y.com", RefreshToken: "dead"}); err != ErrReauth {
		t.Fatalf("want ErrReauth, got %v", err)
	}
}

func TestMbsyncrc(t *testing.T) {
	rc, err := renderMbsyncrc(mbsyncParams{ID: "a", Email: "a@b.com", TokenFile: "/s/t", Maildir: "/m/a@b.com/", SyncState: "/s/st/", Archive: false})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"AuthMechs XOAUTH2", "Inbox /m/a@b.com/INBOX", "Far \":a-far:[Gmail]/Sent Mail\""} {
		if !strings.Contains(rc, want) {
			t.Errorf("missing %q", want)
		}
	}
	if strings.Contains(rc, "All Mail") {
		t.Error("archive should be opt-in")
	}
	if _, err := renderMbsyncrc(mbsyncParams{ID: "a", Email: "a@b.com\nTunnel evil", TokenFile: "x", Maildir: "x", SyncState: "x"}); err == nil {
		t.Error("newline injection accepted")
	}
}

func TestSubmission(t *testing.T) {
	s, _ := OpenStore(t.TempDir())
	_, _ = s.Upsert("kevin@kevingisi.com", "r", gmailScope)
	type sent struct {
		acct, from string
		rcpts      []string
		msg        string
	}
	got := make(chan sent, 1)
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	sub := &Submission{User: "kevin", Password: "pw", Store: s, MaxSize: 1 << 20,
		relay: func(a Account, from string, rcpts []string, msg []byte) error {
			got <- sent{a.Email, from, rcpts, string(msg)}
			return nil
		}}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go sub.serve(c)
		}
	}()
	defer ln.Close()

	c, err := smtp.Dial(ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	if err := c.Mail("kevin@kevingisi.com"); err == nil {
		t.Fatal("MAIL before AUTH accepted")
	}
	if err := c.Auth(smtp.PlainAuth("", "kevin", "pw", "127.0.0.1")); err != nil {
		t.Fatal(err)
	}
	if err := c.Mail("stranger@example.com"); err == nil {
		t.Fatal("unknown sender accepted")
	}
	if err := c.Mail("Kevin@KevinGisi.com"); err != nil {
		t.Fatal(err)
	}
	_ = c.Rcpt("ash@example.com")
	w, _ := c.Data()
	w.Write([]byte("Subject: hi\r\n\r\n.leading dot\r\nbody\r\n"))
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case m := <-got:
		if m.acct != "kevin@kevingisi.com" || len(m.rcpts) != 1 || !strings.Contains(m.msg, "\n.leading dot\n") {
			t.Fatalf("relayed %+v", m)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no relay")
	}
	c.Quit()

	c2, _ := smtp.Dial(ln.Addr().String())
	if err := c2.Auth(smtp.PlainAuth("", "kevin", "wrong", "127.0.0.1")); err == nil {
		t.Fatal("bad password accepted")
	}
}
