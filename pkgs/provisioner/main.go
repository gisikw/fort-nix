package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Target struct {
	Host    string `json:"host"`
	Profile string `json:"profile"`
}
type Lease struct {
	Host        string     `json:"host"`
	Profile     string     `json:"profile"`
	ArmedBy     string     `json:"armed_by"`
	ArmedAt     time.Time  `json:"armed_at"`
	ExpiresAt   time.Time  `json:"expires_at"`
	ClaimedAt   *time.Time `json:"claimed_at,omitempty"`
	ClaimToken  string     `json:"claim_token,omitempty"`
	CompletedAt *time.Time `json:"completed_at,omitempty"`
}
type State struct {
	Lease *Lease `json:"lease,omitempty"`
}
type Server struct {
	mu                                                     sync.Mutex
	targets                                                []Target
	state                                                  State
	statePath, archivePath, completionsDir, prepareCommand string
	secret                                                 []byte
	now                                                    func() time.Time
	requireUser                                            bool
	tmpl                                                   *template.Template
}

func main() {
	s, err := newServerFromEnv()
	if err != nil {
		log.Fatal(err)
	}
	addr := getenv("LISTEN_ADDR", "127.0.0.1:9480")
	log.Printf("provisioner listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, s.routes()))
}

func newServerFromEnv() (*Server, error) {
	registry := os.Getenv("REGISTRY_PATH")
	secretPath := os.Getenv("BOOTSTRAP_SECRET_FILE")
	if registry == "" || secretPath == "" {
		return nil, errors.New("REGISTRY_PATH and BOOTSTRAP_SECRET_FILE are required")
	}
	targetBytes, err := os.ReadFile(registry)
	if err != nil {
		return nil, err
	}
	var targets []Target
	if err = json.Unmarshal(targetBytes, &targets); err != nil {
		return nil, err
	}
	secret, err := os.ReadFile(secretPath)
	if err != nil {
		return nil, err
	}
	return newServer(targets, strings.TrimSpace(string(secret)), getenv("STATE_PATH", "/var/lib/fort-provisioner/state.json"), os.Getenv("SOURCE_ARCHIVE_PATH"), getenv("COMPLETIONS_DIR", "/var/lib/fort-provisioner/completions")), nil
}
func newServer(targets []Target, secret, statePath, archivePath, completions string) *Server {
	s := &Server{targets: targets, secret: []byte(secret), statePath: statePath, archivePath: archivePath, completionsDir: completions, prepareCommand: os.Getenv("PREPARE_COMMAND"), now: time.Now, requireUser: getenv("REQUIRE_PROXY_USER", "true") != "false"}
	if b, err := os.ReadFile(statePath); err == nil {
		_ = json.Unmarshal(b, &s.state)
	}
	s.tmpl = template.Must(template.New("dashboard").Parse(dashboardHTML))
	return s
}
func (s *Server) routes() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok\n")) })
	m.HandleFunc("GET /", s.dashboard)
	m.HandleFunc("POST /api/leases/{host}", s.arm)
	m.HandleFunc("DELETE /api/leases/{host}", s.disarm)
	m.HandleFunc("POST /api/leases/{host}/disarm", s.disarm)
	m.HandleFunc("POST /activate", s.activate)
	m.HandleFunc("GET /bootstrap/{token}", s.bootstrap)
	m.HandleFunc("POST /complete/{token}", s.complete)
	return securityHeaders(m)
}

