package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newTestServer(t *testing.T) (*Store, *httptest.Server) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "state.json"), []byte(testState), 0o644); err != nil {
		t.Fatal(err)
	}
	launchers := `{
	  "jelly": {"argv": ["sh", "-c", "sleep 0.2"]},
	  "kart":  {"argv": ["sh", "-c", "exit 0"]},
	  "paint": {"argv": ["sh", "-c", "exit 0"]}
	}`
	if err := os.WriteFile(filepath.Join(dir, "launchers.json"), []byte(launchers), 0o644); err != nil {
		t.Fatal(err)
	}
	st, err := OpenStore(dir, false)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(st.routes())
	t.Cleanup(srv.Close)
	return st, srv
}

func apiPost(t *testing.T, srv *httptest.Server, path string, body string, wantCode int) {
	t.Helper()
	resp, err := http.Post(srv.URL+path, "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var buf bytes.Buffer
	buf.ReadFrom(resp.Body)
	if resp.StatusCode != wantCode {
		t.Fatalf("POST %s %s: want %d, got %d: %s", path, body, wantCode, resp.StatusCode, buf.String())
	}
}

func waitNotPlaying(t *testing.T, st *Store) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		st.mu.Lock()
		done := st.playing == nil
		st.mu.Unlock()
		if done {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("playing never cleared")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// The acceptance loop (brief §Acceptance 3), entirely over the HTTP API:
// grant → travel → tick → unlock at planet → launch from elsewhere →
// steal → travel back → battle → reclaim → re-unlock.
// Every step lands in the ledger; balances reconcile at the end.
func TestFullLoopOverAPI(t *testing.T) {
	st, srv := newTestServer(t)

	// 1. Grant coins via management endpoint: alex 100 → 300.
	apiPost(t, srv, "/api/admin/grant", `{"kid":"alex","coins":200,"reason":"allowance"}`, 200)

	// 2. Travel prime → zorp (1 night), tick a night, arrive.
	apiPost(t, srv, "/api/travel", `{"kid":"alex","to":"zorp"}`, 200)
	apiPost(t, srv, "/api/admin/tick", `{"days":1}`, 200)

	// 3. Unlock Tux Paint (30) — only possible while at zorp. 300 → 270.
	apiPost(t, srv, "/api/unlock", `{"kid":"alex","planet":"zorp","app":"paint"}`, 200)

	// 4. Travel home to prime, arrive, then launch paint FROM prime
	//    (unlock-here / launch-anywhere).
	apiPost(t, srv, "/api/travel", `{"kid":"alex","to":"prime"}`, 200)
	apiPost(t, srv, "/api/admin/tick", `{"days":1}`, 200)
	apiPost(t, srv, "/api/launch", `{"kid":"alex","app":"paint"}`, 200)
	waitNotPlaying(t, st)

	// 5. Parent aims the Dadmonster at paint (on zorp, far from alex).
	apiPost(t, srv, "/api/admin/steal", `{"planet":"zorp","app":"paint"}`, 200)

	// Stolen apps are not launchable, even though it was ready a moment ago.
	apiPost(t, srv, "/api/launch", `{"kid":"alex","app":"paint"}`, 409)
	// Battling from afar is impossible: the trip back is the price.
	apiPost(t, srv, "/api/battle-win", `{"kid":"alex","planet":"zorp","app":"paint"}`, 409)

	// 6. Travel back, battle, win: stolen → locked (re-buyable).
	apiPost(t, srv, "/api/travel", `{"kid":"alex","to":"zorp"}`, 200)
	apiPost(t, srv, "/api/admin/tick", `{"days":1}`, 200)
	apiPost(t, srv, "/api/battle-win", `{"kid":"alex","planet":"zorp","app":"paint"}`, 200)

	// 7. Re-unlock: the reclaim costs the trip plus the coins. 270 → 240.
	apiPost(t, srv, "/api/unlock", `{"kid":"alex","planet":"zorp","app":"paint"}`, 200)

	// Final state assertions.
	k := st.state.findKid("alex")
	if k.Coins != 240 {
		t.Fatalf("want 240 coins, got %d", k.Coins)
	}
	if k.Location != "zorp" || k.Transit != nil {
		t.Fatalf("want alex settled at zorp, got %s %+v", k.Location, k.Transit)
	}
	if _, app := st.state.findApp("paint"); app.State != appReady {
		t.Fatalf("want paint ready, got %s", app.State)
	}

	// The ledger shows every step, in order.
	wantTypes := []string{"grant", "travel_set", "tick", "arrive", "unlock",
		"travel_set", "tick", "arrive", "launch", "app_exit", "steal",
		"travel_set", "tick", "arrive", "battle_win", "unlock"}
	var got []string
	for _, e := range readLedger(t, st) {
		if e.Type == "seed" || e.Kid == "bee" { // bee's fixture transit also arrives
			continue
		}
		got = append(got, e.Type)
	}
	if fmt.Sprint(got) != fmt.Sprint(wantTypes) {
		t.Fatalf("ledger sequence mismatch:\nwant %v\ngot  %v", wantTypes, got)
	}

	// Balances reconcile from the ledger alone.
	balances, err := replayBalances(st.ledgerPath())
	if err != nil {
		t.Fatal(err)
	}
	for _, kid := range st.state.Kids {
		if balances[kid.ID] != kid.Coins {
			t.Fatalf("kid %s: ledger says %d, state says %d", kid.ID, balances[kid.ID], kid.Coins)
		}
	}
}

func TestStateEndpointAndSSE(t *testing.T) {
	_, srv := newTestServer(t)

	resp, err := http.Get(srv.URL + "/api/state")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var payload Payload
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Kids) != 2 || len(payload.Planets) != 4 || payload.Dev {
		t.Fatalf("unexpected payload: kids=%d planets=%d dev=%v", len(payload.Kids), len(payload.Planets), payload.Dev)
	}

	// SSE sends current state immediately on connect.
	sse, err := http.Get(srv.URL + "/api/events")
	if err != nil {
		t.Fatal(err)
	}
	defer sse.Body.Close()
	if ct := sse.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("want text/event-stream, got %q", ct)
	}
	line, err := bufio.NewReader(sse.Body).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(line, "data: {") {
		t.Fatalf("want immediate data frame, got %q", line)
	}
}

// The kiosk sim button is dev-mode only; the flag rides the payload.
func TestDevFlagInPayload(t *testing.T) {
	dir := t.TempDir()
	st, err := OpenStore(dir, true) // dev seeds example state + launchers
	if err != nil {
		t.Fatal(err)
	}
	var payload Payload
	if err := json.Unmarshal(st.PayloadJSON(), &payload); err != nil {
		t.Fatal(err)
	}
	if !payload.Dev {
		t.Fatal("dev store must advertise dev=true to the kiosk")
	}
	// dev seeding wrote real files; a second open (non-dev) must succeed
	if _, err := OpenStore(dir, false); err != nil {
		t.Fatal(err)
	}
}
