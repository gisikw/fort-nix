package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Test fixture: same shape as state.example.json, smaller. alex is at prime;
// bee is at zorp, in transit to blorf (2 nights).
const testState = `{
  "night": 10,
  "lastTickDate": "2026-07-01",
  "kids": [
    {"id":"alex","name":"Alex","avatar":"A","color":"#d4af37","title":"Paladin",
     "level":14,"xp":640,"xpMax":1000,"coins":100,"location":"prime","transit":null,
     "chores":[{"name":"Clean the room","coins":15,"done":true},
               {"name":"Take out the trash","coins":10,"done":false}]},
    {"id":"bee","name":"Bee","avatar":"B","color":"#23e5ff","title":"Star Cadet",
     "level":6,"xp":180,"xpMax":400,"coins":40,"location":"zorp",
     "transit":{"to":"blorf","nights":2},
     "chores":[{"name":"Clear the table","coins":10,"done":false}]}
  ],
  "planets": [
    {"id":"prime","name":"Castle Prime","emoji":"P","x":12,"y":74,"color":"#d4af37",
     "castleOwners":["alex","bee"],
     "apps":[{"id":"jelly","name":"Jellyfin","icon":"J","state":"ready"},
             {"id":"stux","name":"SuperTux","icon":"S","state":"stolen","cost":40},
             {"id":"zelda","name":"Link to the Past","icon":"Z","state":"locked","cost":120}]},
    {"id":"zorp","name":"Zorp","emoji":"Z","x":40,"y":50,"color":"#7dffb0",
     "castleOwners":["bee"],
     "apps":[{"id":"paint","name":"Tux Paint","icon":"T","state":"locked","cost":30}]},
    {"id":"blorf","name":"Blorf","emoji":"B","x":66,"y":28,"color":"#ffb37d",
     "castleOwners":["alex"],
     "apps":[{"id":"kart","name":"SuperTuxKart","icon":"K","state":"ready","cost":60}]},
    {"id":"mars","name":"Mars","emoji":"M","x":86,"y":66,"color":"#ff8a5c",
     "castleOwners":[],"undiscovered":true,"apps":[]}
  ]
}`

func testLaunchers() string {
	return `{
  "jelly": {"argv": ["sh", "-c", "sleep 0.2"]},
  "kart":  {"argv": ["sh", "-c", "exit 0"]}
}`
}

func newTestStore(t *testing.T) *Store {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "state.json"), []byte(testState), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "launchers.json"), []byte(testLaunchers()), 0o644); err != nil {
		t.Fatal(err)
	}
	st, err := OpenStore(dir, false)
	if err != nil {
		t.Fatal(err)
	}
	return st
}

