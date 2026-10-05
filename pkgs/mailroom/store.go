package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Account is one connected upstream mailbox. Persisted as
// <state>/accounts/<email>.json, mode 0600. The refresh token never leaves
// this file except on its way to Google's token endpoint.
type Account struct {
	Email        string    `json:"email"`
	Provider     string    `json:"provider"` // "google"
	RefreshToken string    `json:"refresh_token"`
	Scope        string    `json:"scope"`
	Archive      bool      `json:"archive"` // also pull [Gmail]/All Mail
	Created      time.Time `json:"created"`
	Updated      time.Time `json:"updated"`

	// Runtime status, persisted so the page survives restarts.
	NeedsReauth bool      `json:"needs_reauth,omitempty"`
	LastSync    time.Time `json:"last_sync,omitempty"`
	LastOK      time.Time `json:"last_ok,omitempty"`
	LastError   string    `json:"last_error,omitempty"`
	LastOutput  string    `json:"last_output,omitempty"`
	Syncing     bool      `json:"-"`
}

var emailRe = regexp.MustCompile(`^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$`)

func validEmail(s string) bool { return emailRe.MatchString(s) && !strings.Contains(s, "..") }

// slug is a filesystem/mbsync-safe identifier for an account.
func slug(email string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(email) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
		default:
			b.WriteRune('-')
		}
	}
	return b.String()
}

type Store struct {
	dir string
	mu  sync.Mutex
	acc map[string]*Account
}

func OpenStore(dir string) (*Store, error) {
	s := &Store{dir: dir, acc: map[string]*Account{}}
	if err := os.MkdirAll(filepath.Join(dir, "accounts"), 0o700); err != nil {
		return nil, err
	}
	ents, err := os.ReadDir(filepath.Join(dir, "accounts"))
	if err != nil {
		return nil, err
	}
	for _, e := range ents {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, "accounts", e.Name()))
		if err != nil {
			return nil, err
		}
		var a Account
		if err := json.Unmarshal(b, &a); err != nil {
			return nil, fmt.Errorf("%s: %w", e.Name(), err)
		}
		if !validEmail(a.Email) {
			continue
		}
		s.acc[strings.ToLower(a.Email)] = &a
	}
	return s, nil
}

func (s *Store) path(email string) string {
	return filepath.Join(s.dir, "accounts", strings.ToLower(email)+".json")
}

// saveLocked writes atomically. Caller holds s.mu.
func (s *Store) saveLocked(a *Account) error {
	b, err := json.MarshalIndent(a, "", "  ")
	if err != nil {
		return err
	}
	p := s.path(a.Email)
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

// Upsert stores a freshly authorized account, preserving settings if it
// already existed (reauth).
func (s *Store) Upsert(email, refresh, scope string) (*Account, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := strings.ToLower(email)
	now := time.Now().UTC()
	a, ok := s.acc[key]
	if !ok {
		a = &Account{Email: key, Provider: "google", Created: now}
		s.acc[key] = a
	}
	a.RefreshToken = refresh
	a.Scope = scope
	a.Updated = now
	a.NeedsReauth = false
	a.LastError = ""
	return a, s.saveLocked(a)
}

func (s *Store) Get(email string) (Account, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	a, ok := s.acc[strings.ToLower(email)]
	if !ok {
		return Account{}, false
	}
	return *a, true
}

func (s *Store) List() []Account {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Account, 0, len(s.acc))
	for _, a := range s.acc {
		out = append(out, *a)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Email < out[j].Email })
	return out
}

// Update applies fn to the live record and persists it.
func (s *Store) Update(email string, fn func(a *Account)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	a, ok := s.acc[strings.ToLower(email)]
	if !ok {
		return errors.New("no such account")
	}
	fn(a)
	return s.saveLocked(a)
}

func (s *Store) Delete(email string) (Account, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := strings.ToLower(email)
	a, ok := s.acc[key]
	if !ok {
		return Account{}, errors.New("no such account")
	}
	delete(s.acc, key)
	return *a, os.Remove(s.path(key))
}
