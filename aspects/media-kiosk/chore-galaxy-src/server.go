package main

// HTTP surface: embedded kiosk frontend at /, JSON API under /api/, SSE state
// stream at /api/events. Mutations return the usual JSON error shape with a
// sharp message; the frontend treats any non-200 as "re-render last good
// state" (a kid never sees an error they can't act on).

import (
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"
)

//go:embed web
var webFS embed.FS

//go:embed state.example.json
var exampleState []byte

// ── SSE hub ─────────────────────────────────────────────────────────────────

type Hub struct {
	mu   sync.Mutex
	subs map[chan []byte]struct{}
}

func newHub() *Hub { return &Hub{subs: map[chan []byte]struct{}{}} }

func (h *Hub) Subscribe() chan []byte {
	ch := make(chan []byte, 8)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	h.mu.Unlock()
	return ch
}

func (h *Hub) Unsubscribe(ch chan []byte) {
	h.mu.Lock()
	delete(h.subs, ch)
	h.mu.Unlock()
}

// Broadcast never blocks a mutation on a slow client: full buffers drop the
// frame (the next broadcast carries complete state anyway).
func (h *Hub) Broadcast(payload []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- payload:
		default:
		}
	}
}

// ── routes ──────────────────────────────────────────────────────────────────

func (st *Store) routes() http.Handler {
	mux := http.NewServeMux()

	web, err := fs.Sub(webFS, "web")
	if err != nil {
		panic(err) // embedded tree is fixed at compile time
	}
	mux.Handle("/", http.FileServerFS(web))

	mux.HandleFunc("GET /api/state", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write(st.PayloadJSON())
	})
	mux.HandleFunc("GET /api/events", st.handleSSE)

	// Kid-facing mutations.
	mux.HandleFunc("POST /api/travel", handle(func(r *http.Request) (any, error) {
		var b struct{ Kid, To string }
		if err := readJSON(r, &b); err != nil {
			return nil, err
		}
		return ok(), st.Travel(b.Kid, b.To)
	}))
	mux.HandleFunc("POST /api/unlock", handle(func(r *http.Request) (any, error) {
		var b struct{ Kid, Planet, App string }
		if err := readJSON(r, &b); err != nil {
			return nil, err
		}
		return ok(), st.Unlock(b.Kid, b.Planet, b.App)
	}))
	mux.HandleFunc("POST /api/battle-win", handle(func(r *http.Request) (any, error) {
		var b struct{ Kid, Planet, App string }
		if err := readJSON(r, &b); err != nil {
			return nil, err
		}
		return ok(), st.BattleWin(b.Kid, b.Planet, b.App)
	}))
	mux.HandleFunc("POST /api/launch", handle(func(r *http.Request) (any, error) {
		var b struct{ Kid, App string }
		if err := readJSON(r, &b); err != nil {
			return nil, err
		}
		return ok(), st.Launch(b.Kid, b.App)
	}))

	// Management-plane operations (mesh-internal; no UI here by design).
	mux.HandleFunc("POST /api/admin/grant", handle(func(r *http.Request) (any, error) {
		var b struct {
			Kid    string
			Coins  int
			Reason string
		}
		if err := readJSON(r, &b); err != nil {
			return nil, err
		}
		return ok(), st.Grant(b.Kid, b.Coins, b.Reason)
	}))
	mux.HandleFunc("POST /api/admin/chore-check", handle(func(r *http.Request) (any, error) {
		var b struct{ Kid, Chore string }
		if err := readJSON(r, &b); err != nil {
			return nil, err
		}
		return ok(), st.ChoreCheck(b.Kid, b.Chore)
	}))
	mux.HandleFunc("POST /api/admin/chore-uncheck", handle(func(r *http.Request) (any, error) {
		var b struct{ Kid, Chore string }
		if err := readJSON(r, &b); err != nil {
			return nil, err
		}
		return ok(), st.ChoreUncheck(b.Kid, b.Chore)
	}))
	mux.HandleFunc("POST /api/admin/chores", handle(func(r *http.Request) (any, error) {
		var b struct {
			Kid    string
			Chores []*Chore
		}
		if err := readJSON(r, &b); err != nil {
			return nil, err
		}
		return ok(), st.SetChores(b.Kid, b.Chores)
	}))
	mux.HandleFunc("GET /api/admin/ledger", handle(func(r *http.Request) (any, error) {
		n := 50
		if q := r.URL.Query().Get("n"); q != "" {
			v, err := strconv.Atoi(q)
			if err != nil || v < 1 || v > 1000 {
				return nil, errBad("n must be 1..1000")
			}
			n = v
		}
		events, err := ledgerTail(st.ledgerPath(), n)
		if err != nil {
			return nil, err
		}
		return map[string]any{"events": events}, nil
	}))
	mux.HandleFunc("POST /api/admin/steal", handle(func(r *http.Request) (any, error) {
		var b struct {
			Planet, App string
			Cost        int
		}
		if err := readJSON(r, &b); err != nil {
			return nil, err
		}
		return ok(), st.Steal(b.Planet, b.App, b.Cost)
	}))
	mux.HandleFunc("POST /api/admin/stop-app", handle(func(r *http.Request) (any, error) {
		return ok(), st.StopApp()
	}))
	mux.HandleFunc("POST /api/admin/tick", handle(func(r *http.Request) (any, error) {
		var b struct {
			Date string
			Days int
		}
		if err := readJSON(r, &b); err != nil {
			return nil, err
		}
		target, err := st.resolveTickTarget(b.Date, b.Days)
		if err != nil {
			return nil, errBad("%v", err)
		}
		days, err := st.Tick(target)
		if err != nil {
			return nil, err
		}
		st.mu.Lock()
		night, last := st.state.Night, st.state.LastTickDate
		st.mu.Unlock()
		return map[string]any{"ok": true, "advanced": days, "night": night, "lastTickDate": last}, nil
	}))

	return mux
}

func (st *Store) handleSSE(w http.ResponseWriter, r *http.Request) {
	flusher, okf := w.(http.Flusher)
	if !okf {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	ch := st.hub.Subscribe()
	defer st.hub.Unsubscribe(ch)

	send := func(payload []byte) bool {
		if _, err := fmt.Fprintf(w, "data: %s\n\n", payload); err != nil {
			return false
		}
		flusher.Flush()
		return true
	}
	if !send(st.PayloadJSON()) {
		return
	}
	heartbeat := time.NewTicker(25 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case payload := <-ch:
			if !send(payload) {
				return
			}
		case <-heartbeat.C:
			if _, err := fmt.Fprint(w, ": hb\n\n"); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

// ── JSON plumbing ───────────────────────────────────────────────────────────

func ok() map[string]any { return map[string]any{"ok": true} }

func readJSON(r *http.Request, dst any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return errBad("bad request body: %v", err)
	}
	return nil
}

func handle(fn func(*http.Request) (any, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		resp, err := fn(r)
		w.Header().Set("Content-Type", "application/json")
		if err != nil {
			code := http.StatusInternalServerError
			var he *httpError
			if errors.As(err, &he) {
				code = he.code
			} else {
				log.Printf("internal error on %s %s: %v", r.Method, r.URL.Path, err)
			}
			w.WriteHeader(code)
			json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		json.NewEncoder(w).Encode(resp)
	}
}
