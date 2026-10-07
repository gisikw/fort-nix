package main

import (
	"html/template"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

type Web struct {
	Store  *Store
	Google *Google
	Syncer *Syncer
	Origin string // https://vdirsyncer-auth.gisi.network
	Agenda string // agenda.json written by cal-sync
	Local  []string
}

func (w *Web) Routes() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /{$}", w.index)
	m.HandleFunc("POST /connect", w.connect)
	// Same path the old Python helper used, so the redirect URI already
	// registered on the OAuth client keeps working.
	m.HandleFunc("GET /callback", w.callback)
	m.HandleFunc("POST /act", w.act)
	m.HandleFunc("GET /healthz", func(rw http.ResponseWriter, _ *http.Request) { rw.Write([]byte("ok\n")) })
	return m
}

// sameOrigin is the CSRF gate for state-changing POSTs; the identity proxy
// already authenticated the user.
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
	hint := strings.ToLower(strings.TrimSpace(r.FormValue("login_hint")))
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
	email, tr, err := w.Google.Exchange(q.Get("code"))
	if err != nil {
		log.Printf("oauth exchange: %v", err)
		w.flash(rw, r, "Couldn't connect: "+err.Error())
		return
	}
	if err := w.Store.Write(email, tr, time.Now()); err != nil {
		log.Printf("store %s: %v", email, err)
		w.flash(rw, r, "Connected but couldn't save: "+err.Error())
		return
	}
	log.Printf("connected %s by %s", email, r.Header.Get("X-Forwarded-User"))
	w.Syncer.Kick()
	w.flash(rw, r, "Connected "+email+". First sync is running; calendars appear in a minute or two.")
}

func (w *Web) act(rw http.ResponseWriter, r *http.Request) {
	if !w.sameOrigin(r) {
		http.Error(rw, "cross-origin request refused", http.StatusForbidden)
		return
	}
	who := r.Header.Get("X-Forwarded-User")
	switch r.FormValue("action") {
	case "sync":
		if w.Syncer.Kick() {
			w.flash(rw, r, "Syncing.")
		} else {
			w.flash(rw, r, "A sync is already running.")
		}
	case "remove":
		email := strings.ToLower(r.FormValue("email"))
		if !w.Store.Has(email) {
			w.flash(rw, r, "No such account.")
			return
		}
		refresh := w.Store.RefreshToken(email)
		if err := w.Store.Delete(email); err != nil {
			w.flash(rw, r, "Couldn't remove: "+err.Error())
			return
		}
		if refresh != "" {
			go w.Google.Revoke(refresh)
		}
		log.Printf("removed %s by %s", email, who)
		w.flash(rw, r, "Disconnected "+email+", revoked access, and dropped its local copy.")
	default:
		http.Error(rw, "unknown action", http.StatusBadRequest)
	}
}

func (w *Web) flash(rw http.ResponseWriter, r *http.Request, msg string) {
	http.Redirect(rw, r, "/?msg="+url.QueryEscape(msg), http.StatusSeeOther)
}

