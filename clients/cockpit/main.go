package main

import (
	"fmt"
	"os"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"
)

// Foreman cockpit — Bubble Tea POC.
//
// Standalone by default (mock data). To point it at a running Elixir server:
//
//	FOREMAN_SERVER_URL=http://127.0.0.1:4766 \
//	FOREMAN_SERVER_AUTH_TOKEN=... \
//	go run .
//
// nvim open mode is controlled by $NVIM (remote socket, auto-detected) and
// $EDITOR; see docs/design/cockpit-ui-spec.md for the config surface.
func main() {
	c := clientFromEnv()
	cfg, cfgErr := loadConfig(".foreman/config.yaml")
	if installThemesRequested(os.Args[1:]) {
		if err := installThemeFragments(os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}

	if dumpRequested(os.Args[1:], os.Getenv("COCKPIT_DUMP")) {
		if err := dumpClient(c); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}

	if err := ensureTTY(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	m := newModelWithConfig(c, cfg, defaultTools)
	if cfgErr != nil {
		m.notice = "config: " + cfgErr.Error()
	}
	p := tea.NewProgram(m, programOptionsFromEnv(os.Getenv("COCKPIT_DEMO"))...)
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "cockpit error:", err)
		os.Exit(1)
	}
}

func programOptionsFromEnv(demo string) []tea.ProgramOption {
	if demo != "1" && !strings.EqualFold(demo, "true") {
		return nil
	}
	return []tea.ProgramOption{
		tea.WithWindowSize(120, 32),
		tea.WithColorProfile(colorprofile.TrueColor),
	}
}

const defaultServerURL = "http://127.0.0.1:4766"

func clientFromEnv() Client {
	return clientForConfig(os.Getenv("FOREMAN_SERVER_URL"), os.Getenv("FOREMAN_SERVER_AUTH_TOKEN"), os.Getenv("COCKPIT_BACKEND"))
}

func clientForConfig(base, token, backend string) Client {
	if strings.EqualFold(backend, "mock") {
		return NewMockClient()
	}
	if base == "" {
		base = defaultServerURL
	}
	return NewHTTPClient(base, token)
}
func ensureTTY() error {
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		return fmt.Errorf("cockpit requires an interactive TTY; run it from a terminal or set COCKPIT_DUMP=1 for a live backend snapshot")
	}
	_ = tty.Close()
	return nil
}

func dumpRequested(args []string, env string) bool {
	if env == "1" || strings.EqualFold(env, "true") {
		return true
	}
	for _, arg := range args {
		if arg == "--dump" {
			return true
		}
	}
	return false
}

func dumpClient(c Client) error {
	runs := c.Runs()
	tasks := c.Dispatchable()
	if errors := c.DrainErrors(); len(errors) > 0 {
		return fmt.Errorf("cockpit live backend errors: %s", strings.Join(errors, " · "))
	}

	running, recent := 0, 0
	for _, run := range runs {
		switch run.Group {
		case "RUNNING":
			running++
		case "RECENT":
			recent++
		}
	}
	fmt.Printf("runs=%d running=%d recent=%d ready=%d\n", len(runs), running, recent, len(tasks))
	if len(runs) == 0 {
		return nil
	}

	run := runs[0]
	msgs := c.Messages(run.RunID)
	events := c.Events(run.RunID)
	logs := c.Logs(run.RunID)
	reports := c.Reports(run.RunID)
	if errors := c.DrainErrors(); len(errors) > 0 {
		fmt.Printf("detail_errors=%s\n", strings.Join(errors, " · "))
	}
	fmt.Printf("first_run=%s task=%s status=%s phase=%s messages=%d events=%d logs=%d reports=%d\n",
		run.RunID, run.TaskID, run.Status, run.Phase, len(msgs), len(events), len(logs), len(reports))
	return nil
}