func date(t *testing.T, s string) time.Time {
	t.Helper()
	d, err := time.ParseInLocation(dateFmt, s, time.Local)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func httpCode(t *testing.T, err error) int {
	t.Helper()
	if err == nil {
		t.Fatal("expected an error")
	}
	he, ok := err.(*httpError)
	if !ok {
		t.Fatalf("expected *httpError, got %T: %v", err, err)
	}
	return he.code
}

// ── economy invariants ──────────────────────────────────────────────────────

func TestUnlockRequiresPresence(t *testing.T) {
	st := newTestStore(t)
	// bee is at zorp (in transit): can't unlock at prime
	if code := httpCode(t, st.Unlock("bee", "prime", "zelda")); code != 409 {
		t.Fatalf("unlock away from planet: want 409, got %d", code)
	}
	// bee is AT zorp by location, but mid-transit: presence requires !transit
	if code := httpCode(t, st.Unlock("bee", "zorp", "paint")); code != 409 {
		t.Fatalf("unlock while in transit: want 409, got %d", code)
	}
}

func TestUnlockInsufficientCoins(t *testing.T) {
	st := newTestStore(t)
	// alex at prime with 100 coins; zelda costs 120
	if code := httpCode(t, st.Unlock("alex", "prime", "zelda")); code != 409 {
		t.Fatalf("want 409, got %d", code)
	}
	if k := st.state.findKid("alex"); k.Coins != 100 {
		t.Fatalf("coins must be untouched, got %d", k.Coins)
	}
}

func TestUnlockHappyPath(t *testing.T) {
	st := newTestStore(t)
	if err := st.Grant("alex", 50, "test grant"); err != nil {
		t.Fatal(err)
	}
	if err := st.Unlock("alex", "prime", "zelda"); err != nil {
		t.Fatal(err)
	}
	k := st.state.findKid("alex")
	if k.Coins != 30 {
		t.Fatalf("want 30 coins after 100+50-120, got %d", k.Coins)
	}
	_, app := st.state.findApp("zelda")
	if app.State != appReady {
		t.Fatalf("want ready, got %s", app.State)
	}
	// unlocking again must fail: ready is not locked
	if code := httpCode(t, st.Unlock("alex", "prime", "zelda")); code != 409 {
		t.Fatalf("double unlock: want 409, got %d", code)
	}
}

func TestGrantIsOnlyMint(t *testing.T) {
	st := newTestStore(t)
	if code := httpCode(t, st.Grant("alex", 0, "zero")); code != 400 {
		t.Fatalf("zero grant: want 400, got %d", code)
	}
	if code := httpCode(t, st.Grant("alex", -500, "overdraw")); code != 409 {
		t.Fatalf("negative balance: want 409, got %d", code)
	}
	if err := st.Grant("alex", -50, "correction"); err != nil {
		t.Fatal(err) // corrections that keep balance non-negative are fine
	}
}

func TestChoreCheck(t *testing.T) {
	st := newTestStore(t)
	if err := st.ChoreCheck("alex", "Take out the trash"); err != nil {
		t.Fatal(err)
	}
	k := st.state.findKid("alex")
	if k.Coins != 110 {
		t.Fatalf("want 110, got %d", k.Coins)
	}
	// same chore twice: it's already done
	if code := httpCode(t, st.ChoreCheck("alex", "Take out the trash")); code != 404 {
		t.Fatalf("want 404, got %d", code)
	}
}

// ── app state machine (locked → ready → stolen → locked, nothing else) ─────

func TestStateMachine(t *testing.T) {
	st := newTestStore(t)
	// steal requires ready
	if code := httpCode(t, st.Steal("prime", "zelda", 0)); code != 409 {
		t.Fatalf("steal locked app: want 409, got %d", code)
	}
	// steal a ready app with no cost and no cost given → sharp error
	if code := httpCode(t, st.Steal("prime", "jelly", 0)); code != 400 {
		t.Fatalf("steal costless app: want 400, got %d", code)
	}
	if err := st.Steal("prime", "jelly", 25); err != nil {
		t.Fatal(err)
	}
	_, jelly := st.state.findApp("jelly")
	if jelly.State != appStolen || jelly.Cost != 25 {
		t.Fatalf("want stolen/25, got %s/%d", jelly.State, jelly.Cost)
	}
	// battle-win requires presence: alex is at prime, so this works
	if err := st.BattleWin("alex", "prime", "jelly"); err != nil {
		t.Fatal(err)
	}
	if jelly.State != appLocked {
		t.Fatalf("won battle: want locked, got %s", jelly.State)
	}
	// battle-win on a non-stolen app is invalid
	if code := httpCode(t, st.BattleWin("alex", "prime", "jelly")); code != 409 {
		t.Fatalf("battle non-stolen: want 409, got %d", code)
	}
	// battle-win away from the planet is invalid (bee is not at prime)
	if err := st.Steal("blorf", "kart", 0); err != nil {
		t.Fatal(err)
	}
	if code := httpCode(t, st.BattleWin("bee", "blorf", "kart")); code != 409 {
		t.Fatalf("battle from afar: want 409, got %d", code)
	}
}

// ── travel ──────────────────────────────────────────────────────────────────

func TestTravelValidation(t *testing.T) {
	st := newTestStore(t)
	if code := httpCode(t, st.Travel("alex", "mars")); code != 409 {
		t.Fatalf("travel to undiscovered: want 409, got %d", code)
	}
	if code := httpCode(t, st.Travel("alex", "prime")); code != 409 {
		t.Fatalf("travel to current planet: want 409, got %d", code)
	}
	if err := st.Travel("alex", "blorf"); err != nil {
		t.Fatal(err)
	}
	k := st.state.findKid("alex")
	// prime(12,74)→blorf(66,28): hypot(54,46)=70.9 → round(2.73)=3 nights
	if k.Transit == nil || k.Transit.To != "blorf" || k.Transit.Nights != 3 {
		t.Fatalf("want transit to blorf in 3 nights, got %+v", k.Transit)
	}
	if code := httpCode(t, st.Travel("alex", "blorf")); code != 409 {
		t.Fatalf("re-course to same dest: want 409, got %d", code)
	}
}

// ── nightly tick (INVARIANTS 12) ────────────────────────────────────────────

func TestTickIdempotent(t *testing.T) {
	st := newTestStore(t)
	days, err := st.Tick(date(t, "2026-07-02"))
	if err != nil || days != 1 {
		t.Fatalf("first tick: want 1 day, got %d (%v)", days, err)
	}
	night := st.state.Night
	days, err = st.Tick(date(t, "2026-07-02"))
	if err != nil || days != 0 {
		t.Fatalf("same-date second tick must be a no-op, advanced %d (%v)", days, err)
	}
	if st.state.Night != night {
		t.Fatalf("night moved on a same-date tick: %d → %d", night, st.state.Night)
	}
	// past dates are also no-ops
	if days, _ = st.Tick(date(t, "2026-06-15")); days != 0 {
		t.Fatalf("past-date tick must be a no-op, advanced %d", days)
	}
}

func TestTickCatchUpAdvancesTransit(t *testing.T) {
	st := newTestStore(t)
	st.ChoreCheck("alex", "Take out the trash") // done=true, to verify reset
	// 3-day gap: bee's 2-night transit lands on day 2; day 3 is a plain night
	days, err := st.Tick(date(t, "2026-07-04"))
	if err != nil || days != 3 {
		t.Fatalf("want 3 days advanced, got %d (%v)", days, err)
	}
	if st.state.Night != 13 {
		t.Fatalf("want night 13, got %d", st.state.Night)
	}
	bee := st.state.findKid("bee")
	if bee.Location != "blorf" || bee.Transit != nil {
		t.Fatalf("bee should have arrived at blorf, got loc=%s transit=%+v", bee.Location, bee.Transit)
	}
	for _, k := range st.state.Kids {
		for _, c := range k.Chores {
			if c.Done {
				t.Fatalf("chore %q still done after tick — new day must reset check-offs", c.Name)
			}
		}
	}
	// arrival must be in the ledger, dated to the simulated day
	found := false
	for _, e := range readLedger(t, st) {
		if e.Type == "arrive" && e.Kid == "bee" && e.Planet == "blorf" && e.Date == "2026-07-03" {
			found = true
		}
	}
	if !found {
		t.Fatal("no arrive event for bee@blorf dated 2026-07-03 in ledger")
	}
}

// ── ledger (INVARIANTS 10): balances reconstructible ────────────────────────

func readLedger(t *testing.T, st *Store) []Event {
	t.Helper()
	raw, err := os.ReadFile(st.ledgerPath())
	if err != nil {
		t.Fatal(err)
	}
	var events []Event
	for _, line := range splitLines(raw) {
		var e Event
		if err := json.Unmarshal(line, &e); err != nil {
			t.Fatal(err)
		}
		events = append(events, e)
	}
	return events
}

func splitLines(raw []byte) [][]byte {
	var out [][]byte
	start := 0
	for i, b := range raw {
		if b == '\n' {
			if i > start {
				out = append(out, raw[start:i])
			}
			start = i + 1
		}
	}
	return out
}

func TestLedgerReconstruction(t *testing.T) {
	st := newTestStore(t)
	st.Grant("alex", 100, "bounty")
	st.ChoreCheck("bee", "Clear the table")
	st.Unlock("alex", "prime", "zelda") // 200 - 120 = 80
	st.Grant("alex", -30, "correction")

	balances, err := replayBalances(st.ledgerPath())
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range st.state.Kids {
		if balances[k.ID] != k.Coins {
			t.Fatalf("kid %s: ledger replays %d, state has %d", k.ID, balances[k.ID], k.Coins)
		}
	}
}

// ── crash-only (INVARIANTS 1): reopen from files, state intact ─────────────

func TestCrashRecovery(t *testing.T) {
	st := newTestStore(t)
	st.Grant("alex", 100, "pre-crash")
	st.Unlock("alex", "prime", "zelda")
	st.Travel("alex", "zorp")

	// Simulate kill -9 + restart: a brand-new store from the same files.
	st2, err := OpenStore(st.dir, false)
	if err != nil {
		t.Fatal(err)
	}
	k := st2.state.findKid("alex")
	if k.Coins != 80 {
		t.Fatalf("want 80 coins after restart, got %d", k.Coins)
	}
	if _, app := st2.state.findApp("zelda"); app.State != appReady {
		t.Fatalf("want zelda ready after restart, got %s", app.State)
	}
	if k.Transit == nil || k.Transit.To != "zorp" {
		t.Fatalf("want transit to zorp after restart, got %+v", k.Transit)
	}
	balances, err := replayBalances(st2.ledgerPath())
	if err != nil {
		t.Fatal(err)
	}
	if balances["alex"] != 80 {
		t.Fatalf("ledger replay after restart: want 80, got %d", balances["alex"])
	}
}
