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
	"sort"
	"strings"
	"time"
)

// Config loaded from /etc/fort/overlays.json
type Config struct {
	RegistryUrl  string                   `json:"registryUrl"`
	PollInterval string                   `json:"pollInterval"`
	StateDir     string                   `json:"stateDir"`
	BinDir       string                   `json:"binDir"`
	Overlays     map[string]OverlayConfig `json:"overlays"`
}

type OverlayConfig struct {
	Package   string            `json:"package"`
	Config    map[string]string `json:"config"`
	Enabled   bool              `json:"enabled"`
	DependsOn []string          `json:"dependsOn"`
}

// Registry entry from the overlay-registry service
type RegistryEntry struct {
	StorePath string `json:"storePath"`
	UpdatedAt int64  `json:"updatedAt"`
}

// Persisted state per overlay
type OverlayState struct {
	StorePath    string `json:"storePath"`
	ActivatedAt  int64  `json:"activatedAt"`
	ManifestHash string `json:"manifestHash"`
}

// AttemptRecord is the last activation attempt for an overlay that did not
// reach a healthy permanent state. It exists so the manager can remember that
// it already tried a specific store path and failed: without it, every check
// cycle rediscovers the same "new" version and retries it forever.
type AttemptRecord struct {
	StorePath string `json:"storePath"`
	State     string `json:"state"`
	Reason    string `json:"reason"`
	At        int64  `json:"at"`
	Attempts  int    `json:"attempts"`
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
	DynamicUser      bool     `json:"dynamicUser"`
	StateDirectory   string   `json:"stateDirectory"`
	WorkingDirectory string   `json:"workingDirectory"`
	After            []string `json:"after"`
	Restart          string   `json:"restart"`
	RestartSec       int      `json:"restartSec"`
	TimeoutStopSec   int      `json:"timeoutStopSec"`
	Drain            string   `json:"drain"`
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

// orderedOverlays returns overlay names with declared dependencies before
// their dependents, so a dependency activates before anything that needs it.
// Deterministic (ties broken by name). Deps not declared on this host are
// ignored here — the nix side rejects them at eval time. A dependency cycle
// is broken deterministically with a logged warning rather than failing the
// whole run.
func orderedOverlays(overlays map[string]OverlayConfig) []string {
	names := make([]string, 0, len(overlays))
	for name := range overlays {
		names = append(names, name)
	}
	sort.Strings(names)

	order := make([]string, 0, len(names))
	state := map[string]int{} // 0 = unvisited, 1 = visiting, 2 = done
	var visit func(string)
	visit = func(name string) {
		switch state[name] {
		case 1:
			log.Printf("[%s] dependency cycle detected, activation order not guaranteed", name)
			return
		case 2:
			return
		}
		state[name] = 1
		deps := append([]string(nil), overlays[name].DependsOn...)
		sort.Strings(deps)
		for _, dep := range deps {
			if _, ok := overlays[dep]; ok {
				visit(dep)
			}
		}
		state[name] = 2
		order = append(order, name)
	}
	for _, name := range names {
		visit(name)
	}
	return order
}

// cmdCheck polls the registry and activates new versions
func cmdCheck(cfg Config, overlayFilter string) {
	registry := fetchRegistry(cfg.RegistryUrl)
	if registry == nil {
		return
	}

	// Dependency order: a new version of a dependency lands before its
	// dependents are (re)activated in the same check cycle.
	for _, name := range orderedOverlays(cfg.Overlays) {
		ov := cfg.Overlays[name]
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
			if _, err := os.Stat(current.StorePath); err == nil {
				log.Printf("[%s] up to date (%s)", name, entry.StorePath)
				continue
			}
			log.Printf("[%s] store path missing, re-fetching: %s", name, current.StorePath)
		}

		// A store path that already failed activation is not retried on every
		// poll: back off exponentially so a permanently broken version cannot
		// thrash its services indefinitely. An explicit `activate` bypasses this.
		if attempt := loadAttempt(cfg.StateDir, name); attempt != nil && attempt.StorePath == entry.StorePath {
			if wait := backoffRemaining(attempt, cfg.PollInterval); wait > 0 {
				log.Printf("[%s] skipping %s: %s after %d attempt(s) (%s); next retry in %s",
					name, entry.StorePath, attempt.State, attempt.Attempts, attempt.Reason, wait.Round(time.Second))
				continue
			}
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
		failActivation(stateDir, name, storePath, "fetch failed: %v", err)
		return
	}

	// VALIDATING: evaluate overlay.nix
	writeState(stateDir, "validating")
	overlayNix := filepath.Join(storePath, "overlay.nix")
	if _, err := os.Stat(overlayNix); err != nil {
		failActivation(stateDir, name, storePath, "no overlay.nix at %s", overlayNix)
		return
	}

	manifest, err := evalOverlay(storePath, ov.Config)
	if err != nil {
		failActivation(stateDir, name, storePath, "eval failed: %v", err)
		return
	}

	// PROVISIONING: generate and load systemd units
	ensureDataDirOwnership(name, ov.Config, manifest)
	writeState(stateDir, "provisioning")
	if err := generateUnits(name, manifest, ov.DependsOn); err != nil {
		failActivation(stateDir, name, storePath, "unit generation failed: %v", err)
		return
	}

	if err := daemonReload(); err != nil {
		failActivation(stateDir, name, storePath, "daemon-reload failed: %v", err)
		return
	}

	// Stop old services explicitly — systemctl stop on a service is
	// synchronous (waits for drain + exit), whereas stopping the target
	// only deactivates a grouping unit and propagates asynchronously.
	stopServices(name, manifest)

	// Start new target (brings up all wanted services)
	if err := startTarget(name); err != nil {
		log.Printf("[%s] start failed: %v", name, err)
		writeState(stateDir, "rolling-back")
		rollbackOverlay(cfg, name, storePath, fmt.Sprintf("start failed: %v", err))
		return
	}

	// PROVISIONAL: health check loop
	writeState(stateDir, "provisional")
	if manifest.Health != nil && manifest.Health.Type != "none" {
		if !runHealthChecks(name, manifest.Health) {
			log.Printf("[%s] health checks failed, rolling back", name)
			writeState(stateDir, "rolling-back")
			rollbackOverlay(cfg, name, storePath, "health checks failed")
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
	clearAttempt(stateDir)

	log.Printf("[%s] activated %s", name, storePath)
}

// cmdRollback restores the previous version of an overlay
func cmdRollback(cfg Config, name string) {
	rollbackOverlay(cfg, name, "", "operator-initiated rollback")
}

// cmdStatus shows the state of all overlays
func cmdStatus(cfg Config, jsonOutput bool) {
	type StatusEntry struct {
		Name        string         `json:"name"`
		Package     string         `json:"package"`
		State       string         `json:"state"`
		Current     *OverlayState  `json:"current"`
		Previous    *OverlayState  `json:"previous"`
		LastAttempt *AttemptRecord `json:"lastAttempt"`
		Enabled     bool           `json:"enabled"`
	}

	var entries []StatusEntry
	for name, ov := range cfg.Overlays {
		stateDir := filepath.Join(cfg.StateDir, name)
		entry := StatusEntry{
			Name:        name,
			Package:     ov.Package,
			State:       readState(stateDir),
			Current:     loadCurrentState(cfg.StateDir, name),
			Previous:    loadPreviousState(cfg.StateDir, name),
			LastAttempt: loadAttempt(cfg.StateDir, name),
			Enabled:     ov.Enabled,
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
			if a := e.LastAttempt; a != nil {
				fmt.Printf("%-20s   last attempt x%d %s: %s (%s)\n", "", a.Attempts, a.State, a.Reason, a.StorePath)
			}
		}
	}
}

// cmdBoot regenerates systemd units from state dir on startup
func cmdBoot(cfg Config) {
	bootOrder := orderedOverlays(cfg.Overlays)

	for _, name := range bootOrder {
		ov := cfg.Overlays[name]
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

		ensureDataDirOwnership(name, ov.Config, manifest)

		if err := generateUnits(name, manifest, ov.DependsOn); err != nil {
			log.Printf("[%s] boot unit generation failed: %v", name, err)
			continue
		}

		updateBinSymlinks(cfg.BinDir, manifest.Bins)
		stateDir := filepath.Join(cfg.StateDir, name)
		updateGCRoot(stateDir, "gc-root-current", current.StorePath)
		log.Printf("[%s] boot: regenerated units for %s", name, current.StorePath)
	}

	daemonReload()

	// Start all overlay targets, dependencies first (the generated After=
	// ordering makes systemd enforce this too; starting in order keeps the
	// synchronous start calls from racing it)
	for _, name := range bootOrder {
		ov := cfg.Overlays[name]
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

// serviceUnitName returns the systemd unit for an overlay service. When the
// service is named after its overlay (the common single-service case) the
// name is flattened to overlay-<name>.service — the overlay-tiamat-tiamat
// double prefix was reliably confusing (q-b5f9ad4b). Overlays with distinct
// service names keep the namespaced overlay-<overlay>-<service>.service form
// so services from different overlays can never collide.
func serviceUnitName(overlay, service string) string {
	if service == overlay {
		return fmt.Sprintf("overlay-%s.service", overlay)
	}
	return fmt.Sprintf("overlay-%s-%s.service", overlay, service)
}

// legacyServiceUnitName is the pre-flattening name. Used only to migrate:
// stop and remove units written by an older manager version.
func legacyServiceUnitName(overlay, service string) string {
	return fmt.Sprintf("overlay-%s-%s.service", overlay, service)
}

func generateUnits(name string, manifest *OverlayManifest, dependsOn []string) error {
	unitDir := "/run/systemd/system"

	// Generate target unit. Declared overlay dependencies become Wants= +
	// After= on the target: starting this overlay pulls its dependencies in,
	// and target units implicitly order After= their own Wants=, so a
	// dependency's services have started before this target activates.
	targetName := fmt.Sprintf("overlay-%s.target", name)
	targetContent := fmt.Sprintf(`[Unit]
Description=Overlay target for %s
`, name)
	for _, dep := range dependsOn {
		targetContent += fmt.Sprintf("Wants=overlay-%s.target\nAfter=overlay-%s.target\n", dep, dep)
	}

	if err := os.WriteFile(filepath.Join(unitDir, targetName), []byte(targetContent), 0644); err != nil {
		return fmt.Errorf("write target: %w", err)
	}

	// Generate service units
	var wantedByTarget []string
	for svcName, svc := range manifest.Services {
		unitName := serviceUnitName(name, svcName)
		wantedByTarget = append(wantedByTarget, unitName)

		// Migrate away from the pre-flattening unit name: a leftover unit
		// file means an older manager version may still have that unit
		// running — stop it before removing so the renamed unit doesn't
		// double-run (port conflicts), then drop its wants symlink.
		if legacy := legacyServiceUnitName(name, svcName); legacy != unitName {
			legacyPath := filepath.Join(unitDir, legacy)
			if _, err := os.Stat(legacyPath); err == nil {
				log.Printf("[%s] migrating unit %s -> %s", name, legacy, unitName)
				exec.Command("systemctl", "stop", legacy).Run()
				os.Remove(legacyPath)
				os.Remove(filepath.Join(unitDir, targetName+".wants", legacy))
			}
		}

		after := "network.target"
		if len(svc.After) > 0 {
			after = strings.Join(svc.After, " ")
		}
		// Order each service after dependency targets too: a service's own
		// start job is not ordered by its target's After=, only the target is.
		for _, dep := range dependsOn {
			after += fmt.Sprintf(" overlay-%s.target", dep)
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
		if svc.DynamicUser {
			content += "DynamicUser=true\n"
		} else if svc.User != "" {
			content += fmt.Sprintf("User=%s\n", svc.User)
		}
		if svc.Group != "" && !svc.DynamicUser {
			content += fmt.Sprintf("Group=%s\n", svc.Group)
		}
		if svc.StateDirectory != "" {
			content += fmt.Sprintf("StateDirectory=%s\n", svc.StateDirectory)
		}
		if svc.WorkingDirectory != "" {
			content += fmt.Sprintf("WorkingDirectory=%s\n", svc.WorkingDirectory)
		}
		// Drain hook (q-9f7a3b5b): ExecStop runs the drain command while the
		// service is still up; remaining processes are signalled only after
		// it exits (bounded by TimeoutStopSec). The running unit file carries
		// its own version's drain command, so replace and rollback both drain
		// with the definition that matches the running binary.
		if svc.Drain != "" {
			content += fmt.Sprintf("ExecStop=%s\n", svc.Drain)
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

func stopServices(name string, manifest *OverlayManifest) {
	for svcName := range manifest.Services {
		units := []string{serviceUnitName(name, svcName)}
		// Belt-and-braces: also stop the pre-flattening name in case a unit
		// from an older manager version is still loaded.
		if legacy := legacyServiceUnitName(name, svcName); legacy != units[0] {
			units = append(units, legacy)
		}
		for _, unit := range units {
			log.Printf("[%s] stopping %s", name, unit)
			if err := exec.Command("systemctl", "stop", unit).Run(); err != nil {
				log.Printf("[%s] stop %s: %v (may not have been running)", name, unit, err)
			}
		}
	}
	// Also deactivate the target so startTarget sees a clean state
	stopTarget(name)
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

// ensureDataDirOwnership chowns the overlay's data directory tree to the
// configured user:group. Prevents ownership drift when a deploy changes
// the overlay's user/group (e.g. root → grotto) while files on disk retain
// the old owner.
func ensureDataDirOwnership(name string, config map[string]string, manifest *OverlayManifest) {
	// Find the data directory from overlay config
	dataDir := config["dataDir"]
	if dataDir == "" {
		dataDir = config["home"]
	}
	if dataDir == "" {
		return
	}

	// Find user/group from service definitions
	var user, group string
	for _, svc := range manifest.Services {
		if svc.User != "" {
			user = svc.User
			group = svc.Group
			break
		}
	}
	if user == "" {
		return
	}
	if group == "" {
		group = user
	}

	// Verify the directory exists before attempting chown
	if _, err := os.Stat(dataDir); err != nil {
		log.Printf("[%s] dataDir %s does not exist, skipping ownership check", name, dataDir)
		return
	}

	log.Printf("[%s] ensuring %s is owned by %s:%s", name, dataDir, user, group)
	cmd := exec.Command("chown", "-R", fmt.Sprintf("%s:%s", user, group), dataDir)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		log.Printf("[%s] chown %s failed: %v", name, dataDir, err)
	}
}

// rollbackOverlay restores the previous version of an overlay. failedPath and
// reason describe the activation that triggered the rollback; they are recorded
// so a later check cycle knows that path was already tried and lost.
//
// A successful rollback ends in "rolled-back", not "permanent": the services are
// running, but deliberately not running what the registry advertises, and those
// two situations must not be indistinguishable from the outside.
func rollbackOverlay(cfg Config, name, failedPath, reason string) {
	stateDir := filepath.Join(cfg.StateDir, name)
	previous := loadPreviousState(cfg.StateDir, name)
	if previous == nil {
		log.Printf("[%s] no previous version to rollback to", name)
		if failedPath != "" {
			recordAttempt(stateDir, failedPath, "failed", reason+"; no previous version to roll back to")
		}
		writeState(stateDir, "failed")
		return
	}

	ov := cfg.Overlays[name]
	log.Printf("[%s] rolling back to %s", name, previous.StorePath)

	stopTarget(name)

	manifest, err := evalOverlay(previous.StorePath, ov.Config)
	if err != nil {
		log.Printf("[%s] rollback eval failed: %v", name, err)
		if failedPath != "" {
			recordAttempt(stateDir, failedPath, "failed", fmt.Sprintf("%s; rollback eval failed: %v", reason, err))
		}
		writeState(stateDir, "failed")
		return
	}

	generateUnits(name, manifest, ov.DependsOn)
	daemonReload()
	startTarget(name)
	updateBinSymlinks(cfg.BinDir, manifest.Bins)

	// Restore current to previous
	saveCurrentState(stateDir, *previous)
	updateGCRoot(stateDir, "gc-root-current", previous.StorePath)
	os.Remove(filepath.Join(stateDir, "previous.json"))
	os.Remove(filepath.Join(stateDir, "gc-root-previous"))

	if failedPath != "" {
		recordAttempt(stateDir, failedPath, "rolled-back", reason)
	} else {
		clearAttempt(stateDir)
	}
	writeState(stateDir, "rolled-back")
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
	cmd := exec.Command("nix-store", "--realise", "--add-root", link, "--indirect", storePath)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		log.Printf("gc root registration failed for %s: %v", link, err)
		os.Symlink(storePath, link)
	}
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
			cmd := exec.Command("nix-store", "--realise", "--add-root", previousRoot, "--indirect", target)
			cmd.Stdout = os.Stderr
			cmd.Stderr = os.Stderr
			if err := cmd.Run(); err != nil {
				log.Printf("gc root rotation failed for %s: %v", previousRoot, err)
				os.Symlink(target, previousRoot)
			}
		}
	}
}

// failActivation records a terminal activation failure: both the reason and the
// store path that caused it go to disk. Recording the attempted path is what
// lets the next check cycle recognise a known-bad version instead of treating
// it as new work.
func failActivation(stateDir, name, storePath, format string, args ...interface{}) {
	reason := fmt.Sprintf(format, args...)
	log.Printf("[%s] %s", name, reason)
	recordAttempt(stateDir, storePath, "failed", reason)
	writeState(stateDir, "failed")
}

// recordAttempt persists the outcome of an activation that did not end
// permanent. Repeated failures against the same store path increment the
// counter that drives retry backoff; a different path resets it.
func recordAttempt(stateDir, storePath, state, reason string) {
	attempts := 1
	if prev := loadAttemptFile(filepath.Join(stateDir, "last-attempt.json")); prev != nil && prev.StorePath == storePath {
		attempts = prev.Attempts + 1
	}
	rec := AttemptRecord{
		StorePath: storePath,
		State:     state,
		Reason:    reason,
		At:        time.Now().Unix(),
		Attempts:  attempts,
	}
	data, _ := json.MarshalIndent(rec, "", "  ")
	os.MkdirAll(stateDir, 0755)
	os.WriteFile(filepath.Join(stateDir, "last-attempt.json"), data, 0644)
}

func clearAttempt(stateDir string) {
	os.Remove(filepath.Join(stateDir, "last-attempt.json"))
}

func loadAttempt(baseDir, name string) *AttemptRecord {
	return loadAttemptFile(filepath.Join(baseDir, name, "last-attempt.json"))
}

func loadAttemptFile(path string) *AttemptRecord {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var rec AttemptRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return nil
	}
	return &rec
}

const maxRetryBackoff = 6 * time.Hour

// backoffRemaining reports how long to keep skipping a store path that already
// failed. The delay doubles per attempt from the poll interval up to a six-hour
// ceiling, so a permanently broken version settles into a few retries a day
// instead of one every poll — while a transient failure still recovers on its
// own without operator involvement.
func backoffRemaining(attempt *AttemptRecord, pollInterval string) time.Duration {
	base, err := time.ParseDuration(pollInterval)
	if err != nil || base <= 0 {
		base = 5 * time.Minute
	}

	delay := base
	for i := 1; i < attempt.Attempts && delay < maxRetryBackoff; i++ {
		delay *= 2
	}
	if delay > maxRetryBackoff {
		delay = maxRetryBackoff
	}

	elapsed := time.Since(time.Unix(attempt.At, 0))
	if elapsed >= delay {
		return 0
	}
	return delay - elapsed
}

func enabledStr(enabled bool) string {
	if enabled {
		return "enabled"
	}
	return "disabled"
}