func ago(t time.Time) string {
	if t.IsZero() {
		return "never"
	}
	d := time.Since(t)
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

type row struct {
	Account
	Since string
}

func (w *Web) index(rw http.ResponseWriter, r *http.Request) {
	var rows []row
	for _, a := range w.Store.List() {
		rows = append(rows, row{Account: a, Since: ago(a.Modified)})
	}
	st := w.Syncer.State()
	agendaAge := "never"
	if fi, err := os.Stat(w.Agenda); err == nil {
		agendaAge = ago(fi.ModTime())
	}
	rw.Header().Set("Content-Type", "text/html; charset=utf-8")
	rw.Header().Set("Cache-Control", "no-store")
	err := pageTmpl.Execute(rw, map[string]any{
		"Rows":      rows,
		"Msg":       r.URL.Query().Get("msg"),
		"Sync":      st,
		"SyncedAgo": ago(st.LastOK),
		"AgendaAge": agendaAge,
		"Local":     w.Local,
		"Redirect":  w.Google.RedirectURI,
	})
	if err != nil {
		log.Printf("render: %v", err)
	}
}

var pageTmpl = template.Must(template.New("page").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{{if .Sync.Running}}<meta http-equiv="refresh" content="6">{{end}}
<title>Calendars</title>
<link rel="stylesheet" href="https://cdn.gisi.network/theme/tokens.css">
<style>
 body{font-family:var(--f-body,system-ui);background:var(--c-bg,#faf8f5);color:var(--c-text,#222);max-width:760px;margin:2rem auto;padding:0 1rem;line-height:1.45}
 h1{font-family:var(--f-brand,inherit);color:var(--c-primary,#b4622d);margin:0 0 .25rem}
 h2{font-size:1rem;margin:1.6rem 0 .5rem}
 .sub{color:var(--c-muted,#777);margin:0 0 1.5rem}
 .flash{background:var(--c-surface,#fff3e6);border-left:3px solid var(--c-primary,#b4622d);padding:.6rem .9rem;margin:0 0 1rem}
 .acct{border:1px solid var(--c-border,#ddd);border-radius:8px;padding:.8rem 1rem;margin:0 0 .7rem;background:var(--c-surface,#fff)}
 .acct b{word-break:break-all}
 .meta{font-size:.9rem;color:var(--c-muted,#666)}
 .bad{color:#b00020}.ok{color:#2e7d32}
 .row{display:flex;gap:.5rem;flex-wrap:wrap;margin-top:.5rem;align-items:center}
 form{display:inline;margin:0}
 button{font:inherit;padding:.4rem .8rem;border-radius:6px;border:1px solid var(--c-border,#ccc);background:var(--c-bg,#fff);color:inherit;cursor:pointer}
 .primary{background:var(--c-primary,#b4622d);color:var(--c-primary-fg,#fff);border-color:transparent}
 .danger{color:#b00020}
 input[type=email]{font:inherit;padding:.4rem .6rem;border:1px solid var(--c-border,#ccc);border-radius:6px;min-width:16rem}
 details{margin-top:1rem;font-size:.92rem} pre{white-space:pre-wrap;font-size:.8rem;background:var(--c-surface,#f4f4f4);padding:.5rem;max-height:16rem;overflow:auto}
 code{font-size:.85em}
</style></head><body>
<h1>Calendars</h1>
<p class="sub">Google accounts synced (read-only) to ratched every 15 minutes, alongside the Radicale calendars. Kes reads the merged agenda; she only writes to your personal Radicale calendar.</p>
{{with .Msg}}<div class="flash">{{.}}</div>{{end}}

<h2>Google accounts</h2>
{{range .Rows}}
<div class="acct">
 <b>{{.Email}}</b>{{if .Legacy}} <span class="meta">(work)</span>{{end}}
 <div class="meta">Token saved {{.Since}}{{if not .Legacy}}{{if .Calendars}} · {{.Calendars}} calendars synced{{else}} · nothing synced yet{{end}}{{end}}.</div>
 <div class="row">
  <form method="post" action="/connect"><input type="hidden" name="login_hint" value="{{.Email}}"><button>Reconnect</button></form>
  {{if not .Legacy}}<form method="post" action="/act" onsubmit="return confirm('Disconnect {{.Email}}, revoke access and drop its local copy?')"><input type="hidden" name="email" value="{{.Email}}"><input type="hidden" name="action" value="remove"><button class="danger">Disconnect</button></form>{{end}}
 </div>
</div>
{{else}}<p>No Google accounts yet.</p>{{end}}

<form method="post" action="/connect" class="row">
 <input type="email" name="login_hint" placeholder="address (optional)">
 <button class="primary">Connect a Google account</button>
</form>
<p class="meta">Only calendars ticked at <a href="https://calendar.google.com/calendar/syncselect">calendar.google.com/calendar/syncselect</a> are visible to sync, per account.</p>

<h2>Also synced</h2>
<ul class="meta">{{range .Local}}<li>{{.}}</li>{{end}}</ul>

<h2>Sync</h2>
<div class="meta">
 {{if .Sync.Running}}Syncing now…{{else if .Sync.Error}}<span class="bad">Last on-demand sync failed: {{.Sync.Error}}</span>{{else}}<span class="ok">Last successful sync {{.SyncedAgo}}.</span>{{end}}
 Agenda for Kes refreshed {{.AgendaAge}}.
</div>
<div class="row"><form method="post" action="/act"><input type="hidden" name="action" value="sync"><button>Sync now</button></form></div>
{{if .Sync.Output}}<details><summary class="meta">Last on-demand sync output</summary><pre>{{.Sync.Output}}</pre></details>{{end}}

<details>
<summary>If Google refuses</summary>
<ul>
 <li><b>redirect_uri_mismatch:</b> the OAuth client needs <code>{{.Redirect}}</code> as an authorized redirect URI.</li>
 <li><b>Works, then breaks after a week:</b> the consent screen is still in <i>Testing</i>; publish it to <i>In production</i>.</li>
 <li><b>Sync says 403 / API disabled:</b> enable the <i>CalDAV API</i> in the same Cloud project.</li>
 <li><b>Workspace account blocked:</b> Admin console → Security → API controls → trust this OAuth client.</li>
</ul>
</details>
</body></html>
`))
