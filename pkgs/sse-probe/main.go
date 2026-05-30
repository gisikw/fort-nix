package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "usage: sse-probe <serve|monitor>\n")
		os.Exit(1)
	}

	switch os.Args[1] {
	case "serve":
		cmdServe(os.Args[2:])
	case "monitor":
		cmdMonitor(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}
}

// --- serve ---

func cmdServe(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	port := fs.Int("port", 9400, "listen port")
	host := fs.String("host", "", "host identifier (included in heartbeats)")
	interval := fs.Duration("interval", time.Second, "heartbeat interval")
	fs.Parse(args)

	if *host == "" {
		h, _ := os.Hostname()
		*host = h
	}

	var (
		mu      sync.Mutex
		clients = make(map[chan []byte]struct{})
	)

	// broadcaster goroutine
	go func() {
		seq := uint64(0)
		for {
			seq++
			data, _ := json.Marshal(map[string]interface{}{
				"seq":  seq,
				"ts":   time.Now().UTC().Format(time.RFC3339Nano),
				"host": *host,
			})
			msg := fmt.Sprintf("event: heartbeat\ndata: %s\n\n", data)

			mu.Lock()
			for ch := range clients {
				select {
				case ch <- []byte(msg):
				default:
					// slow client, drop
				}
			}
			mu.Unlock()

			time.Sleep(*interval)
		}
	}()

	http.HandleFunc("/events", func(w http.ResponseWriter, r *http.Request) {
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "streaming not supported", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")
		w.Header().Set("Access-Control-Allow-Origin", "*")

		ch := make(chan []byte, 8)
		mu.Lock()
		clients[ch] = struct{}{}
		mu.Unlock()

		defer func() {
			mu.Lock()
			delete(clients, ch)
			mu.Unlock()
		}()

		// send initial connected event
		fmt.Fprintf(w, "event: connected\ndata: {\"host\":%q}\n\n", *host)
		flusher.Flush()

		for {
			select {
			case msg := <-ch:
				w.Write(msg)
				flusher.Flush()
			case <-r.Context().Done():
				return
			}
		}
	})

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "ok\n")
	})

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("sse-probe serve on %s (host=%s, interval=%s)", addr, *host, *interval)
	log.Fatal(http.ListenAndServe(addr, nil))
}

// --- monitor ---

type targetFlag []string

func (t *targetFlag) String() string { return strings.Join(*t, ",") }
func (t *targetFlag) Set(v string) error {
	*t = append(*t, v)
	return nil
}

type dropEvent struct {
	Target     string    `json:"target"`
	DroppedAt  time.Time `json:"dropped_at"`
	ConnectedFor string `json:"connected_for"`
	LastSeq    uint64    `json:"last_seq"`
	Error      string    `json:"error,omitempty"`
}

type connEvent struct {
	Target      string    `json:"target"`
	ConnectedAt time.Time `json:"connected_at"`
	Attempt     int       `json:"attempt"`
}

type statsEntry struct {
	mu           sync.Mutex
	target       string
	drops        int
	connects     int
	lastConnect  time.Time
	lastDrop     time.Time
	totalUptime  time.Duration
	currentStart time.Time
	connected    bool
}

