package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func fixture(t *testing.T) *Server {
	t.Helper()
	d := t.TempDir()
	archive := filepath.Join(d, "source.tgz")
	os.WriteFile(archive, []byte("archive"), 0600)
	s := newServer([]Target{{Host: "newbox", Profile: "beelink"}}, "fleet-secret", filepath.Join(d, "state.json"), archive, filepath.Join(d, "complete"))
	s.requireUser = true
	s.now = func() time.Time { return time.Date(2026, 7, 14, 14, 0, 0, 0, time.UTC) }
	return s
}
func request(s *Server, method, path, auth, user string, body []byte) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, bytes.NewReader(body))
	if auth != "" {
		r.Header.Set("Authorization", "Bearer "+auth)
	}
	if user != "" {
		r.Header.Set("X-Forwarded-User", user)
	}
	w := httptest.NewRecorder()
	s.routes().ServeHTTP(w, r)
	return w
}
func arm(t *testing.T, s *Server) {
	t.Helper()
	w := request(s, "POST", "/api/leases/newbox", "", "kevin", nil)
	if w.Code != 303 {
		t.Fatalf("arm: %d %s", w.Code, w.Body.String())
	}
}
func activate(t *testing.T, s *Server) (int, map[string]any) {
	t.Helper()
	w := request(s, "POST", "/activate", "fleet-secret", "", nil)
	var v map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &v)
	return w.Code, v
}
func TestDashboardRequiresIdentity(t *testing.T) {
	s := fixture(t)
	if got := request(s, "GET", "/", "", "", nil).Code; got != 401 {
		t.Fatalf("got %d", got)
	}
	if got := request(s, "GET", "/", "", "kevin", nil).Code; got != 200 {
		t.Fatalf("got %d", got)
	}
}
func TestActivationAuthAndLease(t *testing.T) {
	s := fixture(t)
	arm(t, s)
	if got := request(s, "POST", "/activate", "wrong", "", nil).Code; got != 401 {
		t.Fatalf("wrong auth %d", got)
	}
	code, v := activate(t, s)
	if code != 200 || v["host"] != "newbox" || v["claim_token"] == "" {
		t.Fatalf("%d %#v", code, v)
	}
	if code, _ = activate(t, s); code != 409 {
		t.Fatalf("second activation %d", code)
	}
}
func TestConcurrentActivationHasOneWinner(t *testing.T) {
	s := fixture(t)
	arm(t, s)
	const n = 24
	start := make(chan struct{})
	codes := make(chan int, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); <-start; c, _ := activate(t, s); codes <- c }()
	}
	close(start)
	wg.Wait()
	close(codes)
	wins := 0
	for c := range codes {
		if c == 200 {
			wins++
		} else if c != 409 {
			t.Errorf("unexpected %d", c)
		}
	}
	if wins != 1 {
		t.Fatalf("wins=%d", wins)
	}
}
func TestLeaseExpiry(t *testing.T) {
	s := fixture(t)
	arm(t, s)
	base := s.now()
	s.now = func() time.Time { return base.Add(5 * time.Minute) }
	if code, _ := activate(t, s); code != 409 {
		t.Fatalf("got %d", code)
	}
}
func TestCompletionIsRecordedAndConsumed(t *testing.T) {
	s := fixture(t)
	arm(t, s)
	_, v := activate(t, s)
	token := v["claim_token"].(string)
	body := []byte(`{"uuid":"abc","pubkey":"ssh-ed25519 xxx","hardware_configuration":"{}"}`)
	w := request(s, "POST", "/complete/"+token, token, "", body)
	if w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body.String())
	}
	b, err := os.ReadFile(filepath.Join(s.completionsDir, "newbox.json"))
	if err != nil || !bytes.Contains(b, []byte(`"uuid": "abc"`)) {
		t.Fatalf("%v %s", err, b)
	}
	if got := request(s, "POST", "/complete/"+token, token, "", body).Code; got != 403 {
		t.Fatalf("repeat %d", got)
	}
}
func TestOriginCheck(t *testing.T) {
	s := fixture(t)
	r := httptest.NewRequest("POST", "https://provision.gisi.network/api/leases/newbox", nil)
	r.Host = "provision.gisi.network"
	r.Header.Set("X-Forwarded-User", "kevin")
	r.Header.Set("Origin", "https://evil.example")
	w := httptest.NewRecorder()
	s.routes().ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatalf("got %d", w.Code)
	}
}
func TestBootstrapRequiresClaimToken(t *testing.T) {
	s := fixture(t)
	arm(t, s)
	_, v := activate(t, s)
	token := v["claim_token"].(string)
	if got := request(s, "GET", "/bootstrap/"+token, "wrong", "", nil).Code; got != 401 {
		t.Fatalf("wrong %d", got)
	}
	w := request(s, "GET", "/bootstrap/"+token, token, "", nil)
	if w.Code != 200 || w.Body.String() != "archive" {
		t.Fatalf("%d %q", w.Code, w.Body.String())
	}
}

var _ = http.MethodGet
