package main

// The ledger is an append-only JSONL event log (INVARIANTS 9–10): every coin
// movement, unlock, steal, reclaim, travel, and launch lands here. Balances
// are reconstructible from it; state.json is a materialization.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"os"
)

type Event struct {
	TS      string `json:"ts"`
	Date    string `json:"date"`
	Night   int    `json:"night"`
	Type    string `json:"type"`
	Kid     string `json:"kid,omitempty"`
	Planet  string `json:"planet,omitempty"`
	App     string `json:"app,omitempty"`
	Coins   int    `json:"coins,omitempty"`
	Balance *int   `json:"balance,omitempty"`
	Note    string `json:"note,omitempty"`
}

func appendLedger(path string, events []Event) error {
	if len(events) == 0 {
		return nil
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	for _, e := range events {
		if err := enc.Encode(e); err != nil {
			return err
		}
	}
	return f.Sync()
}

// replayBalances reconstructs per-kid coin balances from the ledger alone.
func replayBalances(path string) (map[string]int, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	balances := map[string]int{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	line := 0
	for sc.Scan() {
		line++
		if len(sc.Bytes()) == 0 {
			continue
		}
		var e Event
		if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
			return nil, fmt.Errorf("ledger line %d: %w", line, err)
		}
		if e.Kid != "" && e.Coins != 0 {
			balances[e.Kid] += e.Coins
		}
	}
	return balances, sc.Err()
}

// ledgerTail returns the last n events, newest first, for the admin read
// view. Reads the whole file (household-scale: one ledger line per coin
// movement, a few per day) and skips malformed lines rather than failing —
// a hand-mangled line must not take the recent-activity view down with it.
func ledgerTail(path string, n int) ([]Event, error) {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return []Event{}, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var events []Event
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		if len(sc.Bytes()) == 0 {
			continue
		}
		var e Event
		if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
			continue
		}
		events = append(events, e)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if len(events) > n {
		events = events[len(events)-n:]
	}
	for i, j := 0, len(events)-1; i < j; i, j = i+1, j-1 {
		events[i], events[j] = events[j], events[i]
	}
	return events, nil
}

// seedLedgerIfEmpty writes a seed event per kid when the ledger doesn't exist
// yet, so replayed balances have a baseline matching the initial state file.
func (st *Store) seedLedgerIfEmpty() error {
	info, err := os.Stat(st.ledgerPath())
	if err == nil && info.Size() > 0 {
		return nil
	}
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	now := st.now()
	var events []Event
	for _, k := range st.state.Kids {
		bal := k.Coins
		events = append(events, Event{
			TS: now.Format("2006-01-02T15:04:05Z07:00"), Date: now.Format(dateFmt),
			Night: st.state.Night, Type: "seed", Kid: k.ID,
			Coins: k.Coins, Balance: &bal, Note: "initial balance",
		})
	}
	return appendLedger(st.ledgerPath(), events)
}

// reconcileLedger compares replayed balances against the state file at boot.
// A mismatch means someone hand-edited coins without a ledger event (or a
// crash landed between ledger append and state write). We warn loudly but
// keep serving: the kiosk must always come up (INVARIANTS 1).
func (st *Store) reconcileLedger() {
	balances, err := replayBalances(st.ledgerPath())
	if err != nil {
		log.Printf("WARNING: cannot replay ledger: %v", err)
		return
	}
	for _, k := range st.state.Kids {
		if got, want := balances[k.ID], k.Coins; got != want {
			log.Printf("WARNING: ledger/state mismatch for kid %q: ledger says %d, state.json says %d — hand-edited coins? add a grant event", k.ID, got, want)
		}
	}
}
