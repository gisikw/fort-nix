package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Config loaded from /etc/fort/overlays.json
type Config struct {
	RegistryUrl  string                    `json:"registryUrl"`
	PollInterval string                    `json:"pollInterval"`
	StateDir     string                    `json:"stateDir"`
	BinDir       string                    `json:"binDir"`
	Overlays     map[string]OverlayConfig  `json:"overlays"`
}

type OverlayConfig struct {
	Package string            `json:"package"`
	Config  map[string]string `json:"config"`
	Enabled bool              `json:"enabled"`
}

// Registry entry from the overlay-registry service
type RegistryEntry struct {
	StorePath string `json:"storePath"`
	UpdatedAt int64  `json:"updatedAt"`
}

// Persisted state per overlay
type OverlayState struct {
	StorePath    string `json:"storePath"`
	ActivatedAt int64  `json:"activatedAt"`
	ManifestHash string `json:"manifestHash"`
}

// Evaluated overlay manifest (output of overlay.nix)
type OverlayManifest struct {
	Services map[string]ServiceDef `json:"services"`
	Bins     []string              `json:"bins"`
	Health   *HealthConfig         `json:"health"`
}

type ServiceDef struct {
	Exec             string   `json:"exec"`
	User             string   `json:"user"`
	Group            string   `json:"group"`
	WorkingDirectory string   `json:"workingDirectory"`
	After            []string `json:"after"`
	Restart          string   `json:"restart"`
	RestartSec       int      `json:"restartSec"`
	TimeoutStopSec   int      `json:"timeoutStopSec"`
	Environment      []string `json:"environment"`
	EnvironmentFile  []string `json:"environmentFile"`
}

type HealthConfig struct {
	Type      string `json:"type"`
	Endpoint  string `json:"endpoint"`
	Interval  int    `json:"interval"`
	Grace     int    `json:"grace"`
	Stabilize int    `json:"stabilize"`
}

const configPath = "/etc/fort/overlays.json"

func main() {
	log.SetFlags(log.Ldate | log.Ltime | log.Lshortfile)

	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "Usage: fort-overlay-manager <command> [args]\n")
		fmt.Fprintf(os.Stderr, "Commands: check, activate, rollback, status, boot\n")
		os.Exit(1)
	}

	cfg := loadConfig()

	switch os.Args[1] {
	case "check":
		overlay := ""
		for i, arg := range os.Args[2:] {
			if arg == "--overlay" && i+1 < len(os.Args[2:]) {
				overlay = os.Args[i+3]
			}
		}
		cmdCheck(cfg, overlay)
	case "activate":
		if len(os.Args) < 3 {
			log.Fatal("Usage: fort-overlay-manager activate <name> --store-path <path>")
		}
		name := os.Args[2]
		storePath := ""
		for i, arg := range os.Args[3:] {
			if arg == "--store-path" && i+1 < len(os.Args[3:]) {
				storePath = os.Args[i+4]
			}
		}
		if storePath == "" {
			log.Fatal("--store-path required")
		}
		cmdActivate(cfg, name, storePath)
	case "rollback":
		if len(os.Args) < 3 {
			log.Fatal("Usage: fort-overlay-manager rollback <name>")
		}
		cmdRollback(cfg, os.Args[2])
	case "status":
		jsonOutput := false
		for _, arg := range os.Args[2:] {
			if arg == "--json" {
				jsonOutput = true
			}
		}
		cmdStatus(cfg, jsonOutput)
	case "boot":
		cmdBoot(cfg)
	default:
		log.Fatalf("Unknown command: %s", os.Args[1])
	}
}

func loadConfig() Config {
	data, err := os.ReadFile(configPath)
	if err != nil {
		log.Fatalf("Failed to read config: %v", err)
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		log.Fatalf("Failed to parse config: %v", err)
	}
	return cfg
}

