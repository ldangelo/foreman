package main

import (
	"encoding/json"
	"os"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// commandEnvelope is the JSON envelope sent to /api/commands.
// The server derives the aggregate_id from the payload.
type commandEnvelope struct {
	Type      string         `json:"type"`
	CommandID string         `json:"command_id,omitempty"`
	Payload   map[string]any `json:"payload"`
}

// postCommandWithResponse centralizes the POST /api/commands path.
// The server returns 201 on success with `{status: "accepted", result: ...}`.
func postCommandWithResponse(c *client.Client, body any) (map[string]any, error) {
	var out map[string]any
	if err := c.PostJSON("/api/commands", body, &out); err != nil {
		return nil, err
	}

	return out, nil
}

func postCommand(c *client.Client, body any) error {
	out, err := postCommandWithResponse(c, body)
	if err != nil {
		return err
	}

	return printJSON(out)
}

// printJSON pretty-prints a value to stdout.
func printJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

// getStr retrieves a string value from a map, returning empty string if not found or not a string.
func getStr(m map[string]any, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}
