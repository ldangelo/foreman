package main

import (
	"fmt"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

func runRun(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError(
			"foreman run: missing subcommand (get)",
			"Usage:\n  foreman run get <id>",
		)
	}

	switch args[0] {
	case "get":
		return runGet(c, args[1:])
	default:
		return usageTextError(
			fmt.Sprintf("foreman run: unknown subcommand %q", args[0]),
			"Usage:\n  foreman run get <id>",
		)
	}
}

func runGet(c *client.Client, args []string) error {
	fs := newFlagSet("run get")
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 1 {
		return usageError(fs, "foreman run get: expected one argument: <run-id>")
	}

	var out map[string]any

	err := c.GetJSON(client.JoinPath("/api/runs", fs.Arg(0)), &out)
	if err != nil {
		return err
	}

	return printJSON(out)
}
