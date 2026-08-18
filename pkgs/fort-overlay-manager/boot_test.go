package main

import (
	"path/filepath"
	"testing"
)

// The reboot half of the lordhenry wedge: the manager's state dir is
// persistent, but an overlay's placement lives on tmpfs and is wiped by a
// reboot. An uncommitted overlay (no current version) that failed activation
// before the reboot would inherit its hours-long backoff and get skipped every
// boot forever, so it never came back even after the underlying fault was
// fixed. resetStaleBackoffOnBoot clears that stale record — but only when there
// is no committed version to protect.

func TestResetStaleBackoffClearsWhenUncommitted(t *testing.T) {
	base := t.TempDir()
	cfg := Config{StateDir: base}
	overlayDir := filepath.Join(base, "coffer")
	recordAttempt(overlayDir, "/nix/store/xpg-coffer", "rolled-back", "health checks failed")

	if !resetStaleBackoffOnBoot(cfg, "coffer", nil) {
		t.Fatal("expected stale backoff to be cleared for an uncommitted overlay")
	}
	if got := loadAttempt(base, "coffer"); got != nil {
		t.Fatalf("attempt still present after reset: %+v", got)
	}
}

func TestResetStaleBackoffKeepsBackoffWhenCommitted(t *testing.T) {
	base := t.TempDir()
	cfg := Config{StateDir: base}
	overlayDir := filepath.Join(base, "coffer")
	recordAttempt(overlayDir, "/nix/store/new-coffer", "rolled-back", "health checks failed")

	// A committed (running) version must keep the backoff so a failing newer
	// version cannot thrash it across reboots.
	current := &OverlayState{StorePath: "/nix/store/old-coffer", ActivatedAt: 1}
	if resetStaleBackoffOnBoot(cfg, "coffer", current) {
		t.Fatal("did not expect a committed overlay's backoff to be cleared")
	}
	if got := loadAttempt(base, "coffer"); got == nil {
		t.Fatal("attempt was cleared for a committed overlay; backoff should persist")
	}
}

func TestResetStaleBackoffNoOpWithoutAttempt(t *testing.T) {
	base := t.TempDir()
	cfg := Config{StateDir: base}
	if resetStaleBackoffOnBoot(cfg, "coffer", nil) {
		t.Fatal("expected no-op when there is no recorded attempt")
	}
}
