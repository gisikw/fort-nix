package main

import (
	"testing"
	"time"
)

// The launch mechanism must be real: spawn a trivial command, observe
// "playing" while it runs, and observe it clear when the child exits.
func TestLaunchMechanism(t *testing.T) {
	st := newTestStore(t)
	if err := st.Launch("alex", "jelly"); err != nil { // sh -c "sleep 0.2"
		t.Fatal(err)
	}
	st.mu.Lock()
	playing := st.playing
	st.mu.Unlock()
	if playing == nil || playing.App != "jelly" || playing.PID <= 0 {
		t.Fatalf("want playing jelly with a real pid, got %+v", playing)
	}

	// One screen, one app: a second launch while playing must 409.
	if code := httpCode(t, st.Launch("alex", "kart")); code != 409 {
		t.Fatalf("double launch: want 409, got %d", code)
	}

	// When the child exits, playing clears (the kiosk is simply there again).
	deadline := time.Now().Add(5 * time.Second)
	for {
		st.mu.Lock()
		done := st.playing == nil
		st.mu.Unlock()
		if done {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("playing never cleared after child exit")
		}
		time.Sleep(20 * time.Millisecond)
	}

	var sawLaunch, sawExit bool
	for _, e := range readLedger(t, st) {
		if e.Type == "launch" && e.App == "jelly" {
			sawLaunch = true
		}
		if e.Type == "app_exit" && e.App == "jelly" {
			sawExit = true
		}
	}
	if !sawLaunch || !sawExit {
		t.Fatalf("ledger missing launch/app_exit events (launch=%v exit=%v)", sawLaunch, sawExit)
	}
}

// Parents can stop the running app from the admin surface. The kill targets
// the exact process group of the child we spawned; the normal reap path then
// records app_exit and clears "playing".
func TestAdminStopApp(t *testing.T) {
	st := newTestStore(t)
	if code := httpCode(t, st.StopApp()); code != 409 {
		t.Fatalf("stop with nothing playing: want 409, got %d", code)
	}
	st.launchers["jelly"] = &LaunchSpec{Argv: []string{"sh", "-c", "sleep 30"}}
	if err := st.Launch("alex", "jelly"); err != nil {
		t.Fatal(err)
	}
	if err := st.StopApp(); err != nil {
		t.Fatal(err)
	}
	waitNotPlaying(t, st) // far sooner than the 30s sleep — the TERM landed
	var sawStop, sawExit bool
	for _, e := range readLedger(t, st) {
		if e.Type == "app_stop" && e.App == "jelly" {
			sawStop = true
		}
		if e.Type == "app_exit" && e.App == "jelly" {
			sawExit = true
		}
	}
	if !sawStop || !sawExit {
		t.Fatalf("ledger missing app_stop/app_exit (stop=%v exit=%v)", sawStop, sawExit)
	}
}

func TestLaunchValidation(t *testing.T) {
	st := newTestStore(t)
	// zelda is locked: not launchable
	if code := httpCode(t, st.Launch("alex", "zelda")); code != 409 {
		t.Fatalf("launch locked app: want 409, got %d", code)
	}
	// stux is stolen: not launchable
	if code := httpCode(t, st.Launch("alex", "stux")); code != 409 {
		t.Fatalf("launch stolen app: want 409, got %d", code)
	}
	// paint has no launcher configured (and is locked anyway); unlock it first
	st.Grant("bee", 100, "test")
	st.Mutate(func() ([]Event, error) { // put bee at zorp, off transit
		bee := st.state.findKid("bee")
		bee.Transit = nil
		return nil, nil
	})
	if err := st.Unlock("bee", "zorp", "paint"); err != nil {
		t.Fatal(err)
	}
	if code := httpCode(t, st.Launch("bee", "paint")); code != 409 {
		t.Fatalf("launch without launcher spec: want 409, got %d", code)
	}
	// launch-anywhere: alex is at prime, kart lives on blorf, still launchable
	if err := st.Launch("alex", "kart"); err != nil {
		t.Fatalf("launch from anywhere must work: %v", err)
	}
	waitNotPlaying(t, st) // let the child reap before the temp dir vanishes
}
