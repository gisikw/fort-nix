package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

var (
	db         *sql.DB
	hmacSecret []byte
	tmpl       *template.Template
)

type Token struct {
	ID        int64
	Label     string
	CreatedBy string
	CreatedAt time.Time
	ExpiresAt time.Time
	Expired   bool
}

type TokenPayload struct {
	Sub   string `json:"sub"`
	Exp   int64  `json:"exp"`
	JTI   string `json:"jti"`
	Label string `json:"label"`
}

func main() {
	secretPath := os.Getenv("TOKEN_SECRET_FILE")
	if secretPath == "" {
		secretPath = "/var/lib/fort-auth/token-secret"
	}
	secret, err := os.ReadFile(secretPath)
	if err != nil {
		log.Fatalf("failed to read HMAC secret from %s: %v", secretPath, err)
	}
	hmacSecret = []byte(strings.TrimSpace(string(secret)))

	dbPath := os.Getenv("TOKEN_DB_PATH")
	if dbPath == "" {
		dbPath = "/var/lib/fort-tokens/tokens.db"
	}
	db, err = sql.Open("sqlite3", dbPath+"?_journal_mode=WAL")
	if err != nil {
		log.Fatalf("failed to open database: %v", err)
	}
	defer db.Close()

	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS tokens (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		label TEXT NOT NULL,
		jti TEXT NOT NULL UNIQUE,
		created_by TEXT NOT NULL,
		created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
		expires_at DATETIME NOT NULL
	)`)
	if err != nil {
		log.Fatalf("failed to create table: %v", err)
	}

	tmpl = template.Must(template.New("index").Parse(indexHTML))

	http.HandleFunc("/", handleIndex)
	http.HandleFunc("/tokens", handleTokens)
	http.HandleFunc("/tokens/", handleTokenDelete)

	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = "127.0.0.1:9471"
	}
	log.Printf("listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}

func getUser(r *http.Request) string {
	user := r.Header.Get("X-Forwarded-User")
	if user == "" {
		user = r.Header.Get("X-Auth-Request-User")
	}
	if user == "" {
		user = "unknown"
	}
	return user
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	rows, err := db.Query("SELECT id, label, created_by, created_at, expires_at FROM tokens ORDER BY created_at DESC")
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()

	var tokens []Token
	now := time.Now()
	for rows.Next() {
		var t Token
		if err := rows.Scan(&t.ID, &t.Label, &t.CreatedBy, &t.CreatedAt, &t.ExpiresAt); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		t.Expired = t.ExpiresAt.Before(now)
		tokens = append(tokens, t)
	}

	tmpl.Execute(w, map[string]any{
		"Tokens": tokens,
		"User":   getUser(r),
	})
}

func handleTokens(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", 405)
		return
	}

	label := strings.TrimSpace(r.FormValue("label"))
	if label == "" {
		http.Error(w, "label required", 400)
		return
	}

	daysStr := r.FormValue("days")
	days, err := strconv.Atoi(daysStr)
	if err != nil || days < 1 || days > 365 {
		days = 90
	}

	user := getUser(r)
	jti := fmt.Sprintf("%x", time.Now().UnixNano())
	expiresAt := time.Now().Add(time.Duration(days) * 24 * time.Hour)

	payload := TokenPayload{
		Sub:   user,
		Exp:   expiresAt.Unix(),
		JTI:   jti,
		Label: label,
	}

	payloadJSON, _ := json.Marshal(payload)
	payloadB64 := base64.RawURLEncoding.EncodeToString(payloadJSON)

	mac := hmac.New(sha256.New, hmacSecret)
	mac.Write([]byte(payloadB64))
	sig := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))

	token := payloadB64 + "." + sig

	_, err = db.Exec("INSERT INTO tokens (label, jti, created_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?)",
		label, jti, user, time.Now(), expiresAt)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}

	w.Header().Set("Content-Type", "text/html")
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><title>Token Created</title>
<style>body{font-family:monospace;max-width:800px;margin:2em auto;padding:0 1em}
.token{background:#1a1a2e;color:#0f0;padding:1em;border-radius:4px;word-break:break-all;margin:1em 0}
a{color:#4a9eff}</style></head>
<body><h2>Token Created</h2>
<p>Label: <strong>%s</strong></p>
<p>Expires: %s</p>
<div class="token">%s</div>
<p>Copy this token now — it won't be shown again.</p>
<p><a href="/">Back to tokens</a></p>
</body></html>`, template.HTMLEscapeString(label), expiresAt.Format("2006-01-02"), template.HTMLEscapeString(token))
}

func handleTokenDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", 405)
		return
	}

	idStr := strings.TrimPrefix(r.URL.Path, "/tokens/")
	idStr = strings.TrimSuffix(idStr, "/delete")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, "invalid id", 400)
		return
	}

	_, err = db.Exec("DELETE FROM tokens WHERE id = ?", id)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}

	http.Redirect(w, r, "/", http.StatusSeeOther)
}

const indexHTML = `<!DOCTYPE html>
<html><head><title>Fort Tokens</title>
<style>
body { font-family: monospace; max-width: 800px; margin: 2em auto; padding: 0 1em; background: #0d1117; color: #c9d1d9; }
h1 { color: #58a6ff; }
table { width: 100%; border-collapse: collapse; margin: 1em 0; }
th, td { padding: 0.5em; text-align: left; border-bottom: 1px solid #21262d; }
th { color: #8b949e; }
.expired { color: #f85149; }
.active { color: #3fb950; }
form { margin: 1em 0; }
input, select, button { font-family: monospace; padding: 0.4em; background: #161b22; color: #c9d1d9; border: 1px solid #30363d; border-radius: 4px; }
button { cursor: pointer; background: #238636; border-color: #238636; color: #fff; }
button.delete { background: #da3633; border-color: #da3633; }
.user { color: #8b949e; font-size: 0.9em; }
</style></head>
<body>
<h1>Fort Tokens</h1>
<p class="user">Signed in as: {{ .User }}</p>

<h2>Create Token</h2>
<form method="POST" action="/tokens">
  <input type="text" name="label" placeholder="Label (e.g. work-laptop)" required>
  <select name="days">
    <option value="30">30 days</option>
    <option value="90" selected>90 days</option>
    <option value="180">180 days</option>
    <option value="365">365 days</option>
  </select>
  <button type="submit">Create Token</button>
</form>

<h2>Active Tokens</h2>
{{ if .Tokens }}
<table>
  <tr><th>Label</th><th>Created By</th><th>Created</th><th>Expires</th><th></th></tr>
  {{ range .Tokens }}
  <tr>
    <td>{{ .Label }}</td>
    <td>{{ .CreatedBy }}</td>
    <td>{{ .CreatedAt.Format "2006-01-02" }}</td>
    <td class="{{ if .Expired }}expired{{ else }}active{{ end }}">{{ .ExpiresAt.Format "2006-01-02" }}{{ if .Expired }} (expired){{ end }}</td>
    <td><form method="POST" action="/tokens/{{ .ID }}/delete" style="margin:0"><button class="delete" type="submit" onclick="return confirm('Delete this token?')">Delete</button></form></td>
  </tr>
  {{ end }}
</table>
{{ else }}
<p>No tokens yet.</p>
{{ end }}
</body></html>`
