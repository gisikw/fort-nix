package main

// State types mirror the RATIONALE §5 payload shape near-verbatim.
// App unlock state lives on the planet (shared arcade); coins, chores,
// and rocket position live on the kid (INVARIANTS 7).

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const dateFmt = "2006-01-02"

type Chore struct {
	Name  string `json:"name"`
	Coins int    `json:"coins"`
	Done  bool   `json:"done"`
}

type Transit struct {
	To     string `json:"to"`
	Nights int    `json:"nights"`
}

type Kid struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Avatar   string   `json:"avatar"`
	Color    string   `json:"color"`
	Title    string   `json:"title"`
	Level    int      `json:"level"`
	XP       int      `json:"xp"`
	XPMax    int      `json:"xpMax"`
	Coins    int      `json:"coins"`
	Location string   `json:"location"`
	Transit  *Transit `json:"transit"`
	Chores   []*Chore `json:"chores"`
}

const (
	appReady  = "ready"
	appLocked = "locked"
	appStolen = "stolen"
)

type App struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Icon  string `json:"icon"`
	State string `json:"state"`
	Cost  int    `json:"cost,omitempty"`
}

type Planet struct {
	ID           string   `json:"id"`
	Name         string   `json:"name"`
	Emoji        string   `json:"emoji"`
	X            float64  `json:"x"`
	Y            float64  `json:"y"`
	Color        string   `json:"color"`
	CastleOwners []string `json:"castleOwners"`
	Undiscovered bool     `json:"undiscovered,omitempty"`
	Apps         []*App   `json:"apps"`
}

type State struct {
	Night        int       `json:"night"`
	LastTickDate string    `json:"lastTickDate"`
	Kids         []*Kid    `json:"kids"`
	Planets      []*Planet `json:"planets"`
}

func (s *State) findKid(id string) *Kid {
	for _, k := range s.Kids {
		if k.ID == id {
			return k
		}
	}
	return nil
}

func (s *State) findPlanet(id string) *Planet {
	for _, p := range s.Planets {
		if p.ID == id {
			return p
		}
	}
	return nil
}

// findApp locates an app by id across all planets. App ids are validated
// globally unique at load, so launch-from-anywhere needs only the app id.
func (s *State) findApp(id string) (*Planet, *App) {
	for _, p := range s.Planets {
		for _, a := range p.Apps {
			if a.ID == id {
				return p, a
			}
		}
	}
	return nil, nil
}

// nightsTo derives travel cost from map distance, same formula as the
// prototype: max(1, min(4, round(dist/26))).
func (s *State) nightsTo(fromID, toID string) int {
	from, to := s.findPlanet(fromID), s.findPlanet(toID)
	if from == nil || to == nil {
		return 1
	}
	n := int(math.Round(math.Hypot(to.X-from.X, to.Y-from.Y) / 26))
	if n < 1 {
		n = 1
	}
	if n > 4 {
		n = 4
	}
	return n
}

func (s *State) validate() error {
	appIDs := map[string]string{}
	for _, p := range s.Planets {
		for _, a := range p.Apps {
			if prev, dup := appIDs[a.ID]; dup {
				return fmt.Errorf("app id %q appears on both %q and %q — app ids must be globally unique", a.ID, prev, p.ID)
			}
			appIDs[a.ID] = p.ID
			switch a.State {
			case appReady, appLocked, appStolen:
			default:
				return fmt.Errorf("app %q has invalid state %q", a.ID, a.State)
			}
			if a.State != appReady && a.Cost <= 0 {
				return fmt.Errorf("app %q is %s but has no cost", a.ID, a.State)
			}
		}
	}
	for _, k := range s.Kids {
		if s.findPlanet(k.Location) == nil {
			return fmt.Errorf("kid %q is located at unknown planet %q", k.ID, k.Location)
		}
		if k.Transit != nil && s.findPlanet(k.Transit.To) == nil {
			return fmt.Errorf("kid %q is in transit to unknown planet %q", k.ID, k.Transit.To)
		}
	}
	for _, p := range s.Planets {
		for _, o := range p.CastleOwners {
			if s.findKid(o) == nil {
				return fmt.Errorf("planet %q lists unknown castle owner %q", p.ID, o)
			}
		}
	}
	return nil
}

// Playing is transient runtime state (not persisted): the child process the
// backend launched and is waiting on. Lost on restart by design — crash-only.
type Playing struct {
	App  string `json:"app"`
	Name string `json:"name"`
	Icon string `json:"icon"`
	Kid  string `json:"kid"`
	PID  int    `json:"-"`
}

