package main

import (
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// The environment verbs (E4-S6). Secret VALUES never travel as a flag or argv
// element (both are visible in shell history and `ps`): `secret set` reads the
// value from stdin or from a named environment variable, and no verb prints a
// value it was given.

const envUsageText = "Usage:\n  foreman project env list [--format=json] <id>\n  foreman project env set [--replace] <id> NAME=value [NAME=value ...]\n  foreman project env unset <id> NAME [NAME ...]"

func environmentPath(projectID string) string {
	return client.JoinPath("/api/projects", projectID, "environment")
}

func getEnvironment(c *client.Client, projectID string) (map[string]any, error) {
	var out map[string]any
	if err := c.GetJSON(environmentPath(projectID), &out); err != nil {
		return nil, err
	}
	return out, nil
}

func putEnvironment(c *client.Client, projectID string, body map[string]any) (map[string]any, error) {
	var out map[string]any
	if err := c.PutJSON(environmentPath(projectID), body, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func projectEnv(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError("foreman project env: missing subcommand (list|set|unset)", envUsageText)
	}

	switch args[0] {
	case "list":
		return projectEnvList(c, args[1:])
	case "set":
		return projectEnvSet(c, args[1:])
	case "unset":
		return projectEnvUnset(c, args[1:])
	default:
		return usageTextError(fmt.Sprintf("foreman project env: unknown subcommand %q", args[0]), envUsageText)
	}
}

func projectEnvList(c *client.Client, args []string) error {
	fs := newFlagSet("project env list")
	format := fs.String("format", "", "Output format (json)")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman project env list: expected one argument: <project-id>")
	}

	out, err := getEnvironment(c, fs.Arg(0))
	if err != nil {
		return err
	}
	if *format == "json" {
		return printJSON(out)
	}

	vars, _ := out["vars"].(map[string]any)
	names := make([]string, 0, len(vars))
	for name := range vars {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		fmt.Printf("%s=%v\n", name, vars[name])
	}
	if legacy, _ := out["legacy_env"].(bool); legacy {
		fmt.Fprintln(os.Stderr, "note: this project uses legacy config.env; values are hidden. `env set --replace` migrates it to the environment record.")
	}
	return nil
}

func currentVars(c *client.Client, projectID string, replace bool) (map[string]any, error) {
	if replace {
		return map[string]any{}, nil
	}

	out, err := getEnvironment(c, projectID)
	if err != nil {
		return nil, err
	}
	if legacy, _ := out["legacy_env"].(bool); legacy {
		vars, _ := out["vars"].(map[string]any)
		if len(vars) > 0 {
			return nil, fmt.Errorf("foreman project env: project %q still uses legacy config.env whose values are hidden; "+
				"pass --replace with every variable to migrate it", projectID)
		}
	}

	vars, _ := out["vars"].(map[string]any)
	if vars == nil {
		vars = map[string]any{}
	}
	return vars, nil
}

func projectEnvSet(c *client.Client, args []string) error {
	fs := newFlagSet("project env set")
	replace := fs.Bool("replace", false, "Start from an empty variable set instead of the current one")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() < 2 {
		return usageError(fs, "foreman project env set: expected <project-id> NAME=value [NAME=value ...]")
	}

	projectID := fs.Arg(0)
	vars, err := currentVars(c, projectID, *replace)
	if err != nil {
		return err
	}

	for _, pair := range fs.Args()[1:] {
		name, value, ok := strings.Cut(pair, "=")
		if !ok || name == "" {
			return usageError(fs, "foreman project env set: %q is not NAME=value", pair)
		}
		vars[name] = value
	}

	if _, err := putEnvironment(c, projectID, map[string]any{"vars": vars}); err != nil {
		return err
	}
	_, err = fmt.Fprintf(os.Stdout, "project %s: %d variable(s) set\n", projectID, len(fs.Args())-1)
	return err
}

func projectEnvUnset(c *client.Client, args []string) error {
	fs := newFlagSet("project env unset")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() < 2 {
		return usageError(fs, "foreman project env unset: expected <project-id> NAME [NAME ...]")
	}

	projectID := fs.Arg(0)
	vars, err := currentVars(c, projectID, false)
	if err != nil {
		return err
	}
	for _, name := range fs.Args()[1:] {
		delete(vars, name)
	}

	if _, err := putEnvironment(c, projectID, map[string]any{"vars": vars}); err != nil {
		return err
	}
	_, err = fmt.Fprintf(os.Stdout, "project %s: %d variable(s) removed\n", projectID, len(fs.Args())-1)
	return err
}

const secretUsageText = "Usage:\n  foreman project secret list [--format=json] <id>\n  foreman project secret set [--from-env VAR] <id> <NAME>   (value read from stdin unless --from-env)\n  foreman project secret unset <id> <NAME>"

func secretPath(projectID, name string) string {
	return client.JoinPath("/api/projects", projectID, "secrets", name)
}

func projectSecret(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError("foreman project secret: missing subcommand (list|set|unset)", secretUsageText)
	}

	switch args[0] {
	case "list":
		return projectSecretList(c, args[1:])
	case "set":
		return projectSecretSet(c, os.Stdin, args[1:])
	case "unset":
		return projectSecretUnset(c, args[1:])
	default:
		return usageTextError(fmt.Sprintf("foreman project secret: unknown subcommand %q", args[0]), secretUsageText)
	}
}

