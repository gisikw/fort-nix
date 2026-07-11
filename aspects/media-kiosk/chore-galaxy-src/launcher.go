package main

// Launch is the backend's job (INVARIANTS 11): the frontend requests an app
// id; the backend maps it to an exec spec from launchers.json and manages the
// child process. The child runs in its own session (Setsid), so a backend
// restart never kills a running game — crash-only both ways. When the child
// exits, "playing" clears and the kiosk (which never stopped serving) is
// simply there again.

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

type LaunchSpec struct {
	Argv []string `json:"argv"`
	Env  []string `json:"env,omitempty"`
	Dir  string   `json:"dir,omitempty"`
}

func (st *Store) loadLaunchers() error {
	raw, err := os.ReadFile(st.launcherPath())
	if os.IsNotExist(err) {
		if st.dev {
			// Dev convenience: synthesize a harmless launcher per app so the
			// launch path is exercisable without host-specific commands.
			st.launchers = map[string]*LaunchSpec{}
			for _, p := range st.state.Planets {
				for _, a := range p.Apps {
					st.launchers[a.ID] = &LaunchSpec{Argv: []string{"sh", "-c", "sleep 3"}}
				}
			}
			data, _ := json.MarshalIndent(st.launchers, "", "  ")
			return os.WriteFile(st.launcherPath(), append(data, '\n'), 0o644)
		}
		log.Printf("WARNING: %s not found — no apps are launchable until it exists", st.launcherPath())
		st.launchers = map[string]*LaunchSpec{}
		return nil
	}
	if err != nil {
		return err
	}
	st.launchers = map[string]*LaunchSpec{}
	if err := json.Unmarshal(raw, &st.launchers); err != nil {
		return fmt.Errorf("parse %s: %w", st.launcherPath(), err)
	}
	for id, spec := range st.launchers {
		if spec == nil || len(spec.Argv) == 0 {
			return fmt.Errorf("%s: launcher %q has no argv", st.launcherPath(), id)
		}
	}
	return nil
}

// Launch validates and spawns. One app at a time: the TV is one screen.
func (st *Store) Launch(kidID, appID string) error {
	return st.Mutate(func() ([]Event, error) {
		if st.state.findKid(kidID) == nil {
			return nil, errNotFound("unknown kid %q", kidID)
		}
		planet, app := st.state.findApp(appID)
		if app == nil {
			return nil, errNotFound("unknown app %q", appID)
		}
		if app.State != appReady {
			return nil, errConflict("app %q is %s, not ready", appID, app.State)
		}
		if st.playing != nil {
			return nil, errConflict("%q is already playing", st.playing.Name)
		}
		spec := st.launchers[appID]
		if spec == nil {
			return nil, errConflict("no launcher configured for %q", appID)
		}

		cmd := exec.Command(spec.Argv[0], spec.Argv[1:]...)
		cmd.Env = append(os.Environ(), spec.Env...)
		cmd.Dir = spec.Dir
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		logf, err := os.OpenFile(filepath.Join(st.dir, "launch.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err == nil {
			fmt.Fprintf(logf, "\n--- %s launch %s: %v\n", st.now().Format("2006-01-02T15:04:05"), appID, spec.Argv)
			cmd.Stdout, cmd.Stderr = logf, logf
		}
		if err := cmd.Start(); err != nil {
			if logf != nil {
				logf.Close()
			}
			return nil, errConflict("launch %q failed: %v", appID, err)
		}
		st.playing = &Playing{App: app.ID, Name: app.Name, Icon: app.Icon, Kid: kidID, PID: cmd.Process.Pid}
		go st.reap(cmd, app.ID, logf)
		return []Event{{
			Type: "launch", Kid: kidID, Planet: planet.ID, App: app.ID,
			Note: fmt.Sprintf("pid %d: %v", cmd.Process.Pid, spec.Argv),
		}}, nil
	})
}

// StopApp (management plane) terminates the running app. The child was
// started with Setsid, so its pid is its process-group id: signal the whole
// group (-pid) to catch wrapper scripts, by exact pid — never by name. The
// reap goroutine observes the exit and does the app_exit bookkeeping.
func (st *Store) StopApp() error {
	return st.Mutate(func() ([]Event, error) {
		if st.playing == nil {
			return nil, errConflict("nothing is playing")
		}
		if err := syscall.Kill(-st.playing.PID, syscall.SIGTERM); err != nil {
			return nil, errConflict("stop %q (pid %d): %v", st.playing.App, st.playing.PID, err)
		}
		return []Event{{
			Type: "app_stop", App: st.playing.App,
			Note: fmt.Sprintf("SIGTERM to pgid %d", st.playing.PID),
		}}, nil
	})
}

// reap waits for the child, clears "playing", and broadcasts so the kiosk
// drops its launch overlay the moment the app exits.
func (st *Store) reap(cmd *exec.Cmd, appID string, logf *os.File) {
	err := cmd.Wait()
	if logf != nil {
		logf.Close()
	}
	note := "exited"
	if err != nil {
		note = fmt.Sprintf("exited: %v", err)
	}
	merr := st.Mutate(func() ([]Event, error) {
		if st.playing != nil && st.playing.App == appID {
			st.playing = nil
		}
		return []Event{{Type: "app_exit", App: appID, Note: note}}, nil
	})
	if merr != nil {
		log.Printf("recording app exit for %q failed: %v", appID, merr)
	}
}
