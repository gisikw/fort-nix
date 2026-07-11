package main

// Domain actions. Kid-facing: travel, unlock, battle-win, launch (launcher.go).
// Management-plane: grant, chore-check, steal, tick (tick.go). All enforce the
// economy invariants; the app state machine is exactly
// locked → ready → stolen → locked (INVARIANTS 8).

import (
	"fmt"
	"strings"
)

type httpError struct {
	code int
	msg  string
}

func (e *httpError) Error() string { return e.msg }

func errBad(format string, a ...any) error      { return &httpError{400, fmt.Sprintf(format, a...)} }
func errNotFound(format string, a ...any) error { return &httpError{404, fmt.Sprintf(format, a...)} }
func errConflict(format string, a ...any) error { return &httpError{409, fmt.Sprintf(format, a...)} }

// atPlanet: unlock-here semantics — rocket present and not mid-flight.
func atPlanet(k *Kid, planetID string) bool {
	return k.Location == planetID && k.Transit == nil
}

func (st *Store) Travel(kidID, to string) error {
	return st.Mutate(func() ([]Event, error) {
		k := st.state.findKid(kidID)
		if k == nil {
			return nil, errNotFound("unknown kid %q", kidID)
		}
		p := st.state.findPlanet(to)
		if p == nil {
			return nil, errNotFound("unknown planet %q", to)
		}
		if p.Undiscovered {
			return nil, errConflict("%q is not discovered yet", to)
		}
		if atPlanet(k, to) {
			return nil, errConflict("already at %q", to)
		}
		if k.Transit != nil && k.Transit.To == to {
			return nil, errConflict("already on course to %q", to)
		}
		nights := st.state.nightsTo(k.Location, to)
		k.Transit = &Transit{To: to, Nights: nights}
		return []Event{{
			Type: "travel_set", Kid: kidID, Planet: to,
			Note: fmt.Sprintf("%d night(s) from %s", nights, k.Location),
		}}, nil
	})
}

func (st *Store) Unlock(kidID, planetID, appID string) error {
	return st.Mutate(func() ([]Event, error) {
		k := st.state.findKid(kidID)
		if k == nil {
			return nil, errNotFound("unknown kid %q", kidID)
		}
		p := st.state.findPlanet(planetID)
		if p == nil {
			return nil, errNotFound("unknown planet %q", planetID)
		}
		app := findAppOn(p, appID)
		if app == nil {
			return nil, errNotFound("no app %q on planet %q", appID, planetID)
		}
		if app.State != appLocked {
			return nil, errConflict("app %q is %s, not locked", appID, app.State)
		}
		if !atPlanet(k, planetID) {
			return nil, errConflict("kid %q is not at %q — unlocking requires being there", kidID, planetID)
		}
		if k.Coins < app.Cost {
			return nil, errConflict("kid %q has %d coins, needs %d", kidID, k.Coins, app.Cost)
		}
		k.Coins -= app.Cost
		app.State = appReady
		bal := k.Coins
		return []Event{{
			Type: "unlock", Kid: kidID, Planet: planetID, App: appID,
			Coins: -app.Cost, Balance: &bal,
		}}, nil
	})
}

// BattleWin resolves the on-rails battle: stolen → locked. The battle is
// guaranteed-win drama; reclaiming then costs the re-unlock (a separate
// Unlock call), so the total price is the trip plus the coins.
func (st *Store) BattleWin(kidID, planetID, appID string) error {
	return st.Mutate(func() ([]Event, error) {
		k := st.state.findKid(kidID)
		if k == nil {
			return nil, errNotFound("unknown kid %q", kidID)
		}
		p := st.state.findPlanet(planetID)
		if p == nil {
			return nil, errNotFound("unknown planet %q", planetID)
		}
		app := findAppOn(p, appID)
		if app == nil {
			return nil, errNotFound("no app %q on planet %q", appID, planetID)
		}
		if app.State != appStolen {
			return nil, errConflict("app %q is %s, not stolen", appID, app.State)
		}
		if !atPlanet(k, planetID) {
			return nil, errConflict("kid %q is not at %q — the battle happens there", kidID, planetID)
		}
		app.State = appLocked
		return []Event{{
			Type: "battle_win", Kid: kidID, Planet: planetID, App: appID,
			Note: fmt.Sprintf("reclaimed from Dadmonster — re-unlock for %d", app.Cost),
		}}, nil
	})
}

// ── Management-plane operations (mesh-internal; today's client is curl,
//    tomorrow's is the admin surface — same API, no UI here). ──────────────

// Grant is the only way coins enter the system (INVARIANTS 5).
func (st *Store) Grant(kidID string, coins int, reason string) error {
	return st.Mutate(func() ([]Event, error) {
		k := st.state.findKid(kidID)
		if k == nil {
			return nil, errNotFound("unknown kid %q", kidID)
		}
		if coins == 0 {
			return nil, errBad("coins must be nonzero")
		}
		if k.Coins+coins < 0 {
			return nil, errConflict("kid %q has %d coins; grant of %d would go negative", kidID, k.Coins, coins)
		}
		k.Coins += coins
		bal := k.Coins
		return []Event{{
			Type: "grant", Kid: kidID, Coins: coins, Balance: &bal, Note: reason,
		}}, nil
	})
}