// Payload is what the kiosk renders: the state plus transient/server fields.
// The admin surface renders the same payload (plus the ledger tail).
type Payload struct {
	Dev          bool      `json:"dev"`
	Date         string    `json:"date"`
	Night        int       `json:"night"`
	LastTickDate string    `json:"lastTickDate"`
	Playing      *Playing  `json:"playing"`
	Kids         []*Kid    `json:"kids"`
	Planets      []*Planet `json:"planets"`
}

// Store owns all mutable state behind one mutex. Every mutation appends its
// ledger events first (the ledger is the source of truth), then materializes
// state.json atomically, then broadcasts the new payload over SSE.
type Store struct {
	mu        sync.Mutex
	dir       string
	dev       bool
	state     *State
	launchers map[string]*LaunchSpec
	playing   *Playing
	hub       *Hub
	now       func() time.Time     // injectable for tests
	stamps    map[string]fileStamp // last file stamp the backend saw (watch.go)
}

func (st *Store) statePath() string    { return filepath.Join(st.dir, "state.json") }
func (st *Store) ledgerPath() string   { return filepath.Join(st.dir, "ledger.jsonl") }
func (st *Store) launcherPath() string { return filepath.Join(st.dir, "launchers.json") }

func OpenStore(dir string, dev bool) (*Store, error) {
	st := &Store{dir: dir, dev: dev, hub: newHub(), now: time.Now, stamps: map[string]fileStamp{}}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}

	if _, err := os.Stat(st.statePath()); os.IsNotExist(err) {
		if !dev {
			return nil, fmt.Errorf("%s not found — copy state.example.json there and edit it for this household", st.statePath())
		}
		if err := os.WriteFile(st.statePath(), exampleState, 0o644); err != nil {
			return nil, err
		}
	}
	raw, err := os.ReadFile(st.statePath())
	if err != nil {
		return nil, err
	}
	st.state = &State{}
	if err := json.Unmarshal(raw, st.state); err != nil {
		return nil, fmt.Errorf("parse %s: %w", st.statePath(), err)
	}
	if err := st.state.validate(); err != nil {
		return nil, fmt.Errorf("%s: %w", st.statePath(), err)
	}
	// A blank lastTickDate means "fresh install": start counting from today
	// rather than fast-forwarding from some placeholder date.
	if st.state.LastTickDate == "" {
		st.state.LastTickDate = st.now().Format(dateFmt)
		if err := st.saveStateLocked(); err != nil {
			return nil, err
		}
	}

	if err := st.loadLaunchers(); err != nil {
		return nil, err
	}
	if err := st.seedLedgerIfEmpty(); err != nil {
		return nil, err
	}
	st.reconcileLedger()
	st.rememberStampsLocked() // baseline the external-edit watcher (watch.go)
	return st, nil
}

// Mutate runs fn under the store lock; on success it stamps and appends the
// returned ledger events, saves state atomically, and broadcasts. Ledger
// append happens before the state write: if we crash between the two, the
// ledger (source of truth) is ahead and boot-time reconciliation flags it.
func (st *Store) Mutate(fn func() ([]Event, error)) error {
	st.mu.Lock()
	defer st.mu.Unlock()
	events, err := fn()
	if err != nil {
		return err
	}
	now := st.now()
	for i := range events {
		if events[i].TS == "" {
			events[i].TS = now.Format(time.RFC3339)
		}
		if events[i].Date == "" {
			events[i].Date = now.Format(dateFmt)
		}
		if events[i].Night == 0 {
			events[i].Night = st.state.Night
		}
	}
	if err := appendLedger(st.ledgerPath(), events); err != nil {
		return fmt.Errorf("ledger append: %w", err)
	}
	if err := st.saveStateLocked(); err != nil {
		return fmt.Errorf("state save: %w", err)
	}
	st.broadcastLocked()
	return nil
}

func (st *Store) saveStateLocked() error {
	data, err := json.MarshalIndent(st.state, "", "  ")
	if err != nil {
		return err
	}
	tmp := st.statePath() + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, st.statePath()); err != nil {
		return err
	}
	// Record our own write so the watcher never mistakes it for a hand-edit.
	if fs, err := stampFile(st.statePath()); err == nil {
		st.stamps[st.statePath()] = fs
	}
	return nil
}

func (st *Store) payloadLocked() []byte {
	p := Payload{
		Dev:          st.dev,
		Date:         st.now().Format(dateFmt),
		Night:        st.state.Night,
		LastTickDate: st.state.LastTickDate,
		Playing:      st.playing,
		Kids:         st.state.Kids,
		Planets:      st.state.Planets,
	}
	data, err := json.Marshal(p)
	if err != nil {
		// Marshal of our own types cannot fail in practice; keep the kiosk
		// alive with an empty payload rather than panicking.
		return []byte("{}")
	}
	return data
}

func (st *Store) PayloadJSON() []byte {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.payloadLocked()
}

func (st *Store) broadcastLocked() {
	st.hub.Broadcast(st.payloadLocked())
}
