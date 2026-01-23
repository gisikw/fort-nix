package main

import (
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

//go:embed static/*
var staticFiles embed.FS

type Item struct {
	ID      string `json:"id"`
	Text    string `json:"text"`
	Done    bool   `json:"done"`
	Created string `json:"created"`
}

type Store struct {
	Items []Item `json:"items"`
}

var (
	store      Store
	storeMu    sync.RWMutex
	storePath  string
	lastMod    time.Time
	clients    = make(map[*websocket.Conn]bool)
	clientsMu  sync.Mutex
	upgrader   = websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool { return true },
	}
)

func main() {
	addr := flag.String("addr", ":8765", "listen address")
	dataFile := flag.String("data", "/var/lib/punchlist/items.json", "path to items.json")
	flag.Parse()

	storePath = *dataFile

	// Ensure parent directory exists
	if err := os.MkdirAll(filepath.Dir(storePath), 0755); err != nil {
		log.Fatalf("Failed to create data directory: %v", err)
	}

	// Load initial data
	if err := loadStore(); err != nil {
		log.Printf("Warning: could not load store: %v (starting fresh)", err)
		store = Store{Items: []Item{}}
		saveStore()
	}

	// Watch for external file changes
	go watchFile()

	// Static files
	staticFS, _ := fs.Sub(staticFiles, "static")
	http.Handle("/", http.FileServer(http.FS(staticFS)))

	// API
	http.HandleFunc("/api/items", handleItems)
	http.HandleFunc("/api/items/", handleItem) // handles PATCH, DELETE, and /bump
	http.HandleFunc("/ws", handleWebSocket)

	log.Printf("Punchlist listening on %s (data: %s)", *addr, storePath)
	log.Fatal(http.ListenAndServe(*addr, nil))
}

func loadStore() error {
	storeMu.Lock()
	defer storeMu.Unlock()

	data, err := os.ReadFile(storePath)
	if err != nil {
		if os.IsNotExist(err) {
			store = Store{Items: []Item{}}
			return nil
		}
		return err
	}

	// Zero out before unmarshaling - otherwise fields missing from JSON
	// (e.g., writing "{}") won't clear the in-memory state
	store = Store{}
	if err := json.Unmarshal(data, &store); err != nil {
		return err
	}

	// Ensure Items is never nil (nil serializes as "null", not "[]")
	if store.Items == nil {
		store.Items = []Item{}
	}

	if info, err := os.Stat(storePath); err == nil {
		lastMod = info.ModTime()
	}

	return nil
}

func saveStore() error {
	storeMu.Lock()
	defer storeMu.Unlock()

	data, err := json.MarshalIndent(store, "", "  ")
	if err != nil {
		return err
	}

	if err := os.WriteFile(storePath, data, 0660); err != nil {
		return err
	}

	if info, err := os.Stat(storePath); err == nil {
		lastMod = info.ModTime()
	}

	return nil
}

func watchFile() {
	ticker := time.NewTicker(500 * time.Millisecond)
	for range ticker.C {
		info, err := os.Stat(storePath)
		if err != nil {
			// File might have been deleted, check again next tick
			continue
		}

		storeMu.RLock()
		// Use != instead of After to catch any mtime change (including file replacement)
		changed := !info.ModTime().Equal(lastMod)
		storeMu.RUnlock()

		if changed {
			log.Printf("File changed externally, reloading")
			if err := loadStore(); err != nil {
				log.Printf("Error reloading store: %v", err)
				continue
			}
			broadcast()
		}
	}
}

func broadcast() {
	storeMu.RLock()
	data, _ := json.Marshal(store.Items)
	storeMu.RUnlock()

	clientsMu.Lock()
	for conn := range clients {
		if err := conn.WriteMessage(websocket.TextMessage, data); err != nil {
			conn.Close()
			delete(clients, conn)
		}
	}
	clientsMu.Unlock()
}

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade failed: %v", err)
		return
	}

	clientsMu.Lock()
	clients[conn] = true
	clientsMu.Unlock()

	// Send current state immediately
	storeMu.RLock()
	data, _ := json.Marshal(store.Items)
	storeMu.RUnlock()
	conn.WriteMessage(websocket.TextMessage, data)

	// Keep connection alive, remove on close
	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			clientsMu.Lock()
			delete(clients, conn)
			clientsMu.Unlock()
			conn.Close()
			return
		}
	}
}