// ChoreCheck marks one of today's chores done and grants its coins.
func (st *Store) ChoreCheck(kidID, choreName string) error {
	return st.Mutate(func() ([]Event, error) {
		k := st.state.findKid(kidID)
		if k == nil {
			return nil, errNotFound("unknown kid %q", kidID)
		}
		for _, c := range k.Chores {
			if c.Name == choreName && !c.Done {
				c.Done = true
				k.Coins += c.Coins
				bal := k.Coins
				return []Event{{
					Type: "chore_check", Kid: kidID, Coins: c.Coins, Balance: &bal, Note: c.Name,
				}}, nil
			}
		}
		return nil, errNotFound("kid %q has no unchecked chore %q today", kidID, choreName)
	})
}

// ChoreUncheck reverses a mis-tapped check-off: done → false, and the coins
// come back out with a ledger event — a deduction is never silent
// (INVARIANTS 10). If the kid already spent below the chore's value the
// uncheck is refused rather than going negative; correct with a grant.
func (st *Store) ChoreUncheck(kidID, choreName string) error {
	return st.Mutate(func() ([]Event, error) {
		k := st.state.findKid(kidID)
		if k == nil {
			return nil, errNotFound("unknown kid %q", kidID)
		}
		for _, c := range k.Chores {
			if c.Name == choreName && c.Done {
				if k.Coins < c.Coins {
					return nil, errConflict("kid %q has %d coins; unchecking %q would take back %d and go negative — use a grant to correct instead", kidID, k.Coins, choreName, c.Coins)
				}
				c.Done = false
				k.Coins -= c.Coins
				bal := k.Coins
				return []Event{{
					Type: "chore_uncheck", Kid: kidID, Coins: -c.Coins, Balance: &bal, Note: c.Name,
				}}, nil
			}
		}
		return nil, errNotFound("kid %q has no checked chore %q today", kidID, choreName)
	})
}

// SetChores replaces a kid's daily chore list — the management plane owns
// the list, the tick only clears check-offs. Done flags carry over by name,
// and incoming done flags are ignored: check-off must go through ChoreCheck
// so the coins and the ledger event always travel together (INVARIANTS 5/10).
func (st *Store) SetChores(kidID string, chores []*Chore) error {
	return st.Mutate(func() ([]Event, error) {
		k := st.state.findKid(kidID)
		if k == nil {
			return nil, errNotFound("unknown kid %q", kidID)
		}
		seen := map[string]bool{}
		for _, c := range chores {
			if strings.TrimSpace(c.Name) == "" {
				return nil, errBad("chore names must be nonempty")
			}
			if c.Coins < 0 {
				return nil, errBad("chore %q: coins must be >= 0", c.Name)
			}
			if seen[c.Name] {
				return nil, errBad("duplicate chore %q — check-off matches by name", c.Name)
			}
			seen[c.Name] = true
		}
		done := map[string]bool{}
		for _, c := range k.Chores {
			if c.Done {
				done[c.Name] = true
			}
		}
		if chores == nil {
			chores = []*Chore{} // marshal as [], never null — the kiosk iterates it
		}
		names := make([]string, len(chores))
		for i, c := range chores {
			c.Done = done[c.Name]
			names[i] = fmt.Sprintf("%s (%d)", c.Name, c.Coins)
		}
		k.Chores = chores
		return []Event{{
			Type: "chores_edit", Kid: kidID, Note: "list is now: " + strings.Join(names, ", "),
		}}, nil
	})
}

// Steal is the parent-triggered Dadmonster event: ready → stolen. Never RNG
// (INVARIANTS 3). Cost may be set here (it becomes the re-unlock price); an
// app that never had a cost needs one supplied.
func (st *Store) Steal(planetID, appID string, cost int) error {
	return st.Mutate(func() ([]Event, error) {
		p := st.state.findPlanet(planetID)
		if p == nil {
			return nil, errNotFound("unknown planet %q", planetID)
		}
		app := findAppOn(p, appID)
		if app == nil {
			return nil, errNotFound("no app %q on planet %q", appID, planetID)
		}
		if app.State != appReady {
			return nil, errConflict("app %q is %s — only ready apps can be stolen", appID, app.State)
		}
		if cost < 0 {
			return nil, errBad("cost must be positive")
		}
		if cost > 0 {
			app.Cost = cost
		}
		if app.Cost <= 0 {
			return nil, errBad("app %q has no cost — pass one so the re-unlock has a price", appID)
		}
		app.State = appStolen
		return []Event{{
			Type: "steal", Planet: planetID, App: appID,
			Note: fmt.Sprintf("Dadmonster strikes — reclaim + re-unlock for %d", app.Cost),
		}}, nil
	})
}

func findAppOn(p *Planet, appID string) *App {
	for _, a := range p.Apps {
		if a.ID == appID {
			return a
		}
	}
	return nil
}
