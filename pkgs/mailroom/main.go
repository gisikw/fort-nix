// mailroom: account connections for mail.gisi.network.
//
// One process, three jobs, all on loopback:
//   - /accounts/ web page (behind the fort identity proxy) to connect,
//     reconnect, and remove Google accounts via OAuth;
//   - a sync loop running mbsync per account into Maildirs Dovecot serves;
//   - a tiny SMTP submission listener for Roundcube that relays each
//     message through the sending account's own SMTP with XOAUTH2.
//
// Refresh tokens live only in $MAILROOM_STATE/accounts/*.json (0600).
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func mustFile(k string) string {
	p := os.Getenv(k)
	if p == "" {
		log.Fatalf("%s is required", k)
	}
	b, err := os.ReadFile(p)
	if err != nil {
		log.Fatalf("%s: %v", k, err)
	}
	return strings.TrimSpace(string(b))
}

func main() {
	log.SetFlags(0)
	state := env("MAILROOM_STATE", "/var/lib/mailroom")
	mailRoot := env("MAILROOM_MAILDIR", "/var/lib/mail/maildir")
	origin := strings.TrimRight(env("MAILROOM_ORIGIN", "https://mail.gisi.network"), "/")
	interval, err := time.ParseDuration(env("MAILROOM_SYNC_INTERVAL", "5m"))
	if err != nil {
		log.Fatalf("MAILROOM_SYNC_INTERVAL: %v", err)
	}

	store, err := OpenStore(state)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	if err := os.MkdirAll(mailRoot, 0o700); err != nil {
		log.Fatalf("maildir: %v", err)
	}
	g := newGoogle(mustFile("GOOGLE_CLIENT_ID_FILE"), mustFile("GOOGLE_CLIENT_SECRET_FILE"), origin+"/accounts/callback")

	syncer := &Syncer{
		Store: store, Google: g,
		Mbsync:   env("MBSYNC", "mbsync"),
		MailRoot: mailRoot, StateDir: state,
		Interval: interval, Timeout: 6 * time.Hour,
		kick: make(chan string, 1),
	}
	sub := &Submission{
		Addr:     env("MAILROOM_SMTP", "127.0.0.1:2525"),
		User:     env("MAILROOM_SMTP_USER", "kevin"),
		Password: mustFile("MAILROOM_SMTP_PASS_FILE"),
		Store:    store, Google: g,
		Upstream: env("MAILROOM_SMTP_UPSTREAM", "smtp.gmail.com:465"),
		MaxSize:  35 << 20,
	}
	web := &Web{Store: store, Google: g, Syncer: syncer, Origin: origin, Root: mailRoot}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	go syncer.Run(ctx)
	go func() { log.Fatalf("smtp: %v", sub.ListenAndServe()) }()

	srv := &http.Server{
		Addr:              env("MAILROOM_HTTP", "127.0.0.1:8096"),
		Handler:           web.Routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		<-ctx.Done()
		sctx, c := context.WithTimeout(context.Background(), 5*time.Second)
		defer c()
		_ = srv.Shutdown(sctx)
	}()
	log.Printf("mailroom: http %s, smtp %s, %d account(s)", srv.Addr, sub.Addr, len(store.List()))
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("http: %v", err)
	}
}