// cmdCheck polls the registry and activates new versions
func cmdCheck(cfg Config, overlayFilter string) {
	registry := fetchRegistry(cfg.RegistryUrl)
	if registry == nil {
		return
	}

	for name, ov := range cfg.Overlays {
		if !ov.Enabled {
			continue
		}
		if overlayFilter != "" && name != overlayFilter {
			continue
		}

		entry, ok := registry[ov.Package]
		if !ok {
			log.Printf("[%s] not found in registry (package: %s)", name, ov.Package)
			continue
		}

		current := loadCurrentState(cfg.StateDir, name)
		if current != nil && current.StorePath == entry.StorePath {
			log.Printf("[%s] up to date (%s)", name, entry.StorePath)
			continue
		}

		log.Printf("[%s] new version available: %s", name, entry.StorePath)
		cmdActivate(cfg, name, entry.StorePath)
	}
}

// cmdActivate runs the activation state machine for one overlay
func cmdActivate(cfg Config, name, storePath string) {
	ov, ok := cfg.Overlays[name]
	if !ok {
		log.Fatalf("[%s] not in config", name)
	}

	stateDir := filepath.Join(cfg.StateDir, name)
	os.MkdirAll(stateDir, 0755)
	writeState(stateDir, "fetching")

	// FETCHING: realize the store path
	log.Printf("[%s] fetching %s", name, storePath)
	if err := realiseStorePath(storePath); err != nil {
		log.Printf("[%s] fetch failed: %v", name, err)
		writeState(stateDir, "idle")
		return
	}

	// VALIDATING: evaluate overlay.nix
	writeState(stateDir, "validating")
	overlayNix := filepath.Join(storePath, "overlay.nix")
	if _, err := os.Stat(overlayNix); err != nil {
		log.Printf("[%s] no overlay.nix at %s", name, overlayNix)
		writeState(stateDir, "idle")
		return
	}

	manifest, err := evalOverlay(storePath, ov.Config)
	if err != nil {
		log.Printf("[%s] eval failed: %v", name, err)
		writeState(stateDir, "idle")
		return
	}

	// PROVISIONING: generate and load systemd units
	writeState(stateDir, "provisioning")
	if err := generateUnits(name, manifest); err != nil {
		log.Printf("[%s] unit generation failed: %v", name, err)
		writeState(stateDir, "idle")
		return
	}

	if err := daemonReload(); err != nil {
		log.Printf("[%s] daemon-reload failed: %v", name, err)
		writeState(stateDir, "idle")
		return
	}

	// Stop old target if running
	stopTarget(name)

	// Start new target
	if err := startTarget(name); err != nil {
		log.Printf("[%s] start failed: %v", name, err)
		writeState(stateDir, "rolling-back")
		rollbackOverlay(cfg, name)
		return
	}

	// PROVISIONAL: health check loop
	writeState(stateDir, "provisional")
	if manifest.Health != nil && manifest.Health.Type != "none" {
		if !runHealthChecks(name, manifest.Health) {
			log.Printf("[%s] health checks failed, rolling back", name)
			writeState(stateDir, "rolling-back")
			rollbackOverlay(cfg, name)
			return
		}
	}

	// PERMANENT: update state, rotate previous, update GC roots and bin symlinks
	writeState(stateDir, "permanent")
	rotatePrevious(stateDir)
	saveCurrentState(stateDir, OverlayState{
		StorePath:   storePath,
		ActivatedAt: time.Now().Unix(),
	})
	updateGCRoot(stateDir, "gc-root-current", storePath)
	updateBinSymlinks(cfg.BinDir, manifest.Bins)

	log.Printf("[%s] activated %s", name, storePath)
}

// cmdRollback restores the previous version of an overlay
func cmdRollback(cfg Config, name string) {
	rollbackOverlay(cfg, name)
}

