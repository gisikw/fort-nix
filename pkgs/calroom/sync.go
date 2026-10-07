package main

import (
	"bytes"
	"context"
	"log"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// Syncer runs the same cal-sync script the systemd timer runs (it takes a
// flock, so overlapping with the timer just queues). Output is kept for the
// page so a failed discovery is visible without a shell.
type Syncer struct {
	Cmd       string
	LastSync  string // marker file touched by cal-sync on success
	mu        sync.Mutex
	running   bool
	lastOut   string
	lastErr   string
	lastStart time.Time
}

func (s *Syncer) Kick() bool {
	s.mu.Lock()
	if s.running || s.Cmd == "" {
		s.mu.Unlock()
		return false
	}
	s.running, s.lastStart = true, time.Now()
	s.mu.Unlock()
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
		defer cancel()
		cmd := exec.CommandContext(ctx, s.Cmd)
		var buf bytes.Buffer
		cmd.Stdout, cmd.Stderr = &buf, &buf
		err := cmd.Run()
		out := buf.String()
		if len(out) > 16000 {
			out = "…" + out[len(out)-16000:]
		}
		s.mu.Lock()
		s.running, s.lastOut, s.lastErr = false, strings.TrimSpace(out), ""
		if err != nil {
			s.lastErr = err.Error()
			log.Printf("cal-sync: %v", err)
		}
		s.mu.Unlock()
	}()
	return true
}

type SyncState struct {
	Running bool
	Output  string
	Error   string
	LastOK  time.Time
}

func (s *Syncer) State() SyncState {
	s.mu.Lock()
	defer s.mu.Unlock()
	st := SyncState{Running: s.running, Output: s.lastOut, Error: s.lastErr}
	if s.LastSync != "" {
		if fi, err := os.Stat(s.LastSync); err == nil {
			st.LastOK = fi.ModTime()
		}
	}
	return st
}
