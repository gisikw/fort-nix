package main

import (
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"net/url"
	"strings"
	"syscall"
	"time"
)

type Web struct {
	Store  *Store
	Google *Google
	Syncer *Syncer
	Origin string // https://mail.gisi.network
	Root   string // maildir root, for the disk gauge
}

func (w *Web) Routes() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /accounts/{$}", w.index)
	m.HandleFunc("POST /accounts/connect", w.connect)
	m.HandleFunc("GET /accounts/callback", w.callback)
	m.HandleFunc("POST /accounts/act", w.act)
	m.HandleFunc("GET /accounts/identities.json", w.identities)
	m.HandleFunc("GET /accounts/healthz", func(rw http.ResponseWriter, _ *http.Request) { rw.Write([]byte("ok\n")) })
	m.HandleFunc("GET /accounts", func(rw http.ResponseWriter, r *http.Request) {
		http.Redirect(rw, r, "/accounts/", http.StatusFound)
	})
	return m
}

// sameOrigin is the CSRF gate for state-changing POSTs. The identity proxy
// already authenticated the user; this only stops other origins riding
// that cookie.
func (w *Web) sameOrigin(r *http.Request) bool {
	if sfs := r.Header.Get("Sec-Fetch-Site"); sfs != "" && sfs != "same-origin" {
		return false
	}
	if o := r.Header.Get("Origin"); o != "" && o != w.Origin {
		return false
	}
	return true
}

func (w *Web) connect(rw http.ResponseWriter, r *http.Request) {
	if !w.sameOrigin(r) {
		http.Error(rw, "cross-origin request refused", http.StatusForbidden)
		return
	}
	hint := strings.TrimSpace(r.FormValue("login_hint"))
	if hint != "" && !validEmail(hint) {
		hint = ""
	}
	http.Redirect(rw, r, w.Google.AuthURL(hint), http.StatusSeeOther)
}

func (w *Web) callback(rw http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if e := q.Get("error"); e != "" {
		w.flash(rw, r, "Google said: "+e)
		return
	}
	if !w.Google.consumeState(q.Get("state")) {
		w.flash(rw, r, "That sign-in link expired or was already used. Try again.")
		return
	}
	email, refresh, scope, err := w.Google.Exchange(q.Get("code"))
	if err != nil {
		log.Printf("oauth exchange: %v", err)
		w.flash(rw, r, "Couldn't connect: "+err.Error())
		return
	}
	if _, err := w.Store.Upsert(email, refresh, scope); err != nil {
		log.Printf("store %s: %v", email, err)
		w.flash(rw, r, "Connected but couldn't save: "+err.Error())
		return
	}
	log.Printf("connected %s by %s", email, r.Header.Get("X-Forwarded-User"))
	w.Syncer.Kick(email)
	w.flash(rw, r, "Connected "+email+". First sync is running.")
}

func (w *Web) act(rw http.ResponseWriter, r *http.Request) {
	if !w.sameOrigin(r) {
		http.Error(rw, "cross-origin request refused", http.StatusForbidden)
		return
	}
	email := r.FormValue("email")
	a, ok := w.Store.Get(email)
	if !ok {
		w.flash(rw, r, "No such account.")
		return
	}
	who := r.Header.Get("X-Forwarded-User")
	switch r.FormValue("action") {
	case "sync":
		w.Syncer.Kick(a.Email)
		w.flash(rw, r, "Syncing "+a.Email+".")
	case "archive-on", "archive-off":
		on := r.FormValue("action") == "archive-on"
		_ = w.Store.Update(a.Email, func(a *Account) { a.Archive = on })
		log.Printf("%s archive=%v by %s", a.Email, on, who)
		if on {
			w.Syncer.Kick(a.Email)
			w.flash(rw, r, "Archive sync on for "+a.Email+". The first pull of All Mail can take hours.")
		} else {
			w.flash(rw, r, "Archive sync off for "+a.Email+". What's already pulled stays.")
		}
	case "remove":
		removed, err := w.Store.Delete(a.Email)
		if err != nil {
			w.flash(rw, r, "Couldn't remove: "+err.Error())
			return
		}
		w.Google.Forget(removed.Email)
		go w.Google.Revoke(removed.RefreshToken)
		log.Printf("removed %s by %s", removed.Email, who)
		w.flash(rw, r, "Disconnected "+removed.Email+" and revoked access. Its mail already on Q stays put.")
	default:
		http.Error(rw, "unknown action", http.StatusBadRequest)
	}
}

