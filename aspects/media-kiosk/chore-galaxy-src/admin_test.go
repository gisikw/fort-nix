package main

// The parent-controls surface: chore uncheck (ledgered claw-back, never
// silent), chore-list editing (done flags carry by name, incoming done flags
// ignored — no check-off path that skips the coins+ledger), the ledger-tail
// read view, and the /admin/ page itself.

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestChoreUncheck(t *testing.T) {
	st := newTestStore(t)
	// Fixture: alex has "Clean the room" (15) already done, 100 coins.
	if err := st.ChoreUncheck("alex", "Clean the room"); err != nil {
		t.Fatal(err)
	}
	k := st.state.findKid("alex")
	if k.Coins != 85 {
		t.Fatalf("want 85 after claw-back, got %d", k.Coins)
	}
	if k.Chores[0].Done {
		t.Fatal("chore still done after uncheck")
	}
	// Unchecking an unchecked chore: nothing to reverse.
	if code := httpCode(t, st.ChoreUncheck("alex", "Clean the room")); code != 404 {
		t.Fatalf("double uncheck: want 404, got %d", code)
	}

	// A claw-back may never overdraw: re-check (85→100), spend down to 5,
	// then the uncheck is refused and nothing moves.
	if err := st.ChoreCheck("alex", "Clean the room"); err != nil {
		t.Fatal(err)
	}
	if err := st.Grant("alex", -95, "spend down"); err != nil {
		t.Fatal(err)
	}
	if code := httpCode(t, st.ChoreUncheck("alex", "Clean the room")); code != 409 {
		t.Fatalf("overdrawing uncheck: want 409, got %d", code)
	}
	if k.Coins != 5 || !k.Chores[0].Done {
		t.Fatalf("refused uncheck must not move anything: coins=%d done=%v", k.Coins, k.Chores[0].Done)
	}

	// Every movement above is in the ledger; balances replay exactly.
	balances, err := replayBalances(st.ledgerPath())
	if err != nil {
		t.Fatal(err)
	}
	if balances["alex"] != k.Coins {
		t.Fatalf("ledger replays %d, state has %d", balances["alex"], k.Coins)
	}
}

func TestSetChores(t *testing.T) {
	st := newTestStore(t)
	err := st.SetChores("alex", []*Chore{
		{Name: "Clean the room", Coins: 20},              // exists, done today
		{Name: "Water the plants", Coins: 5, Done: true}, // new; incoming done must be ignored
	})
	if err != nil {
		t.Fatal(err)
	}
	k := st.state.findKid("alex")
	if len(k.Chores) != 2 {
		t.Fatalf("want 2 chores, got %d", len(k.Chores))
	}
	if !k.Chores[0].Done || k.Chores[0].Coins != 20 {
		t.Fatalf("done flag / new coins not carried: %+v", k.Chores[0])
	}
	if k.Chores[1].Done {
		t.Fatal("client-sent done flag must be ignored — check-off goes through ChoreCheck only")
	}
	if k.Coins != 100 {
		t.Fatalf("editing the list must never move coins, got %d", k.Coins)
	}

	// Validation: empty names, duplicates, negative coins.
	if code := httpCode(t, st.SetChores("alex", []*Chore{{Name: "  ", Coins: 5}})); code != 400 {
		t.Fatalf("blank name: want 400, got %d", code)
	}
	if code := httpCode(t, st.SetChores("alex", []*Chore{{Name: "X", Coins: 5}, {Name: "X", Coins: 9}})); code != 400 {
		t.Fatalf("duplicate name: want 400, got %d", code)
	}
	if code := httpCode(t, st.SetChores("alex", []*Chore{{Name: "X", Coins: -5}})); code != 400 {
		t.Fatalf("negative coins: want 400, got %d", code)
	}

	// Clearing the list is legal and must marshal as [], never null — the
	// kiosk iterates chores unconditionally.
	if err := st.SetChores("alex", nil); err != nil {
		t.Fatal(err)
	}
	if k.Chores == nil || len(k.Chores) != 0 {
		t.Fatalf("want empty non-nil chore list, got %#v", k.Chores)
	}

	// The edits landed in the ledger (every mutation does — INVARIANTS 9).
	tail, err := ledgerTail(st.ledgerPath(), 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(tail) != 1 || tail[0].Type != "chores_edit" || tail[0].Kid != "alex" {
		t.Fatalf("want a chores_edit tail event, got %+v", tail)
	}
}

func TestAdminEndpoints(t *testing.T) {
	_, srv := newTestServer(t)

	apiPost(t, srv, "/api/admin/chore-check", `{"kid":"alex","chore":"Take out the trash"}`, 200)
	apiPost(t, srv, "/api/admin/chore-uncheck", `{"kid":"alex","chore":"Take out the trash"}`, 200)
	apiPost(t, srv, "/api/admin/chores", `{"kid":"alex","chores":[{"name":"Sweep","coins":5}]}`, 200)
	apiPost(t, srv, "/api/admin/chores", `{"kid":"alex","chores":[{"name":"Sweep","coins":5},{"name":"Sweep","coins":9}]}`, 400)
	apiPost(t, srv, "/api/admin/chore-uncheck", `{"kid":"nobody","chore":"X"}`, 404)

	// Ledger tail: newest first, honors n, rejects junk n.
	resp, err := http.Get(srv.URL + "/api/admin/ledger?n=2")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("ledger tail: want 200, got %d", resp.StatusCode)
	}
	var body struct{ Events []Event }
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if len(body.Events) != 2 {
		t.Fatalf("want 2 events, got %d", len(body.Events))
	}
	if body.Events[0].Type != "chores_edit" || body.Events[1].Type != "chore_uncheck" {
		t.Fatalf("want newest-first [chores_edit chore_uncheck], got [%s %s]",
			body.Events[0].Type, body.Events[1].Type)
	}
	if resp, err := http.Get(srv.URL + "/api/admin/ledger?n=zillion"); err != nil {
		t.Fatal(err)
	} else {
		resp.Body.Close()
		if resp.StatusCode != 400 {
			t.Fatalf("bad n: want 400, got %d", resp.StatusCode)
		}
	}
}

func TestAdminUIServed(t *testing.T) {
	_, srv := newTestServer(t)
	resp, err := http.Get(srv.URL + "/admin/")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("GET /admin/: want 200, got %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Fatalf("want text/html, got %q", ct)
	}
}
