package main

// File-change reload: hand-edits to state.json / launchers.json (explicitly
// blessed by INVARIANTS 9 "hand-editable") propagate to the running server
// without a restart. A 1s stat poll (mtime+size) keeps the stdlib-only
// judgment call from the buildout intact — fsnotify would cost the module
// its only-dependency-free build (vendorHash = null) for no household-scale
// gain in latency.
//
// Own writes never trigger a reload: every backend write records the file's
// post-write stamp under the store lock, and the poller skips files whose
// stamp it has already seen. Malformed or invalid external content keeps the
// last-good state and logs — the kiosk never crashes and never goes blank on
// a half-saved editor buffer (INVARIANTS 1).

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"time"
)

type fileStamp struct {
	mod  time.Time
	size int64
}

func stampFile(path string) (fileStamp, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return fileStamp{}, err
	}
	return fileStamp{fi.ModTime(), fi.Size()}, nil
}

// rememberStampsLocked baselines the poller to the files as they are now.
func (st *Store) rememberStampsLocked() {
	for _, p := range []string{st.statePath(), st.launcherPath()} {
		if fs, err := stampFile(p); err == nil {
			st.stamps[p] = fs
		}
	}
}

// watchFiles polls for external edits until the process dies. Crash-only:
// no shutdown plumbing, same as the tick loop.
func (st *Store) watchFiles(interval time.Duration) {
	for range time.Tick(interval) {
		st.checkExternalChanges()
	}
}

// checkExternalChanges is one poll pass; returns whether anything reloaded.
// Split out from the loop so tests can drive it deterministically.
func (st *Store) checkExternalChanges() bool {
	st.mu.Lock()
	defer st.mu.Unlock()
	changed := false
	if st.reloadIfChangedLocked(st.statePath(), st.loadStateLocked) {
		changed = true
	}
	if st.reloadIfChangedLocked(st.launcherPath(), st.loadLaunchersLocked) {
		changed = true
	}
	if changed {
		st.broadcastLocked()
	}
	return changed
}

// reloadIfChangedLocked stats the file against the last stamp the backend
// saw (its own writes update that stamp, so they never re-trigger). A stamp
// that moves again between stat and read means a write is still in flight —
// skip and let the next poll pick up the finished file. Content that fails
// to load records the stamp anyway (one warning, not one per second) and
// keeps last-good state; the next external change is examined fresh.
func (st *Store) reloadIfChangedLocked(path string, load func([]byte) error) bool {
	before, err := stampFile(path)
	if err != nil || before == st.stamps[path] {
		return false
	}
	raw, readErr := os.ReadFile(path)
	after, statErr := stampFile(path)
	if statErr != nil || after != before || readErr != nil {
		return false
	}
	st.stamps[path] = after
	if err := load(raw); err != nil {
		log.Printf("WARNING: external change to %s NOT loaded, keeping last-good state: %v", path, err)
		return false
	}
	log.Printf("reloaded %s after external change", path)
	return true
}

func (st *Store) loadStateLocked(raw []byte) error {
	s := &State{}
	if err := json.Unmarshal(raw, s); err != nil {
		return err
	}
	if err := s.validate(); err != nil {
		return err
	}
	if s.LastTickDate == "" {
		// Same fresh-install rule as boot; persisted by the next mutation.
		s.LastTickDate = st.now().Format(dateFmt)
	}
	st.state = s
	// Hand-edited coins without a ledger event get the same loud warning as
	// at boot — and we keep serving, exactly like boot (INVARIANTS 1).
	st.reconcileLedger()
	return nil
}

func (st *Store) loadLaunchersLocked(raw []byte) error {
	launchers := map[string]*LaunchSpec{}
	if err := json.Unmarshal(raw, &launchers); err != nil {
		return err
	}
	for id, spec := range launchers {
		if spec == nil || len(spec.Argv) == 0 {
			return fmt.Errorf("launcher %q has no argv", id)
		}
	}
	st.launchers = launchers
	return nil
}
