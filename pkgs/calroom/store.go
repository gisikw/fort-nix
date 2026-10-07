package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

var emailRe = regexp.MustCompile(`^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$`)

func validEmail(s string) bool { return len(s) <= 254 && emailRe.MatchString(s) }

// Slug is the vdirsyncer pair/storage name fragment for an account. It must
// match what cal-sync derives from the token filename (tr -c 'a-z0-9' '_').
func Slug(email string) string {
	var b strings.Builder
	for _, r := range email {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	return b.String()
}

// Store is the token directory vdirsyncer reads. One file per account,
// named <email>.json, in the requests-oauthlib shape vdirsyncer's
// google_calendar storage expects (it refreshes and rewrites it itself).
// The pre-existing single-account token (the ASG work calendar) stays at
// its old path so the running sync never notices the migration.
type Store struct {
	Dir         string // e.g. /var/lib/vdirsyncer/tokens
	LegacyFile  string // e.g. /var/lib/vdirsyncer/token
	LegacyEmail string // the account LegacyFile belongs to
	DataDir     string // vdirsyncer local copies, google/<email>/...
	StatusDir   string // vdirsyncer status_path; pair state is dropped on disconnect
}

type Account struct {
	Email     string
	Legacy    bool
	Path      string
	Modified  time.Time
	Calendars int
}

func (s *Store) path(email string) string {
	if s.LegacyEmail != "" && email == s.LegacyEmail {
		return s.LegacyFile
	}
	return filepath.Join(s.Dir, email+".json")
}

func (s *Store) List() []Account {
	var out []Account
	if s.LegacyEmail != "" {
		if st, err := os.Stat(s.LegacyFile); err == nil {
			out = append(out, Account{Email: s.LegacyEmail, Legacy: true, Path: s.LegacyFile, Modified: st.ModTime()})
		}
	}
	entries, _ := os.ReadDir(s.Dir)
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".json") {
			continue
		}
		email := strings.TrimSuffix(name, ".json")
		if !validEmail(email) || email == s.LegacyEmail {
			continue
		}
		st, err := e.Info()
		if err != nil {
			continue
		}
		a := Account{Email: email, Path: filepath.Join(s.Dir, name), Modified: st.ModTime()}
		if s.DataDir != "" {
			cals, _ := os.ReadDir(filepath.Join(s.DataDir, email))
			for _, c := range cals {
				if c.IsDir() {
					a.Calendars++
				}
			}
		}
		out = append(out, a)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Legacy != out[j].Legacy {
			return out[i].Legacy
		}
		return out[i].Email < out[j].Email
	})
	return out
}

func (s *Store) Has(email string) bool {
	_, err := os.Stat(s.path(email))
	return err == nil
}

// Write stores a fresh grant atomically, mode 0600.
func (s *Store) Write(email string, tr *tokenResp, now time.Time) error {
	if !validEmail(email) {
		return errors.New("invalid email")
	}
	tok := map[string]any{
		"access_token":  tr.AccessToken,
		"refresh_token": tr.RefreshToken,
		"expires_in":    tr.ExpiresIn,
		"expires_at":    float64(now.Unix()) + float64(tr.ExpiresIn),
		"scope":         strings.Fields(tr.Scope),
		"token_type":    firstNonEmpty(tr.TokenType, "Bearer"),
	}
	b, err := json.MarshalIndent(tok, "", "  ")
	if err != nil {
		return err
	}
	p := s.path(email)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(p), ".tok-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return err
	}
	if _, err := f.Write(append(b, '\n')); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), p)
}

// RefreshToken reads back the stored refresh token (for revocation).
func (s *Store) RefreshToken(email string) string {
	b, err := os.ReadFile(s.path(email))
	if err != nil {
		return ""
	}
	var t struct {
		RefreshToken string `json:"refresh_token"`
	}
	_ = json.Unmarshal(b, &t)
	return t.RefreshToken
}

// Delete removes a non-legacy account's token and its local calendar copy.
// The legacy work token is only ever replaced, never deleted from here.
func (s *Store) Delete(email string) error {
	if email == s.LegacyEmail {
		return errors.New("the work calendar token is managed in fort-nix; reconnect it instead")
	}
	if !validEmail(email) {
		return errors.New("invalid email")
	}
	if err := os.Remove(s.path(email)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if s.DataDir != "" {
		_ = os.RemoveAll(filepath.Join(s.DataDir, email))
	}
	if s.StatusDir != "" {
		pair := "g_" + Slug(email)
		_ = os.RemoveAll(filepath.Join(s.StatusDir, pair))
		_ = os.Remove(filepath.Join(s.StatusDir, pair+".collections"))
	}
	return nil
}

func firstNonEmpty(xs ...string) string {
	for _, x := range xs {
		if x != "" {
			return x
		}
	}
	return ""
}