// cmdStatus shows the state of all overlays
func cmdStatus(cfg Config, jsonOutput bool) {
	type StatusEntry struct {
		Name      string       `json:"name"`
		Package   string       `json:"package"`
		State     string       `json:"state"`
		Current   *OverlayState `json:"current"`
		Previous  *OverlayState `json:"previous"`
		Enabled   bool         `json:"enabled"`
	}

	var entries []StatusEntry
	for name, ov := range cfg.Overlays {
		stateDir := filepath.Join(cfg.StateDir, name)
		entry := StatusEntry{
			Name:     name,
			Package:  ov.Package,
			State:    readState(stateDir),
			Current:  loadCurrentState(cfg.StateDir, name),
			Previous: loadPreviousState(cfg.StateDir, name),
			Enabled:  ov.Enabled,
		}
		entries = append(entries, entry)
	}

	if jsonOutput {
		data, _ := json.MarshalIndent(entries, "", "  ")
		fmt.Println(string(data))
	} else {
		for _, e := range entries {
			sp := "<none>"
			if e.Current != nil {
				sp = e.Current.StorePath
			}
			fmt.Printf("%-20s %-12s %-10s %s\n", e.Name, e.State, enabledStr(e.Enabled), sp)
		}
	}
}

// cmdBoot regenerates systemd units from state dir on startup
func cmdBoot(cfg Config) {
	for name, ov := range cfg.Overlays {
		if !ov.Enabled {
			continue
		}

		current := loadCurrentState(cfg.StateDir, name)
		if current == nil {
			continue
		}

		// Verify store path still exists
		if _, err := os.Stat(current.StorePath); err != nil {
			log.Printf("[%s] store path missing: %s", name, current.StorePath)
			continue
		}

		manifest, err := evalOverlay(current.StorePath, ov.Config)
		if err != nil {
			log.Printf("[%s] boot eval failed: %v", name, err)
			continue
		}

		if err := generateUnits(name, manifest); err != nil {
			log.Printf("[%s] boot unit generation failed: %v", name, err)
			continue
		}

		updateBinSymlinks(cfg.BinDir, manifest.Bins)
		log.Printf("[%s] boot: regenerated units for %s", name, current.StorePath)
	}

	daemonReload()

	// Start all overlay targets
	for name, ov := range cfg.Overlays {
		if !ov.Enabled {
			continue
		}
		if loadCurrentState(cfg.StateDir, name) != nil {
			startTarget(name)
		}
	}
}

// --- Helpers ---

func fetchRegistry(url string) map[string]RegistryEntry {
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		log.Printf("registry fetch failed: %v", err)
		return nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		log.Printf("registry returned %d", resp.StatusCode)
		return nil
	}

	var entries map[string]RegistryEntry
	if err := json.NewDecoder(resp.Body).Decode(&entries); err != nil {
		log.Printf("registry parse failed: %v", err)
		return nil
	}
	return entries
}

func realiseStorePath(storePath string) error {
	cmd := exec.Command("nix-store", "--realise", storePath)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func resolveSecrets(config map[string]string) map[string]string {
	resolved := make(map[string]string, len(config))
	for k, v := range config {
		if strings.HasPrefix(v, "%SECRET:") && strings.HasSuffix(v, "%") {
			resolved[k] = v[len("%SECRET:") : len(v)-1]
		} else {
			resolved[k] = v
		}
	}
	return resolved
}

func evalOverlay(storePath string, config map[string]string) (*OverlayManifest, error) {
	config = resolveSecrets(config)
	// Build the apply expression with config as both top-level args and nested attrset:
	// f { port = "19876"; storePath = "/nix/store/..."; config = { port = "19876"; }; }
	// Top-level for backward compat, config attrset for overlays that prefer it.
	var configInner string
	topLevel := fmt.Sprintf("storePath = %q;", storePath)
	for k, v := range config {
		topLevel += fmt.Sprintf(" %s = %q;", k, v)
		configInner += fmt.Sprintf(" %s = %q;", k, v)
	}
	topLevel += fmt.Sprintf(" config = {%s };", configInner)
	applyExpr := fmt.Sprintf("f: f { %s }", topLevel)

	cmd := exec.Command("nix", "eval", "--json",
		"--file", filepath.Join(storePath, "overlay.nix"),
		"--apply", applyExpr,
	)
	var out strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("nix eval: %w", err)
	}

	var manifest OverlayManifest
	if err := json.Unmarshal([]byte(out.String()), &manifest); err != nil {
		return nil, fmt.Errorf("parse manifest: %w", err)
	}
	return &manifest, nil
}

