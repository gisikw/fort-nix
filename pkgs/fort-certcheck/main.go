package main

import (
	"flag"
	"fmt"
	"os"
	"time"
)

// Exit codes: 0 = the named condition holds, 1 = it does not, 2 = usage error.
//
//	fort-certcheck should-renew --cert PATH --min-days N [--marker PATH]
//	    exit 0 when the cert needs renewal (missing, unreadable, expired,
//	    or expiring within N days). The marker path, if given, is only
//	    reported — it never gates the decision (q-6f9d966e).
//
//	fort-certcheck fresh --cert PATH --min-days N
//	    exit 0 when the cert is present, readable, and valid for more than
//	    N days. Used as the ssl-cert need's freshness probe.
//
//	fort-certcheck should-install --cert PATH --key PATH --current PATH
//	    exit 0 when the candidate cert/key pair should replace the current
//	    cert; exit 1 when the candidate is valid but not an improvement
//	    (identical, or current is better) — a safe no-op; exit 3 when the
//	    candidate itself is unusable (unreadable, key mismatch) — callers
//	    should treat that as a failed delivery and retry.
func main() {
	if len(os.Args) < 2 {
		usage()
	}
	cmd := os.Args[1]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)

	switch cmd {
	case "should-renew":
		certPath := fs.String("cert", "", "path to certificate PEM")
		minDays := fs.Int("min-days", 30, "renewal threshold in days")
		markerPath := fs.String("marker", "", "acme-success marker path (reported, never gates)")
		fs.Parse(os.Args[2:])
		if *certPath == "" {
			usage()
		}
		markerExists := false
		if *markerPath != "" {
			_, err := os.Stat(*markerPath)
			markerExists = err == nil
		}
		certPEM, _ := os.ReadFile(*certPath) // missing file → nil → renew
		d := DecideRenewal(markerExists, certPEM, time.Now(), *minDays)
		report(cmd, d)

	case "fresh":
		certPath := fs.String("cert", "", "path to certificate PEM")
		minDays := fs.Int("min-days", 21, "freshness threshold in days")
		fs.Parse(os.Args[2:])
		if *certPath == "" {
			usage()
		}
		certPEM, _ := os.ReadFile(*certPath)
		d := IsFresh(certPEM, time.Now(), *minDays)
		report(cmd, d)

	case "should-install":
		certPath := fs.String("cert", "", "candidate certificate PEM")
		keyPath := fs.String("key", "", "candidate private key PEM")
		currentPath := fs.String("current", "", "currently installed certificate PEM")
		fs.Parse(os.Args[2:])
		if *certPath == "" || *keyPath == "" || *currentPath == "" {
			usage()
		}
		candCert, err := os.ReadFile(*certPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "should-install: invalid: cannot read candidate cert: %v\n", err)
			os.Exit(3)
		}
		candKey, err := os.ReadFile(*keyPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "should-install: invalid: cannot read candidate key: %v\n", err)
			os.Exit(3)
		}
		if err := ValidatePair(candCert, candKey); err != nil {
			fmt.Fprintf(os.Stderr, "should-install: invalid: %v\n", err)
			os.Exit(3)
		}
		currentCert, _ := os.ReadFile(*currentPath) // missing current → install
		d := ShouldInstall(candCert, candKey, currentCert, time.Now())
		report(cmd, d)

	default:
		usage()
	}
}

func report(cmd string, d Decision) {
	verdict := "no"
	code := 1
	if d.Act {
		verdict = "yes"
		code = 0
	}
	fmt.Fprintf(os.Stderr, "%s: %s: %s\n", cmd, verdict, d.Reason)
	os.Exit(code)
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  fort-certcheck should-renew --cert PATH --min-days N [--marker PATH]
  fort-certcheck fresh --cert PATH --min-days N
  fort-certcheck should-install --cert PATH --key PATH --current PATH`)
	os.Exit(2)
}
