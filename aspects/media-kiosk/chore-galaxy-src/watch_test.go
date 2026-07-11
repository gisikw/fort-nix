package main

// File-change reload (the invariant-9 "hand-editable" promise made live):
// external edits to state.json / launchers.json reload and broadcast; the
// backend's own writes don't re-trigger; malformed or invalid content keeps
// last-good state — the kiosk never blanks on a bad hand-edit (INVARIANTS 1).

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestExternalStateEditReloadsAndBroadcasts(t *testing.T) {
	st := newTestStore(t)
	ch := st.hub.Subscribe()
	defer st.hub.Unsubscribe(ch)

	edited := strings.Replace(testState, `"coins":100`, `"coins":5555`, 1)
	if err := os.WriteFile(st.statePath(), []byte(edited), 0o644); err != nil {
		t.Fatal(err)
	}
	if !st.checkExternalChanges() {
		t.Fatal("external edit to state.json not detected")
	}
	if k := st.state.findKid("alex"); k.Coins != 5555 {
		t.Fatalf("want reloaded coins 5555, got %d", k.Coins)
	}

	// The reload must reach the kiosk over the SSE hub, no restart, no poll.
	select {
	case payload := <-ch:
		var p Payload
		if err := json.Unmarshal(payload, &p); err != nil {
			t.Fatal(err)
		}
		if len(p.Kids) == 0 || p.Kids[0].Coins != 5555 {
			t.Fatalf("broadcast payload does not carry the reloaded state: %s", payload)
		}
	default:
		t.Fatal("no SSE broadcast after external reload")
	}

	// Nothing further changed: the next pass is a no-op.
	if st.checkExternalChanges() {
		t.Fatal("second pass reloaded again with no new edit")
	}
}

func TestOwnWritesDoNotTriggerReload(t *testing.T) {
	st := newTestStore(t)
	if err := st.Grant("alex", 10, "own write"); err != nil {
		t.Fatal(err)
	}
	if st.checkExternalChanges() {
		t.Fatal("backend's own state.json write was mistaken for a hand-edit")
	}
	if k := st.state.findKid("alex"); k.Coins != 110 {
		t.Fatalf("state clobbered by phantom reload: want 110, got %d", k.Coins)
	}
}

func TestMalformedExternalEditKeepsLastGood(t *testing.T) {
	st := newTestStore(t)
	if err := os.WriteFile(st.statePath(), []byte("{ this is not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if st.checkExternalChanges() {
		t.Fatal("malformed state.json must not reload")
	}
	if k := st.state.findKid("alex"); k.Coins != 100 {
		t.Fatalf("last-good state lost: want 100, got %d", k.Coins)
	}
	var p Payload
	if err := json.Unmarshal(st.PayloadJSON(), &p); err != nil || len(p.Kids) != 2 {
		t.Fatalf("kiosk payload broken after bad edit: %v %s", err, st.PayloadJSON())
	}

	// The editor finishes the save properly: next pass picks it up fresh.
	edited := strings.Replace(testState, `"coins":100`, `"coins":5555`, 1)
	if err := os.WriteFile(st.statePath(), []byte(edited), 0o644); err != nil {
		t.Fatal(err)
	}
	if !st.checkExternalChanges() {
		t.Fatal("repaired state.json not reloaded")
	}
	if k := st.state.findKid("alex"); k.Coins != 5555 {
		t.Fatalf("want 5555 after repaired edit, got %d", k.Coins)
	}
}

func TestInvalidExternalEditKeepsLastGood(t *testing.T) {
	st := newTestStore(t)
	// Well-formed JSON, semantically invalid: alex located at an unknown planet.
	edited := strings.Replace(testState, `"location":"prime"`, `"location":"atlantis"`, 1)
	if err := os.WriteFile(st.statePath(), []byte(edited), 0o644); err != nil {
		t.Fatal(err)
	}
	if st.checkExternalChanges() {
		t.Fatal("invalid state.json must not reload")
	}
	if k := st.state.findKid("alex"); k.Location != "prime" {
		t.Fatalf("last-good state lost: want prime, got %q", k.Location)
	}
}

func TestExternalLaunchersEditReloads(t *testing.T) {
	st := newTestStore(t)
	if err := os.WriteFile(st.launcherPath(), []byte(`{"zelda": {"argv": ["sh", "-c", "exit 0"]}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if !st.checkExternalChanges() {
		t.Fatal("external edit to launchers.json not detected")
	}
	if st.launchers["zelda"] == nil || st.launchers["jelly"] != nil {
		t.Fatalf("launchers not swapped: %v", st.launchers)
	}

	// A busted launchers.json keeps the last-good specs.
	if err := os.WriteFile(st.launcherPath(), []byte(`{"zelda": {"argv": []}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if st.checkExternalChanges() {
		t.Fatal("launcher spec with empty argv must not reload")
	}
	if st.launchers["zelda"] == nil {
		t.Fatal("last-good launchers lost")
	}
}