func (w *Web) identities(rw http.ResponseWriter, _ *http.Request) {
	type ident struct {
		Email string `json:"email"`
	}
	out := []ident{}
	for _, a := range w.Store.List() {
		out = append(out, ident{a.Email})
	}
	rw.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(rw).Encode(out)
}

func (w *Web) flash(rw http.ResponseWriter, r *http.Request, msg string) {
	http.Redirect(rw, r, "/accounts/?msg="+url.QueryEscape(msg), http.StatusSeeOther)
}

func ago(t time.Time) string {
	if t.IsZero() {
		return "never"
	}
	d := time.Since(t).Round(time.Second)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return d.Round(time.Minute).String() + " ago"
	case d < 48*time.Hour:
		return d.Round(time.Hour).String() + " ago"
	}
	return t.Local().Format("Jan 2 15:04")
}

func diskFree(path string) string {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return "?"
	}
	free := float64(st.Bavail) * float64(st.Bsize) / 1e9
	total := float64(st.Blocks) * float64(st.Bsize) / 1e9
	return fmt.Sprintf("%.0f GB free of %.0f GB", free, total)
}

type row struct {
	Account
	SyncedAgo string
	OKAgo     string
}

func (w *Web) index(rw http.ResponseWriter, r *http.Request) {
	accts := w.Store.List()
	rows := make([]row, 0, len(accts))
	anySyncing := false
	for _, a := range accts {
		rows = append(rows, row{Account: a, SyncedAgo: ago(a.LastSync), OKAgo: ago(a.LastOK)})
		anySyncing = anySyncing || a.Syncing
	}
	rw.Header().Set("Content-Type", "text/html; charset=utf-8")
	rw.Header().Set("Cache-Control", "no-store")
	err := pageTmpl.Execute(rw, map[string]any{
		"Rows":     rows,
		"Msg":      r.URL.Query().Get("msg"),
		"Refresh":  anySyncing,
		"Disk":     diskFree(w.Root),
		"User":     r.Header.Get("X-Forwarded-User"),
		"Redirect": w.Google.RedirectURI,
	})
	if err != nil {
		log.Printf("render: %v", err)
	}
}

