// calroom is the calendar-accounts page for ratched's vdirsyncer: it runs
// the Google OAuth consent flow for any number of accounts and drops one
// token per account where cal-sync turns it into a read-only vdirsyncer pair.
// It replaces the single-account Python helper at the same URL.
package main

import (
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func secret(fileVar, valVar string) string {
	if p := os.Getenv(fileVar); p != "" {
		b, err := os.ReadFile(p)
		if err != nil {
			log.Fatalf("%s: %v", fileVar, err)
		}
		return strings.TrimSpace(string(b))
	}
	return strings.TrimSpace(os.Getenv(valVar))
}

func main() {
	id := secret("OAUTH_CLIENT_ID_FILE", "OAUTH_CLIENT_ID")
	sec := secret("OAUTH_CLIENT_SECRET_FILE", "OAUTH_CLIENT_SECRET")
	origin := env("ORIGIN", "https://vdirsyncer-auth.gisi.network")
	if id == "" || sec == "" {
		log.Fatal("OAuth client id/secret missing")
	}
	data := env("DATA_DIR", "/var/lib/vdirsyncer")
	w := &Web{
		Store: &Store{
			Dir:         env("TOKEN_DIR", data+"/tokens"),
			LegacyFile:  env("LEGACY_TOKEN", data+"/token"),
			LegacyEmail: strings.ToLower(env("LEGACY_EMAIL", "")),
			DataDir:     os.Getenv("GOOGLE_DATA_DIR"),
			StatusDir:   os.Getenv("STATUS_DIR"),
		},
		Google: newGoogle(id, sec, origin+"/callback"),
		Syncer: &Syncer{Cmd: os.Getenv("SYNC_CMD"), LastSync: os.Getenv("LAST_SYNC_FILE")},
		Origin: origin,
		Agenda: os.Getenv("AGENDA_FILE"),
	}
	for _, l := range strings.Split(os.Getenv("LOCAL_CALENDARS"), ";") {
		if l = strings.TrimSpace(l); l != "" {
			w.Local = append(w.Local, l)
		}
	}
	addr := "127.0.0.1:" + env("PORT", "8088")
	srv := &http.Server{Addr: addr, Handler: w.Routes(), ReadHeaderTimeout: 10 * time.Second}
	log.Printf("calroom on %s (origin %s)", addr, origin)
	log.Fatal(srv.ListenAndServe())
}
