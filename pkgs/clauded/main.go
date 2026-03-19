// clauded - Process-isolated Claude invocation daemon
//
// Runs as a systemd service with its own process tree, accepting requests
// over a unix socket and spawning claude subprocesses. This bypasses Claude
// Code's Bash tool output suppression, which blanks output when any `claude`
// process exists in the caller's process tree.
//
// Usage:
//   clauded serve [--socket /path/to/sock]   # daemon mode
//   clauded [claude args...]                  # client mode (forwards to daemon)

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"sync"
)

const defaultSocket = "/run/clauded/clauded.sock"

// Request is sent from client to daemon over the unix socket.
type Request struct {
	Args []string `json:"args"`
	Cwd  string   `json:"cwd"`
}

// Message is streamed from daemon to client (newline-delimited JSON).
type Message struct {
	Type string `json:"type"` // "stdout", "stderr", "exit", "error"
	Data string `json:"data,omitempty"`
	Code int    `json:"code,omitempty"`
}

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "serve" {
		sock := defaultSocket
		for i, arg := range os.Args[2:] {
			if arg == "--socket" && i+3 < len(os.Args) {
				sock = os.Args[i+3]
			}
		}
		serve(sock)
	} else {
		client(os.Args[1:])
	}
}

// --- Daemon ---

func serve(socketPath string) {
	// Clean up stale socket
	os.Remove(socketPath)

	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "clauded: listen %s: %v\n", socketPath, err)
		os.Exit(1)
	}
	defer ln.Close()

	// Allow owner-only access (systemd RuntimeDirectoryMode handles dir perms)
	os.Chmod(socketPath, 0700)

	fmt.Fprintf(os.Stderr, "clauded: listening on %s\n", socketPath)

	for {
		conn, err := ln.Accept()
		if err != nil {
			fmt.Fprintf(os.Stderr, "clauded: accept: %v\n", err)
			continue
		}
		go handleConn(conn)
	}
}

func handleConn(conn net.Conn) {
	defer conn.Close()

	enc := json.NewEncoder(conn)

	// Read request
	var req Request
	dec := json.NewDecoder(conn)
	if err := dec.Decode(&req); err != nil {
		enc.Encode(Message{Type: "error", Data: fmt.Sprintf("decode request: %v", err)})
		return
	}

	if len(req.Args) == 0 {
		enc.Encode(Message{Type: "error", Data: "no args provided"})
		return
	}

	// Spawn claude
	cmd := exec.Command("claude", req.Args...)
	if req.Cwd != "" {
		cmd.Dir = req.Cwd
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		enc.Encode(Message{Type: "error", Data: fmt.Sprintf("stdout pipe: %v", err)})
		return
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		enc.Encode(Message{Type: "error", Data: fmt.Sprintf("stderr pipe: %v", err)})
		return
	}

	if err := cmd.Start(); err != nil {
		enc.Encode(Message{Type: "error", Data: fmt.Sprintf("start claude: %v", err)})
		return
	}

	fmt.Fprintf(os.Stderr, "clauded: spawned claude %v (pid %d)\n", req.Args, cmd.Process.Pid)

	// Stream stdout and stderr back as NDJSON
	var mu sync.Mutex
	var wg sync.WaitGroup
	wg.Add(2)

	stream := func(typ string, r io.Reader) {
		defer wg.Done()
		scanner := bufio.NewScanner(r)
		// 1MB line buffer for large outputs
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for scanner.Scan() {
			mu.Lock()
			enc.Encode(Message{Type: typ, Data: scanner.Text()})
			mu.Unlock()
		}
	}

	go stream("stdout", stdout)
	go stream("stderr", stderr)
	wg.Wait()

	exitCode := 0
	if err := cmd.Wait(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			enc.Encode(Message{Type: "error", Data: fmt.Sprintf("wait: %v", err)})
			return
		}
	}

	enc.Encode(Message{Type: "exit", Code: exitCode})
	fmt.Fprintf(os.Stderr, "clauded: claude exited %d\n", exitCode)
}

// --- Client ---

func client(args []string) {
	sock := defaultSocket
	if v := os.Getenv("CLAUDED_SOCKET"); v != "" {
		sock = v
	}

	conn, err := net.Dial("unix", sock)
	if err != nil {
		fmt.Fprintf(os.Stderr, "clauded: connect %s: %v\n", sock, err)
		os.Exit(1)
	}
	defer conn.Close()

	// Get working directory
	cwd, _ := os.Getwd()

	// Send request
	req := Request{Args: args, Cwd: cwd}
	if err := json.NewEncoder(conn).Encode(req); err != nil {
		fmt.Fprintf(os.Stderr, "clauded: send request: %v\n", err)
		os.Exit(1)
	}

	// Half-close write side so daemon knows request is complete
	if uc, ok := conn.(*net.UnixConn); ok {
		uc.CloseWrite()
	}

	// Stream response
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	exitCode := 1
	for scanner.Scan() {
		var msg Message
		if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
			fmt.Fprintf(os.Stderr, "clauded: decode message: %v\n", err)
			continue
		}

		switch msg.Type {
		case "stdout":
			fmt.Println(msg.Data)
		case "stderr":
			fmt.Fprintln(os.Stderr, msg.Data)
		case "error":
			fmt.Fprintf(os.Stderr, "clauded: daemon error: %s\n", msg.Data)
			os.Exit(1)
		case "exit":
			exitCode = msg.Code
		}
	}

	os.Exit(exitCode)
}