func cmdMonitor(args []string) {
	fs := flag.NewFlagSet("monitor", flag.ExitOnError)
	var targets targetFlag
	fs.Var(&targets, "target", "name=url pairs (repeatable)")
	statsInterval := fs.Duration("stats", 5*time.Minute, "stats summary interval")
	logFile := fs.String("log", "", "log file path (default: stdout)")
	fs.Parse(args)

	if len(targets) == 0 {
		fmt.Fprintf(os.Stderr, "at least one --target required\n")
		os.Exit(1)
	}

	var logger *log.Logger
	if *logFile != "" {
		f, err := os.OpenFile(*logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
		if err != nil {
			log.Fatalf("open log file: %v", err)
		}
		defer f.Close()
		logger = log.New(f, "", 0)
	} else {
		logger = log.New(os.Stdout, "", 0)
	}

	allStats := make([]*statsEntry, 0, len(targets))

	for _, t := range targets {
		parts := strings.SplitN(t, "=", 2)
		if len(parts) != 2 {
			log.Fatalf("invalid target format %q (want name=url)", t)
		}
		name, url := parts[0], parts[1]

		s := &statsEntry{target: name}
		allStats = append(allStats, s)

		go monitorTarget(name, url, s, logger)
	}

	// periodic stats summary
	ticker := time.NewTicker(*statsInterval)
	for range ticker.C {
		for _, s := range allStats {
			s.mu.Lock()
			uptime := s.totalUptime
			if s.connected {
				uptime += time.Since(s.currentStart)
			}
			elapsed := time.Since(s.lastConnect)
			if s.connects == 0 {
				elapsed = time.Duration(0)
			}
			summary := map[string]interface{}{
				"type":         "stats",
				"target":       s.target,
				"ts":           time.Now().UTC().Format(time.RFC3339),
				"drops":        s.drops,
				"connects":     s.connects,
				"total_uptime":  uptime.String(),
				"connected":    s.connected,
				"last_connect": s.lastConnect.Format(time.RFC3339),
			}
			if !s.lastDrop.IsZero() {
				summary["last_drop"] = s.lastDrop.Format(time.RFC3339)
			}
			if s.connects > 0 {
				_ = elapsed // available if needed
			}
			s.mu.Unlock()

			data, _ := json.Marshal(summary)
			logger.Println(string(data))
		}
	}
}

func monitorTarget(name, url string, stats *statsEntry, logger *log.Logger) {
	attempt := 0
	backoff := time.Second

	for {
		attempt++
		connectTime := time.Now()

		stats.mu.Lock()
		stats.connects++
		stats.lastConnect = connectTime
		stats.currentStart = connectTime
		stats.connected = true
		stats.mu.Unlock()

		ce := connEvent{
			Target:      name,
			ConnectedAt: connectTime,
			Attempt:     attempt,
		}
		data, _ := json.Marshal(map[string]interface{}{
			"type":    "connect",
			"target":  ce.Target,
			"ts":      ce.ConnectedAt.Format(time.RFC3339),
			"attempt": ce.Attempt,
		})
		logger.Println(string(data))

		lastSeq, err := streamSSE(name, url, stats, logger)

		dropTime := time.Now()
		connDuration := dropTime.Sub(connectTime)

		stats.mu.Lock()
		stats.drops++
		stats.lastDrop = dropTime
		stats.totalUptime += connDuration
		stats.connected = false
		stats.mu.Unlock()

		errStr := ""
		if err != nil {
			errStr = err.Error()
		}

		de := dropEvent{
			Target:       name,
			DroppedAt:    dropTime,
			ConnectedFor: connDuration.String(),
			LastSeq:      lastSeq,
			Error:        errStr,
		}
		data, _ = json.Marshal(map[string]interface{}{
			"type":          "drop",
			"target":        de.Target,
			"ts":            de.DroppedAt.Format(time.RFC3339),
			"connected_for": de.ConnectedFor,
			"last_seq":      de.LastSeq,
			"error":         de.Error,
		})
		logger.Println(string(data))

		// backoff with cap
		if connDuration > 30*time.Second {
			backoff = time.Second // reset if we had a good connection
		} else {
			backoff = min(backoff*2, 30*time.Second)
		}
		time.Sleep(backoff)
	}
}

func streamSSE(name, url string, stats *statsEntry, logger *log.Logger) (uint64, error) {
	client := &http.Client{
		Timeout: 0, // no timeout for SSE
	}

	resp, err := client.Get(url)
	if err != nil {
		return 0, fmt.Errorf("connect: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("status %d", resp.StatusCode)
	}

	scanner := bufio.NewScanner(resp.Body)
	var lastSeq uint64
	var prevSeq uint64

	for scanner.Scan() {
		line := scanner.Text()

		if !strings.HasPrefix(line, "data: ") {
			continue
		}

		data := strings.TrimPrefix(line, "data: ")
		var msg map[string]interface{}
		if err := json.Unmarshal([]byte(data), &msg); err != nil {
			continue
		}

		if seq, ok := msg["seq"].(float64); ok {
			lastSeq = uint64(seq)

			// detect server-side gaps (shouldn't happen, but track it)
			if prevSeq > 0 && lastSeq != prevSeq+1 {
				gap := map[string]interface{}{
					"type":     "gap",
					"target":   name,
					"ts":       time.Now().UTC().Format(time.RFC3339),
					"expected": prevSeq + 1,
					"got":      lastSeq,
				}
				data, _ := json.Marshal(gap)
				logger.Println(string(data))
			}
			prevSeq = lastSeq
		}
	}

	if err := scanner.Err(); err != nil {
		return lastSeq, fmt.Errorf("read: %w", err)
	}

	return lastSeq, fmt.Errorf("stream ended")
}
