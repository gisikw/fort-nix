package main

// chore-galaxy serve --port 8080 --data /var/lib/chore-galaxy [--dev]
//
// One binary: embedded kiosk frontend, JSON API, SSE state stream, nightly
// tick, app launcher. State is flat files in --data. Crash-only: no shutdown
// handling on purpose — kill it whenever; boot recovers from the files.

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] != "serve" {
		fmt.Fprintln(os.Stderr, "usage: chore-galaxy serve [--port 8080] [--data ./data] [--dev]")
		os.Exit(2)
	}
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	port := fs.String("port", "8080", "port to listen on")
	data := fs.String("data", "./data", "data directory (state.json, ledger.jsonl, launchers.json)")
	dev := fs.Bool("dev", false, "dev mode: seed missing data files from examples, enable the kiosk sim-night button")
	fs.Parse(os.Args[2:])

	st, err := OpenStore(*data, *dev)
	if err != nil {
		log.Fatalf("chore-galaxy: %v", err)
	}

	// Catch up any nights missed while the host was off, then keep ticking.
	if days, err := st.Tick(st.now()); err != nil {
		log.Fatalf("catch-up tick: %v", err)
	} else if days > 0 {
		log.Printf("caught up %d missed night(s)", days)
	}
	go st.tickLoop()
	go st.watchFiles(time.Second) // hand-edits to data files hot-reload (watch.go)

	log.Printf("chore-galaxy serving on :%s (data: %s, dev: %v)", *port, *data, *dev)
	if err := http.ListenAndServe(":"+*port, st.routes()); err != nil {
		log.Fatal(err)
	}
}