func handleItems(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case "GET":
		storeMu.RLock()
		data, _ := json.Marshal(store.Items)
		storeMu.RUnlock()
		w.Header().Set("Content-Type", "application/json")
		w.Write(data)

	case "POST":
		var req struct {
			Text string `json:"text"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "Invalid JSON", http.StatusBadRequest)
			return
		}
		if strings.TrimSpace(req.Text) == "" {
			http.Error(w, "Text required", http.StatusBadRequest)
			return
		}

		item := Item{
			ID:      fmt.Sprintf("%d", time.Now().UnixNano()),
			Text:    strings.TrimSpace(req.Text),
			Done:    false,
			Created: time.Now().Format(time.RFC3339),
		}

		storeMu.Lock()
		store.Items = append(store.Items, item)
		storeMu.Unlock()

		if err := saveStore(); err != nil {
			http.Error(w, "Failed to save", http.StatusInternalServerError)
			return
		}

		broadcast()

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(item)

	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func handleItem(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/items/")

	// Check for bump action: /api/items/{id}/bump
	if strings.HasSuffix(path, "/bump") {
		id := strings.TrimSuffix(path, "/bump")
		handleBump(w, r, id)
		return
	}

	id := path
	if id == "" {
		http.Error(w, "ID required", http.StatusBadRequest)
		return
	}

	switch r.Method {
	case "PATCH":
		storeMu.Lock()
		found := false
		var toggledItem Item
		for i := range store.Items {
			if store.Items[i].ID == id {
				store.Items[i].Done = !store.Items[i].Done
				toggledItem = store.Items[i] // Copy value before slice manipulation
				found = true

				// Move completed items to top (start of array, which displays at top)
				if store.Items[i].Done {
					store.Items = append(store.Items[:i], store.Items[i+1:]...)
					store.Items = append([]Item{toggledItem}, store.Items...)
				}
				break
			}
		}
		storeMu.Unlock()

		if !found {
			http.Error(w, "Not found", http.StatusNotFound)
			return
		}

		if err := saveStore(); err != nil {
			http.Error(w, "Failed to save", http.StatusInternalServerError)
			return
		}

		broadcast()

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(toggledItem)

	case "DELETE":
		storeMu.Lock()
		found := false
		for i := range store.Items {
			if store.Items[i].ID == id {
				store.Items = append(store.Items[:i], store.Items[i+1:]...)
				found = true
				break
			}
		}
		storeMu.Unlock()

		if !found {
			http.Error(w, "Not found", http.StatusNotFound)
			return
		}

		if err := saveStore(); err != nil {
			http.Error(w, "Failed to save", http.StatusInternalServerError)
			return
		}

		broadcast()

		w.WriteHeader(http.StatusNoContent)

	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func handleBump(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != "POST" {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	if id == "" {
		http.Error(w, "ID required", http.StatusBadRequest)
		return
	}

	storeMu.Lock()
	found := false
	var bumpedItem Item
	for i := range store.Items {
		if store.Items[i].ID == id {
			bumpedItem = store.Items[i]
			found = true
			// Remove from current position
			store.Items = append(store.Items[:i], store.Items[i+1:]...)
			// Add to end (bottom of visual list, near input)
			store.Items = append(store.Items, bumpedItem)
			break
		}
	}
	storeMu.Unlock()

	if !found {
		http.Error(w, "Not found", http.StatusNotFound)
		return
	}

	if err := saveStore(); err != nil {
		http.Error(w, "Failed to save", http.StatusInternalServerError)
		return
	}

	broadcast()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(bumpedItem)
}