func (s *Server) dashboard(w http.ResponseWriter, r *http.Request) {
	if !s.human(w, r, false) {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	data := struct {
		Targets []Target
		Lease   *Lease
		Now     time.Time
	}{s.targets, s.state.Lease, s.now()}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = s.tmpl.Execute(w, data)
}
func (s *Server) arm(w http.ResponseWriter, r *http.Request) {
	if !s.human(w, r, true) {
		return
	}
	host := r.PathValue("host")
	var target *Target
	for i := range s.targets {
		if s.targets[i].Host == host {
			target = &s.targets[i]
			break
		}
	}
	if target == nil {
		http.Error(w, "unknown host", 404)
		return
	}
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.Lease = &Lease{Host: target.Host, Profile: target.Profile, ArmedBy: user(r), ArmedAt: now, ExpiresAt: now.Add(5 * time.Minute)}
	if err := s.save(); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	http.Redirect(w, r, "/", 303)
}
func (s *Server) disarm(w http.ResponseWriter, r *http.Request) {
	if !s.human(w, r, true) {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state.Lease != nil && s.state.Lease.Host == r.PathValue("host") {
		s.state.Lease = nil
		_ = s.save()
	}
	http.Redirect(w, r, "/", 303)
}
func (s *Server) activate(w http.ResponseWriter, r *http.Request) {
	if !s.machine(w, r, "") {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	l := s.state.Lease
	if l == nil || !s.now().Before(l.ExpiresAt) {
		http.Error(w, "no provisioning lease is armed", 409)
		return
	}
	if l.ClaimedAt != nil {
		http.Error(w, "lease already claimed", 409)
		return
	}
	now := s.now()
	token, err := randomToken()
	if err != nil {
		http.Error(w, "entropy unavailable", 500)
		return
	}
	l.ClaimedAt = &now
	l.ClaimToken = token
	if err = s.save(); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]any{"host": l.Host, "profile": l.Profile, "claim_token": token, "source_archive_url": "/bootstrap/" + token, "expires_at": l.ExpiresAt})
}
func (s *Server) bootstrap(w http.ResponseWriter, r *http.Request) {
	token := r.PathValue("token")
	if !s.machine(w, r, token) {
		return
	}
	s.mu.Lock()
	valid := s.state.Lease != nil && s.state.Lease.ClaimToken == token && s.state.Lease.ClaimedAt != nil && s.now().Before(s.state.Lease.ExpiresAt)
	s.mu.Unlock()
	if !valid {
		http.Error(w, "invalid or expired claim", 403)
		return
	}
	prepared := ""
	if s.state.Lease != nil {
		prepared = filepath.Join(s.completionsDir, s.state.Lease.Host+".tar.gz")
	}
	if _, err := os.Stat(prepared); err == nil {
		http.ServeFile(w, r, prepared)
		return
	}
	if s.archivePath == "" {
		http.Error(w, "archive unavailable", 503)
		return
	}
	w.Header().Set("Content-Type", "application/gzip")
	http.ServeFile(w, r, s.archivePath)
}

type completion struct {
	UUID        string    `json:"uuid"`
	Pubkey      string    `json:"pubkey"`
	Hardware    string    `json:"hardware_configuration"`
	Host        string    `json:"host"`
	Profile     string    `json:"profile"`
	CompletedAt time.Time `json:"completed_at"`
}

func (s *Server) complete(w http.ResponseWriter, r *http.Request) {
	token := r.PathValue("token")
	if !s.machine(w, r, token) {
		return
	}
	var c completion
	if err := json.NewDecoder(io.LimitReader(r.Body, 2<<20)).Decode(&c); err != nil {
		http.Error(w, "invalid completion", 400)
		return
	}
	if c.UUID == "" || c.Pubkey == "" || c.Hardware == "" {
		http.Error(w, "uuid, pubkey and hardware_configuration required", 400)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	l := s.state.Lease
	if l == nil || l.ClaimToken != token || l.ClaimedAt == nil || l.CompletedAt != nil || !s.now().Before(l.ExpiresAt) {
		http.Error(w, "invalid or expired claim", 403)
		return
	}
	c.Host = l.Host
	c.Profile = l.Profile
	c.CompletedAt = s.now()
	b, _ := json.MarshalIndent(c, "", "  ")
	if err := os.MkdirAll(s.completionsDir, 0700); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	completionPath := filepath.Join(s.completionsDir, c.Host+".json")
	if err := atomicWrite(completionPath, b, 0600); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if s.prepareCommand != "" {
		cmd := exec.Command(s.prepareCommand, completionPath)
		if out, err := cmd.CombinedOutput(); err != nil {
			http.Error(w, fmt.Sprintf("prepare failed: %v: %s", err, out), 500)
			return
		}
	}
	completed := s.now()
	l.CompletedAt = &completed
	_ = s.save()
	writeJSON(w, map[string]string{"status": "recorded"})
}

func (s *Server) human(w http.ResponseWriter, r *http.Request, mutate bool) bool {
	if s.requireUser && user(r) == "" {
		http.Error(w, "authenticated proxy identity required", 401)
		return false
	}
	if mutate {
		origin := r.Header.Get("Origin")
		if origin != "" && !strings.EqualFold(strings.TrimSuffix(origin, "/"), "https://"+r.Host) {
			http.Error(w, "origin rejected", 403)
			return false
		}
	}
	return true
}
func (s *Server) machine(w http.ResponseWriter, r *http.Request, claim string) bool {
	supplied := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	expected := string(s.secret)
	if claim != "" {
		expected = claim
	}
	if len(supplied) != len(expected) || subtle.ConstantTimeCompare([]byte(supplied), []byte(expected)) != 1 {
		http.Error(w, "unauthorized", 401)
		return false
	}
	return true
}
func (s *Server) save() error {
	b, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(s.statePath, b, 0600)
}
func atomicWrite(path string, b []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".tmp-")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if err = f.Chmod(mode); err == nil {
		_, err = f.Write(b)
	}
	if err == nil {
		err = f.Sync()
	}
	cerr := f.Close()
	if err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	return os.Rename(name, path)
}
func randomToken() (string, error) {
	b := make([]byte, 32)
	_, err := rand.Read(b)
	return hex.EncodeToString(b), err
}
func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
func user(r *http.Request) string { return r.Header.Get("X-Forwarded-User") }
func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'none'; form-action 'self'; frame-ancestors 'none'")
		next.ServeHTTP(w, r)
	})
}