var pageTmpl = template.Must(template.New("page").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{{if .Refresh}}<meta http-equiv="refresh" content="8">{{end}}
<title>Mail accounts</title>
<link rel="stylesheet" href="https://cdn.gisi.network/theme/tokens.css">
<style>
 body{font-family:var(--f-body,system-ui);background:var(--c-bg,#faf8f5);color:var(--c-text,#222);max-width:760px;margin:2rem auto;padding:0 1rem;line-height:1.45}
 h1{font-family:var(--f-brand,inherit);color:var(--c-primary,#b4622d);margin:0 0 .25rem}
 .sub{color:var(--c-muted,#777);margin:0 0 1.5rem}
 .flash{background:var(--c-surface,#fff3e6);border-left:3px solid var(--c-primary,#b4622d);padding:.6rem .9rem;margin:0 0 1rem}
 .acct{border:1px solid var(--c-border,#ddd);border-radius:8px;padding:.9rem 1rem;margin:0 0 .8rem;background:var(--c-surface,#fff)}
 .acct h2{font-size:1.05rem;margin:0 0 .3rem;word-break:break-all}
 .meta{font-size:.9rem;color:var(--c-muted,#666)}
 .bad{color:#b00020}.ok{color:#2e7d32}
 .row{display:flex;gap:.5rem;flex-wrap:wrap;margin-top:.6rem}
 form{display:inline;margin:0}
 button,.btn{font:inherit;padding:.4rem .8rem;border-radius:6px;border:1px solid var(--c-border,#ccc);background:var(--c-bg,#fff);color:inherit;cursor:pointer}
 .primary{background:var(--c-primary,#b4622d);color:var(--c-primary-fg,#fff);border-color:transparent}
 .danger{color:#b00020}
 input[type=email]{font:inherit;padding:.4rem .6rem;border:1px solid var(--c-border,#ccc);border-radius:6px;min-width:16rem}
 details{margin-top:2rem;font-size:.92rem} pre{white-space:pre-wrap;font-size:.8rem;background:var(--c-surface,#f4f4f4);padding:.5rem;max-height:14rem;overflow:auto}
 a{color:var(--c-primary,#b4622d)}
</style></head><body>
<h1>Mail accounts</h1>
<p class="sub">What <a href="/">mail.gisi.network</a> pulls from. Every mailbox is copied to Q; sending goes out through each account's own server. Disk: {{.Disk}}.</p>
{{with .Msg}}<div class="flash">{{.}}</div>{{end}}

{{range .Rows}}
<div class="acct">
 <h2>{{.Email}}</h2>
 <div class="meta">
  {{if .NeedsReauth}}<span class="bad">Needs reconnecting.</span>
  {{else if .Syncing}}<span>Syncing now…</span>
  {{else if .LastError}}<span class="bad">Last sync failed {{.SyncedAgo}}.</span>
  {{else}}<span class="ok">OK</span>, synced {{.SyncedAgo}}.{{end}}
  Folders: INBOX, Sent{{if .Archive}}, Archive (All Mail){{end}}.
 </div>
 {{if .LastError}}<div class="meta bad">{{.LastError}}</div>{{end}}
 <div class="row">
  {{if .NeedsReauth}}
  <form method="post" action="/accounts/connect"><input type="hidden" name="login_hint" value="{{.Email}}"><button class="primary">Reconnect</button></form>
  {{else}}
  <form method="post" action="/accounts/act"><input type="hidden" name="email" value="{{.Email}}"><input type="hidden" name="action" value="sync"><button>Sync now</button></form>
  <form method="post" action="/accounts/connect"><input type="hidden" name="login_hint" value="{{.Email}}"><button>Reconnect</button></form>
  {{end}}
  <form method="post" action="/accounts/act"><input type="hidden" name="email" value="{{.Email}}">
   {{if .Archive}}<input type="hidden" name="action" value="archive-off"><button>Stop archive sync</button>
   {{else}}<input type="hidden" name="action" value="archive-on"><button title="Pull [Gmail]/All Mail. Can be many GB.">Also keep full archive</button>{{end}}
  </form>
  <form method="post" action="/accounts/act" onsubmit="return confirm('Disconnect {{.Email}} and revoke access? Mail already on Q stays.')"><input type="hidden" name="email" value="{{.Email}}"><input type="hidden" name="action" value="remove"><button class="danger">Disconnect</button></form>
 </div>
 {{if .LastOutput}}<details><summary class="meta">Last sync output</summary><pre>{{.LastOutput}}</pre></details>{{end}}
</div>
{{else}}
<p>No accounts yet.</p>
{{end}}

<form method="post" action="/accounts/connect" class="row">
 <input type="email" name="login_hint" placeholder="address (optional)">
 <button class="primary">Connect a Google account</button>
</form>

<details>
<summary>If Google refuses</summary>
<ul>
 <li><b>"Access blocked" / redirect_uri_mismatch:</b> the OAuth client needs <code>{{.Redirect}}</code> as an authorized redirect URI.</li>
 <li><b>Works, then breaks after a week:</b> the consent screen is still in <i>Testing</i>. Publish it to <i>In production</i> (you'll click through an "unverified app" warning; that's fine for us).</li>
 <li><b>Workspace account blocked:</b> Admin console → Security → API controls → allow this OAuth client (or "trust" it).</li>
 <li><b>IMAP login refused with a fresh token:</b> IMAP is off for that account (Workspace: Admin → Apps → Gmail → End user access).</li>
</ul>
</details>
</body></html>
`))
