package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The bug this whole file exists for: a failed activation was never recorded,
// so every check cycle rediscovered the same broken store path as "new" and
// retried it forever (coffer on lordhenry, every 5 minutes, indefinitely).

func TestRecordAttemptPersistsPathAndReason(t *testing.T) {
	dir := t.TempDir()
	recordAttempt(dir, "/nix/store/aaa-coffer", "failed", "health checks failed")

	got := loadAttemptFile(filepath.Join(dir, "last-attempt.json"))
	if got == nil {
		t.Fatal("attempt not persisted")
	}
	if got.StorePath != "/nix/store/aaa-coffer" {
		t.Errorf("StorePath = %q, want /nix/store/aaa-coffer", got.StorePath)
	}
	if got.State != "failed" {
		t.Errorf("State = %q, want failed", got.State)
	}
	if got.Reason != "health checks failed" {
		t.Errorf("Reason = %q, want health checks failed", got.Reason)
	}
	if got.Attempts != 1 {
		t.Errorf("Attempts = %d, want 1", got.Attempts)
	}
}

func TestRecordAttemptCountsRepeatsOfSamePath(t *testing.T) {
	dir := t.TempDir()
	for i := 0; i < 3; i++ {
		recordAttempt(dir, "/nix/store/aaa-coffer", "rolled-back", "health checks failed")
	}

	got := loadAttemptFile(filepath.Join(dir, "last-attempt.json"))
	if got.Attempts != 3 {
		t.Errorf("Attempts = %d, want 3", got.Attempts)
	}
}

func TestRecordAttemptResetsCountOnNewPath(t *testing.T) {
	dir := t.TempDir()
	recordAttempt(dir, "/nix/store/aaa-coffer", "failed", "boom")
	recordAttempt(dir, "/nix/store/aaa-coffer", "failed", "boom")
	recordAttempt(dir, "/nix/store/bbb-coffer", "failed", "boom")

	got := loadAttemptFile(filepath.Join(dir, "last-attempt.json"))
	if got.Attempts != 1 {
		t.Errorf("Attempts = %d after new path, want 1", got.Attempts)
	}
	if got.StorePath != "/nix/store/bbb-coffer" {
		t.Errorf("StorePath = %q, want bbb", got.StorePath)
	}
}

func TestClearAttemptRemovesRecord(t *testing.T) {
	dir := t.TempDir()
	recordAttempt(dir, "/nix/store/aaa-coffer", "failed", "boom")
	clearAttempt(dir)

	if got := loadAttemptFile(filepath.Join(dir, "last-attempt.json")); got != nil {
		t.Errorf("attempt still present after clear: %+v", got)
	}
}

func TestLoadAttemptMissingAndCorrupt(t *testing.T) {
	dir := t.TempDir()
	if got := loadAttemptFile(filepath.Join(dir, "last-attempt.json")); got != nil {
		t.Errorf("missing file returned %+v, want nil", got)
	}

	corrupt := filepath.Join(dir, "last-attempt.json")
	os.WriteFile(corrupt, []byte("{not json"), 0644)
	if got := loadAttemptFile(corrupt); got != nil {
		t.Errorf("corrupt file returned %+v, want nil", got)
	}
}

func TestBackoffDoublesPerAttempt(t *testing.T) {
	now := time.Now().Unix()
	cases := []struct {
		attempts int
		want     time.Duration
	}{
		{1, 5 * time.Minute},
		{2, 10 * time.Minute},
		{3, 20 * time.Minute},
		{4, 40 * time.Minute},
	}
	for _, tc := range cases {
		rec := &AttemptRecord{At: now, Attempts: tc.attempts}
		got := backoffRemaining(rec, "5m")
		// Allow a second of slop for elapsed time during the test.
		if got > tc.want || got < tc.want-2*time.Second {
			t.Errorf("attempts=%d: remaining = %s, want ~%s", tc.attempts, got, tc.want)
		}
	}
}

func TestBackoffCapsAtCeiling(t *testing.T) {
	rec := &AttemptRecord{At: time.Now().Unix(), Attempts: 50}
	got := backoffRemaining(rec, "5m")
	if got > maxRetryBackoff {
		t.Errorf("remaining = %s, exceeds ceiling %s", got, maxRetryBackoff)
	}
	if got < maxRetryBackoff-2*time.Second {
		t.Errorf("remaining = %s, want ~%s", got, maxRetryBackoff)
	}
}

func TestBackoffExpiresSoRetryEventuallyHappens(t *testing.T) {
	// A transient failure must recover on its own without an operator.
	rec := &AttemptRecord{At: time.Now().Add(-time.Hour).Unix(), Attempts: 1}
	if got := backoffRemaining(rec, "5m"); got != 0 {
		t.Errorf("remaining = %s after backoff elapsed, want 0", got)
	}
}

func TestBackoffFallsBackOnUnparsablePollInterval(t *testing.T) {
	rec := &AttemptRecord{At: time.Now().Unix(), Attempts: 1}
	got := backoffRemaining(rec, "not-a-duration")
	if got > 5*time.Minute || got < 5*time.Minute-2*time.Second {
		t.Errorf("remaining = %s, want ~5m default", got)
	}
}

func TestFailActivationWritesTerminalStateNotIdle(t *testing.T) {
	dir := t.TempDir()
	failActivation(dir, "coffer", "/nix/store/aaa-coffer", "eval failed: %v", os.ErrNotExist)

	if state := readState(dir); state != "failed" {
		t.Errorf("state = %q, want failed (idle is the sink that hid these)", state)
	}
	rec := loadAttemptFile(filepath.Join(dir, "last-attempt.json"))
	if rec == nil || rec.StorePath != "/nix/store/aaa-coffer" {
		t.Fatalf("failed activation did not record the attempted path: %+v", rec)
	}
	if rec.Reason == "" {
		t.Error("no reason recorded")
	}
}

// A successful rollback used to write "permanent", making it indistinguishable
// from a successful activation. The status surface must be able to tell an
// operator that services are up but deliberately not running what the registry
// advertises.
func TestAttemptRecordSerialisesForStatusOutput(t *testing.T) {
	dir := t.TempDir()
	recordAttempt(dir, "/nix/store/aaa-coffer", "rolled-back", "health checks failed")

	data, err := os.ReadFile(filepath.Join(dir, "last-attempt.json"))
	if err != nil {
		t.Fatal(err)
	}
	var round AttemptRecord
	if err := json.Unmarshal(data, &round); err != nil {
		t.Fatalf("status output would not parse: %v", err)
	}
	if round.State != "rolled-back" {
		t.Errorf("State = %q, want rolled-back", round.State)
	}
	if round.At == 0 {
		t.Error("timestamp not recorded")
	}
}
