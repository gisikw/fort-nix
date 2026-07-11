package main

// The nightly tick: date-keyed and idempotent (INVARIANTS 12). Each calendar
// day between lastTickDate and the target date advances the night counter,
// decrements transits (arriving at zero), and resets chore check-offs for the
// new day. Running twice for the same date is a no-op; missed days (host off,
// backend down) catch up on the next run.

import (
	"fmt"
	"log"
	"time"
)

// tickTo advances state day by day up to target. Returns the ledger events
// and how many days were advanced. Not locked — callers go through Mutate.
func tickTo(s *State, target time.Time) ([]Event, int) {
	last, err := time.ParseInLocation(dateFmt, s.LastTickDate, target.Location())
	if err != nil {
		// Corrupt lastTickDate: re-key from target rather than guessing.
		s.LastTickDate = target.Format(dateFmt)
		return nil, 0
	}
	// Compare calendar dates in the target's own location, not absolute time.
	ty, tm, td := target.Date()
	target = time.Date(ty, tm, td, 0, 0, 0, 0, target.Location())
	var events []Event
	days := 0
	for d := last.AddDate(0, 0, 1); !d.After(target); d = d.AddDate(0, 0, 1) {
		days++
		s.Night++
		date := d.Format(dateFmt)
		events = append(events, Event{Type: "tick", Date: date, Night: s.Night})
		for _, k := range s.Kids {
			if k.Transit != nil {
				k.Transit.Nights--
				if k.Transit.Nights <= 0 {
					k.Location = k.Transit.To
					k.Transit = nil
					events = append(events, Event{
						Type: "arrive", Date: date, Night: s.Night,
						Kid: k.ID, Planet: k.Location,
					})
				}
			}
			// New day, fresh chore list. Chores themselves are owned by the
			// management plane; the tick only clears yesterday's check-offs.
			for _, c := range k.Chores {
				c.Done = false
			}
		}
		s.LastTickDate = date
	}
	return events, days
}

// Tick advances to the given target date through the normal mutation path.
func (st *Store) Tick(target time.Time) (int, error) {
	days := 0
	err := st.Mutate(func() ([]Event, error) {
		var events []Event
		events, days = tickTo(st.state, target)
		return events, nil
	})
	return days, err
}

// tickLoop runs the in-process nightly tick: checks once a minute whether the
// calendar date has moved past lastTickDate. Cheap, idempotent, no cron dep.
func (st *Store) tickLoop() {
	for range time.Tick(time.Minute) {
		if days, err := st.Tick(st.now()); err != nil {
			log.Printf("nightly tick failed: %v", err)
		} else if days > 0 {
			log.Printf("nightly tick: advanced %d day(s)", days)
		}
	}
}

// resolveTickTarget maps an admin tick request body to a target date.
// {} → today; {"date":"YYYY-MM-DD"} → that date; {"days":N} → lastTickDate+N
// (a testing affordance — lets tests and dev-mode sim advance virtual days).
func (st *Store) resolveTickTarget(date string, days int) (time.Time, error) {
	if date != "" && days != 0 {
		return time.Time{}, fmt.Errorf("pass either date or days, not both")
	}
	if date != "" {
		t, err := time.ParseInLocation(dateFmt, date, st.now().Location())
		if err != nil {
			return time.Time{}, fmt.Errorf("bad date %q: want YYYY-MM-DD", date)
		}
		return t, nil
	}
	if days != 0 {
		if days < 0 {
			return time.Time{}, fmt.Errorf("days must be positive")
		}
		st.mu.Lock()
		last := st.state.LastTickDate
		st.mu.Unlock()
		t, err := time.ParseInLocation(dateFmt, last, st.now().Location())
		if err != nil {
			return time.Time{}, err
		}
		return t.AddDate(0, 0, days), nil
	}
	return st.now(), nil
}
