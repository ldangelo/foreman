// Package client is the Go CLI's HTTP transport to the Foreman server.
//
// It is intentionally tiny: standard library only. The CLI is a thin
// command shaper over the Phoenix JSON API; no caching, no retries, no
// streaming. Every call is one request, one response, one error.
//
// The transport respects FOREMAN_API_URL (default http://127.0.0.1:4000)
// and FOREMAN_API_TOKEN (optional Bearer credential). A missing token
// is not an error — the server's BearerAuth plug bypasses in dev mode
// when no token is configured server-side either.
package client

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"time"
)

// Client speaks to the Foreman Phoenix API.
type Client struct {
	BaseURL string
	Token   string
	HTTP    *http.Client
}

// New returns a client configured from environment variables:
//   - FOREMAN_API_URL  (default http://127.0.0.1:4000)
//   - FOREMAN_API_TOKEN (optional Bearer credential)
func New() *Client {
	base := os.Getenv("FOREMAN_API_URL")
	if base == "" {
		base = "http://127.0.0.1:4000"
	}

	return &Client{
		BaseURL: base,
		Token:   os.Getenv("FOREMAN_API_TOKEN"),
		HTTP:    &http.Client{Timeout: 30 * time.Second},
	}
}

// Error is the structured response for non-2xx outcomes.
type Error struct {
	Status int
	Body   string
}

func (e *Error) Error() string {
	return fmt.Sprintf("foreman: HTTP %d: %s", e.Status, e.Body)
}

// PostJSON sends a JSON envelope to the given path. `body` is
// marshalled; the response body is unmarshalled into `out` when
// non-nil and the status is 2xx. Non-2xx responses are surfaced
// as *Error.
func (c *Client) PostJSON(path string, body any, out any) error {
	return c.do("POST", path, body, out)
}

// GetJSON fetches a resource and decodes the JSON body into `out`.
func (c *Client) GetJSON(path string, out any) error {
	return c.do("GET", path, nil, out)
}

func (c *Client) do(method, path string, body any, out any) error {
	var reqBody io.Reader

	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("foreman: marshal: %w", err)
		}
		reqBody = bytes.NewReader(buf)
	}

	full := c.BaseURL + path
	req, err := http.NewRequest(method, full, reqBody)
	if err != nil {
		return fmt.Errorf("foreman: build request: %w", err)
	}

	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("foreman: request: %w", err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("foreman: read body: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &Error{Status: resp.StatusCode, Body: string(raw)}
	}

	if out != nil && len(raw) > 0 {
		if err := json.Unmarshal(raw, out); err != nil {
			return fmt.Errorf("foreman: decode %s: %w", full, err)
		}
	}

	return nil
}

// JoinPath concatenates path segments with single slashes. Used for
// building `/api/tasks/:id` style URLs without dragging in a router.
func JoinPath(parts ...string) string {
	out := ""

	for i, p := range parts {
		if p == "" {
			continue
		}

		if i == 0 {
			out = p
			continue
		}

		sep := ""

		if !endsWithSlash(out) && !startsWithSlash(p) {
			sep = "/"
		} else if endsWithSlash(out) && startsWithSlash(p) {
			p = p[1:]
		}

		out = out + sep + p
	}

	return out
}

func endsWithSlash(s string) bool {
	return len(s) > 0 && s[len(s)-1] == '/'
}

func startsWithSlash(s string) bool {
	return len(s) > 0 && s[0] == '/'
}

// URLValues is a tiny helper for query string building without
// importing net/url at every call site.
func URLValues(params map[string]string) string {
	v := url.Values{}

	for k, val := range params {
		if val != "" {
			v.Set(k, val)
		}
	}

	if encoded := v.Encode(); encoded != "" {
		return "?" + encoded
	}

	return ""
}
