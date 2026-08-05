package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

func runRun(c *client.Client, args []string) error {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "foreman run: missing subcommand (get)")
		os.Exit(2)
	}

	switch args[0] {
	case "get":
		return runGet(c, args[1:])
	default:
		fmt.Fprintf(os.Stderr, "foreman run: unknown subcommand %q\n", args[0])
		os.Exit(2)
		return nil
	}
}

func runGet(c *client.Client, args []string) error {
	fs := flag.NewFlagSet("run get", flag.ExitOnError)
	_ = fs.Parse(args)

	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "foreman run get: expected one argument: <run-id>")
		fs.Usage()
		os.Exit(2)
	}

	var out map[string]any

	err := c.GetJSON(client.JoinPath("/api/runs", fs.Arg(0)), &out)
	if err != nil {
		return err
	}

	return printJSON(out)
}