func projectSecretList(c *client.Client, args []string) error {
	fs := newFlagSet("project secret list")
	format := fs.String("format", "", "Output format (json)")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman project secret list: expected one argument: <project-id>")
	}

	out, err := getEnvironment(c, fs.Arg(0))
	if err != nil {
		return err
	}
	secrets, _ := out["secrets"].([]any)
	if *format == "json" {
		return printJSON(secrets)
	}
	for _, item := range secrets {
		secret, _ := item.(map[string]any)
		fmt.Printf("%s\tv%v\t%v\n", secret["name"], secret["version"], secret["updated_at"])
	}
	return nil
}

func projectSecretSet(c *client.Client, stdin io.Reader, args []string) error {
	fs := newFlagSet("project secret set")
	fromEnv := fs.String("from-env", "", "Read the value from this environment variable instead of stdin")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 2 {
		return usageError(fs, "foreman project secret set: expected <project-id> <NAME> (the value is never a flag or argument)")
	}

	var value string
	if *fromEnv != "" {
		value = os.Getenv(*fromEnv)
		if value == "" {
			return fmt.Errorf("foreman project secret set: environment variable %s is empty or unset", *fromEnv)
		}
	} else {
		raw, err := io.ReadAll(stdin)
		if err != nil {
			return fmt.Errorf("foreman project secret set: read stdin: %w", err)
		}
		value = strings.TrimRight(string(raw), "\r\n")
		if value == "" {
			return fmt.Errorf("foreman project secret set: no value on stdin")
		}
	}

	var out map[string]any
	if err := c.PutJSON(secretPath(fs.Arg(0), fs.Arg(1)), map[string]any{"value": value}, &out); err != nil {
		return err
	}
	_, err := fmt.Fprintf(os.Stdout, "secret %s set on project %s (version %v)\n", fs.Arg(1), fs.Arg(0), out["version"])
	return err
}

func projectSecretUnset(c *client.Client, args []string) error {
	fs := newFlagSet("project secret unset")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 2 {
		return usageError(fs, "foreman project secret unset: expected <project-id> <NAME>")
	}

	if err := c.Delete(secretPath(fs.Arg(0), fs.Arg(1)), nil); err != nil {
		return err
	}
	_, err := fmt.Fprintf(os.Stdout, "secret %s removed from project %s\n", fs.Arg(1), fs.Arg(0))
	return err
}

const setupScriptUsageText = "Usage:\n  foreman project setup-script show <id>\n  foreman project setup-script set --file <path> <id>\n  foreman project setup-script clear <id>"

func projectSetupScript(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError("foreman project setup-script: missing subcommand (show|set|clear)", setupScriptUsageText)
	}

	fs := newFlagSet("project setup-script " + args[0])
	file := fs.String("file", "", "Path of the script to install (set)")
	if err := fs.parse(args[1:]); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman project setup-script %s: expected one argument: <project-id>", args[0])
	}
	projectID := fs.Arg(0)

	switch args[0] {
	case "show":
		out, err := getEnvironment(c, projectID)
		if err != nil {
			return err
		}
		if script, ok := out["setup_script"].(string); ok {
			fmt.Print(script)
			if !strings.HasSuffix(script, "\n") {
				fmt.Println()
			}
		} else {
			fmt.Println("(no setup script)")
		}
		return nil
	case "set":
		if *file == "" {
			return usageError(fs, "foreman project setup-script set: --file is required")
		}
		text, err := os.ReadFile(*file)
		if err != nil {
			return fmt.Errorf("foreman project setup-script set: %w", err)
		}
		if _, err := putEnvironment(c, projectID, map[string]any{"setup_script": string(text)}); err != nil {
			return err
		}
		_, err = fmt.Fprintf(os.Stdout, "project %s: setup script installed (%d bytes)\n", projectID, len(text))
		return err
	case "clear":
		if _, err := putEnvironment(c, projectID, map[string]any{"setup_script": nil}); err != nil {
			return err
		}
		_, err := fmt.Fprintf(os.Stdout, "project %s: setup script cleared\n", projectID)
		return err
	default:
		return usageTextError(fmt.Sprintf("foreman project setup-script: unknown subcommand %q", args[0]), setupScriptUsageText)
	}
}

const networkUsageText = "Usage:\n  foreman project network show <id>\n  foreman project network set --mode default|none|allowlist [--allow host ...] <id>\n(enforced on docker jobsites only; the workflow door runs on the server host)"

func projectNetwork(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError("foreman project network: missing subcommand (show|set)", networkUsageText)
	}

	fs := newFlagSet("project network " + args[0])
	mode := fs.String("mode", "", "Network mode: default, none or allowlist")
	var allow repeatedFlag
	fs.Var(&allow, "allow", "Allowed host (repeatable; allowlist mode)")
	if err := fs.parse(args[1:]); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman project network %s: expected one argument: <project-id>", args[0])
	}
	projectID := fs.Arg(0)

	switch args[0] {
	case "show":
		out, err := getEnvironment(c, projectID)
		if err != nil {
			return err
		}
		return printJSON(map[string]any{"network": out["network"], "network_enforced_on": out["network_enforced_on"]})
	case "set":
		if *mode == "" {
			return usageError(fs, "foreman project network set: --mode is required")
		}
		hosts := []string(allow)
		if hosts == nil {
			hosts = []string{}
		}
		body := map[string]any{"network": map[string]any{"mode": *mode, "hosts": hosts}}
		if _, err := putEnvironment(c, projectID, body); err != nil {
			return err
		}
		_, err := fmt.Fprintf(os.Stdout, "project %s: network policy %s\n", projectID, *mode)
		return err
	default:
		return usageTextError(fmt.Sprintf("foreman project network: unknown subcommand %q", args[0]), networkUsageText)
	}
}
