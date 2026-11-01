package main

import (
	"errors"
	"fmt"
	"net/url"
	"os/exec"
	"runtime"
	"strings"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// openBrowser hands a URL to the user's default browser. It is a variable so tests can replace
// it; nothing in the test suite may launch a real browser.
var openBrowser = defaultOpenBrowser

// projectOpen implements `foreman project open <project-id>`: it opens the project's browser
// workspace (/dashboard/projects/<id>) in the default browser.
//
// Every /dashboard route requires authentication and a browser navigation cannot send an
// Authorization header, so the opened URL carries the API token as `?token=`. The token is
// therefore in the URL (the opener's argv, then the browser's address bar and history) but it
// must never reach stdout, stderr or any error text this command produces.
func projectOpen(c *client.Client, args []string) error {
	fs := newFlagSet("project open")
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 1 {
		return usageError(fs, "foreman project open: expected one argument: <project-id>")
	}

	id := fs.Arg(0)

	if c.Token == "" {
		return errors.New("foreman project open: FOREMAN_API_TOKEN is not set; the browser workspace has no unauthenticated mode, so there is nothing to open")
	}

	// Prove the project exists and the API accepts the token before launching anything. This
	// does not prove the dashboard accepts the token (a server with no token configured serves
	// /api open in dev but answers 401 on /dashboard).
	var out map[string]any
	if err := c.GetJSON(client.JoinPath("/api/projects", id), &out); err != nil {
		return err
	}

	workspace := strings.TrimRight(c.BaseURL, "/") + "/dashboard/projects/" + url.PathEscape(id)

	if err := openBrowser(workspace + "?token=" + url.QueryEscape(c.Token)); err != nil {
		return fmt.Errorf("foreman project open: could not launch a browser (open %s with ?token=<FOREMAN_API_TOKEN> yourself): %w", workspace, err)
	}

	fmt.Printf("opened %s in your browser (token from FOREMAN_API_TOKEN, not printed)\n", workspace)

	return nil
}

// defaultOpenBrowser starts the OS URL opener and returns without waiting for it, so a browser
// that stays attached to its opener cannot hang the CLI. Errors name the opener binary only:
// the URL (which carries the token) is never formatted into them.
func defaultOpenBrowser(target string) error {
	var cmd *exec.Cmd

	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", target)
	case "linux":
		cmd = exec.Command("xdg-open", target)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", target)
	default:
		return fmt.Errorf("no browser opener known for %s", runtime.GOOS)
	}

	if err := cmd.Start(); err != nil {
		return err
	}

	// Reap the opener in the background so it does not linger as a zombie while we run.
	go func() { _ = cmd.Wait() }()

	return nil
}