func generateUnits(name string, manifest *OverlayManifest) error {
	unitDir := "/run/systemd/system"

	// Generate target unit
	targetName := fmt.Sprintf("overlay-%s.target", name)
	targetContent := fmt.Sprintf(`[Unit]
Description=Overlay target for %s
`, name)

	if err := os.WriteFile(filepath.Join(unitDir, targetName), []byte(targetContent), 0644); err != nil {
		return fmt.Errorf("write target: %w", err)
	}

	// Generate service units
	var wantedByTarget []string
	for svcName, svc := range manifest.Services {
		unitName := fmt.Sprintf("overlay-%s-%s.service", name, svcName)
		wantedByTarget = append(wantedByTarget, unitName)

		after := "network.target"
		if len(svc.After) > 0 {
			after = strings.Join(svc.After, " ")
		}

		restart := "on-failure"
		if svc.Restart != "" {
			restart = svc.Restart
		}

		restartSec := 5
		if svc.RestartSec > 0 {
			restartSec = svc.RestartSec
		}

		var envLines string
		for _, env := range svc.Environment {
			envLines += fmt.Sprintf("Environment=%s\n", env)
		}
		for _, envFile := range svc.EnvironmentFile {
			envLines += fmt.Sprintf("EnvironmentFile=%s\n", envFile)
		}

		content := fmt.Sprintf(`[Unit]
Description=Overlay %s - %s
After=%s
PartOf=%s

[Service]
Type=simple
ExecStart=%s
Restart=%s
RestartSec=%d
`, name, svcName, after, targetName, svc.Exec, restart, restartSec)

		if svc.TimeoutStopSec > 0 {
			content += fmt.Sprintf("TimeoutStopSec=%d\n", svc.TimeoutStopSec)
		}
		if svc.User != "" {
			content += fmt.Sprintf("User=%s\n", svc.User)
		}
		if svc.Group != "" {
			content += fmt.Sprintf("Group=%s\n", svc.Group)
		}
		if svc.WorkingDirectory != "" {
			content += fmt.Sprintf("WorkingDirectory=%s\n", svc.WorkingDirectory)
		}
		content += envLines

		if err := os.WriteFile(filepath.Join(unitDir, unitName), []byte(content), 0644); err != nil {
			return fmt.Errorf("write service %s: %w", unitName, err)
		}
	}

	// Update target to want its services
	if len(wantedByTarget) > 0 {
		wantsDir := filepath.Join(unitDir, targetName+".wants")
		os.MkdirAll(wantsDir, 0755)
		for _, unit := range wantedByTarget {
			os.Symlink(filepath.Join(unitDir, unit), filepath.Join(wantsDir, unit))
		}
	}

	return nil
}

func daemonReload() error {
	return exec.Command("systemctl", "daemon-reload").Run()
}

func stopTarget(name string) {
	exec.Command("systemctl", "stop", fmt.Sprintf("overlay-%s.target", name)).Run()
}

func startTarget(name string) error {
	return exec.Command("systemctl", "start", fmt.Sprintf("overlay-%s.target", name)).Run()
}

func runHealthChecks(name string, health *HealthConfig) bool {
	grace := time.Duration(health.Grace) * time.Second
	interval := time.Duration(health.Interval) * time.Second
	stabilize := time.Duration(health.Stabilize) * time.Second

	log.Printf("[%s] health: waiting %s grace period", name, grace)
	time.Sleep(grace)

	consecutiveOK := time.Duration(0)
	start := time.Now()
	maxWait := stabilize + 60*time.Second // safety cap

	for consecutiveOK < stabilize && time.Since(start) < maxWait {
		ok := false
		switch health.Type {
		case "http":
			ok = checkHTTP(health.Endpoint)
		case "tcp":
			ok = checkTCP(health.Endpoint)
		case "exec":
			ok = checkExec(health.Endpoint)
		}

		if ok {
			consecutiveOK += interval
		} else {
			consecutiveOK = 0
		}

		if consecutiveOK < stabilize {
			time.Sleep(interval)
		}
	}

	return consecutiveOK >= stabilize
}