const dashboardHTML = `<!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>Fort Foundry</title><style>
:root{--ink:#161916;--paper:#e9e2d2;--rust:#a84227;--acid:#c5d86d;--line:#5d6258}*{box-sizing:border-box}body{margin:0;background:var(--ink);color:var(--paper);font-family:"IBM Plex Mono","Courier New",monospace;background-image:repeating-linear-gradient(135deg,#1b1e1b 0,#1b1e1b 2px,#161916 2px,#161916 13px)}main{max-width:1050px;margin:auto;padding:5vw 24px}.eyebrow{color:var(--acid);letter-spacing:.22em;font-size:.72rem}h1{font-family:Georgia,serif;font-weight:400;font-style:italic;font-size:clamp(3rem,9vw,7rem);line-height:.8;margin:.25em 0}.rule{height:6px;background:var(--rust);margin:2rem 0}.lease{border:1px solid var(--line);padding:18px;margin-bottom:24px;background:#20241f}.lease strong{color:var(--acid)}table{width:100%;border-collapse:collapse;background:#e9e2d2;color:#161916;box-shadow:12px 12px 0 var(--rust)}th,td{text-align:left;padding:16px;border-bottom:1px solid #aaa391}th{font-size:.7rem;letter-spacing:.15em;background:#d5cbb7}.host{font-family:Georgia,serif;font-size:1.4rem}.tag{font-size:.7rem;border:1px solid;padding:4px 7px}button{border:0;background:var(--ink);color:var(--paper);font:700 .75rem inherit;padding:11px 14px;cursor:pointer;text-transform:uppercase;letter-spacing:.08em}button:hover{background:var(--rust)}button.kill{background:var(--rust)}footer{margin-top:40px;color:#92978c;font-size:.72rem}@media(max-width:600px){th:nth-child(2),td:nth-child(2){display:none}td,th{padding:12px}}</style></head><body><main><div class=eyebrow>BEDLAM / PROVISIONING AUTHORITY</div><h1>Fort<br>Foundry</h1><div class=rule></div>{{if .Lease}}<div class=lease><strong>{{.Lease.Host}}</strong> armed by {{.Lease.ArmedBy}} until {{.Lease.ExpiresAt.Format "15:04:05 MST"}}. {{if .Lease.ClaimedAt}}CLAIMED at {{.Lease.ClaimedAt.Format "15:04:05"}}{{else}}Awaiting one boot device.{{end}} <form style="display:inline" method=post action="/api/leases/{{.Lease.Host}}?_method=DELETE"><button class=kill formmethod=post onclick="this.form.method='post';this.form.action='/api/leases/{{.Lease.Host}}/disarm'">Disarm</button></form></div>{{else}}<div class=lease>No active lease. The foundry is cold.</div>{{end}}<table><thead><tr><th>Assigned host</th><th>Device profile</th><th>Five-minute ignition</th></tr></thead><tbody>{{range .Targets}}<tr><td class=host>{{.Host}}</td><td><span class=tag>{{.Profile}}</span></td><td><form method=post action="/api/leases/{{.Host}}"><button>Arm {{.Host}}</button></form></td></tr>{{end}}</tbody></table><footer>One global lease. One claimant. Possession of the fleet USB credential is necessary but not sufficient.</footer></main></body></html>`

var _ = fmt.Sprintf
