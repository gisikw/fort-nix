package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Entry struct {
	StorePath string `json:"storePath"`
	UpdatedAt int64  `json:"updatedAt"`
}

type Registry struct {
	mu       sync.RWMutex
	entries  map[string]Entry
	dataFile string
}

func NewRegistry(dataFile string) (*Registry, error) {
	r := &Registry{entries: make(map[string]Entry), dataFile: dataFile}
	if data, err := os.ReadFile(dataFile); err == nil {
		if err := json.Unmarshal(data, &r.entries); err != nil {
			return nil, fmt.Errorf("parse %s: %w", dataFile, err)
		}
	}
	return r, nil
}

func (r *Registry) save() error {
	data, err := json.MarshalIndent(r.entries, "", "  ")
	if err != nil {
		return err
	}
	tmp := r.dataFile + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		return err
	}
	return os.Rename(tmp, r.dataFile)
}

func (r *Registry) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	path := strings.TrimPrefix(req.URL.Path, "/")

	switch req.Method {
	case http.MethodGet:
		r.mu.RLock()
		defer r.mu.RUnlock()
		w.Header().Set("Content-Type", "application/json")
		if path == "" {
			json.NewEncoder(w).Encode(r.entries)
		} else {
			entry, ok := r.entries[path]
			if !ok {
				http.Error(w, "not found", http.StatusNotFound)
				return
			}
			json.NewEncoder(w).Encode(entry)
		}

	case http.MethodPost:
		if path == "" {
			http.Error(w, "package name required", http.StatusBadRequest)
			return
		}
		var body struct {
			StorePath string `json:"storePath"`
		}
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil || body.StorePath == "" {
			http.Error(w, "storePath required", http.StatusBadRequest)
			return
		}
		r.mu.Lock()
		r.entries[path] = Entry{StorePath: body.StorePath, UpdatedAt: time.Now().Unix()}
		if err := r.save(); err != nil {
			r.mu.Unlock()
			log.Printf("save error: %v", err)
			http.Error(w, "save failed", http.StatusInternalServerError)
			return
		}
		r.mu.Unlock()
		log.Printf("updated %s -> %s", path, body.StorePath)
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `{"ok":true}`)

	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func main() {
	dataFile := os.Getenv("REGISTRY_DATA_FILE")
	if dataFile == "" {
		dataFile = "/var/lib/overlay-registry/registry.json"
	}
	if err := os.MkdirAll(filepath.Dir(dataFile), 0755); err != nil {
		log.Fatal(err)
	}

	listenAddr := os.Getenv("LISTEN_ADDR")
	if listenAddr == "" {
		listenAddr = "127.0.0.1:9480"
	}

	registry, err := NewRegistry(dataFile)
	if err != nil {
		log.Fatal(err)
	}

	log.Printf("overlay-registry listening on %s (data: %s)", listenAddr, dataFile)
	log.Fatal(http.ListenAndServe(listenAddr, registry))
}