func checkHTTP(endpoint string) bool {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(endpoint)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	return resp.StatusCode >= 200 && resp.StatusCode < 300
}

func checkTCP(endpoint string) bool {
	conn, err := net.DialTimeout("tcp", endpoint, 5*time.Second)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func checkExec(command string) bool {
	cmd := exec.Command("sh", "-c", command)
	return cmd.Run() == nil
}

func rollbackOverlay(cfg Config, name string) {
	stateDir := filepath.Join(cfg.StateDir, name)
	previous := loadPreviousState(cfg.StateDir, name)
	if previous == nil {
		log.Printf("[%s] no previous version to rollback to", name)
		writeState(stateDir, "idle")
		return
	}

	ov := cfg.Overlays[name]
	log.Printf("[%s] rolling back to %s", name, previous.StorePath)

	stopTarget(name)

	manifest, err := evalOverlay(previous.StorePath, ov.Config)
	if err != nil {
		log.Printf("[%s] rollback eval failed: %v", name, err)
		writeState(stateDir, "idle")
		return
	}

	generateUnits(name, manifest)
	daemonReload()
	startTarget(name)
	updateBinSymlinks(cfg.BinDir, manifest.Bins)

	// Restore current to previous
	saveCurrentState(stateDir, *previous)
	updateGCRoot(stateDir, "gc-root-current", previous.StorePath)
	os.Remove(filepath.Join(stateDir, "previous.json"))
	os.Remove(filepath.Join(stateDir, "gc-root-previous"))

	writeState(stateDir, "permanent")
	log.Printf("[%s] rolled back to %s", name, previous.StorePath)
}

func updateBinSymlinks(binDir string, bins []string) {
	os.MkdirAll(binDir, 0755)
	for _, bin := range bins {
		base := filepath.Base(bin)
		link := filepath.Join(binDir, base)
		os.Remove(link)
		if err := os.Symlink(bin, link); err != nil {
			log.Printf("symlink %s -> %s failed: %v", link, bin, err)
		}
	}
}

func updateGCRoot(stateDir, name, storePath string) {
	link := filepath.Join(stateDir, name)
	os.Remove(link)
	os.Symlink(storePath, link)
}

// State file helpers
func writeState(stateDir, state string) {
	os.MkdirAll(stateDir, 0755)
	os.WriteFile(filepath.Join(stateDir, "state"), []byte(state), 0644)
}

func readState(stateDir string) string {
	data, err := os.ReadFile(filepath.Join(stateDir, "state"))
	if err != nil {
		return "idle"
	}
	return strings.TrimSpace(string(data))
}

func loadCurrentState(baseDir, name string) *OverlayState {
	return loadStateFile(filepath.Join(baseDir, name, "current.json"))
}

func loadPreviousState(baseDir, name string) *OverlayState {
	return loadStateFile(filepath.Join(baseDir, name, "previous.json"))
}

func loadStateFile(path string) *OverlayState {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var state OverlayState
	if err := json.Unmarshal(data, &state); err != nil {
		return nil
	}
	return &state
}

func saveCurrentState(stateDir string, state OverlayState) {
	data, _ := json.MarshalIndent(state, "", "  ")
	os.WriteFile(filepath.Join(stateDir, "current.json"), data, 0644)
}

func rotatePrevious(stateDir string) {
	currentPath := filepath.Join(stateDir, "current.json")
	previousPath := filepath.Join(stateDir, "previous.json")

	if _, err := os.Stat(currentPath); err == nil {
		data, _ := os.ReadFile(currentPath)
		os.WriteFile(previousPath, data, 0644)

		// Rotate GC root
		currentRoot := filepath.Join(stateDir, "gc-root-current")
		if target, err := os.Readlink(currentRoot); err == nil {
			previousRoot := filepath.Join(stateDir, "gc-root-previous")
			os.Remove(previousRoot)
			os.Symlink(target, previousRoot)
		}
	}
}

func enabledStr(enabled bool) string {
	if enabled {
		return "enabled"
	}
	return "disabled"
}
