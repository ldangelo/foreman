// Package client is the Go CLI's HTTP transport to the Foreman server.
//
// It is intentionally tiny: standard library only. The CLI is a thin
// command shaper over the Phoenix JSON API; no caching, no retries, no
// streaming. Every call is one request, one response, one error.
//
// The transport respects FOREMAN_API_URL (default http://127.0.0.1:4766)
// and FOREMAN_API_TOKEN (Bearer credential). A missing token is not a
// client-side error, but the server's BearerAuth plug answers 401 when no
// token is configured server-side unless it opts into allow_insecure_local.
package client

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
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
//   - FOREMAN_API_URL  (default http://127.0.0.1:4766)
//   - FOREMAN_API_TOKEN (optional Bearer credential)
func New() *Client {
	base := os.Getenv("FOREMAN_API_URL")
	if base == "" {
		base = "http://127.0.0.1:4766"
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

// UsageError reports a CLI usage problem and carries the ready-to-print
// stderr text.
type UsageError struct {
	Text string
}

func NewUsageError(text string) error {
	return &UsageError{Text: text}
}

func (e *UsageError) Error() string {
	return e.Text
}

// HelpError reports a help request and carries the ready-to-print text.
type HelpError struct {
	Text string
}

func NewHelpError(text string) error {
	return &HelpError{Text: text}
}

func (e *HelpError) Error() string {
	return e.Text
}

// ExitError carries an explicit process exit code and the stderr text to
// print, for verbs that define their own exit-code contract.
type ExitError struct {
	Code int
	Text string
}

func NewExitError(code int, text string) error {
	return &ExitError{Code: code, Text: text}
}

func (e *ExitError) Error() string {
	return e.Text
}

// ExitCode maps CLI errors to the documented process exit codes.
func ExitCode(err error) int {
	if err == nil {
		return 0
	}

	var helpErr *HelpError
	if errors.As(err, &helpErr) {
		return 0
	}

	var exitErr *ExitError
	if errors.As(err, &exitErr) {
		return exitErr.Code
	}

	var usageErr *UsageError
	if errors.As(err, &usageErr) {
		return 1
	}

	var httpErr *Error
	if errors.As(err, &httpErr) {
		switch {
		case httpErr.Status == http.StatusNotFound:
			return 2
		case httpErr.Status == http.StatusConflict:
			return 3
		case httpErr.Status == http.StatusUnauthorized:
			return 4
		case httpErr.Status >= http.StatusInternalServerError:
			return 5
		default:
			return 1
		}
	}

	return 1
}

// PostJSON sends a JSON envelope to the given path. `body` is
// marshalled; the response body is unmarshalled into `out` when
// non-nil and the status is 2xx. Non-2xx responses are surfaced
// as *Error.
func (c *Client) PostJSON(path string, body any, out any) error {
	return c.do("POST", path, body, out)
}

// PutJSON replaces a resource with the JSON body and decodes the response.
func (c *Client) PutJSON(path string, body any, out any) error {
	return c.do("PUT", path, body, out)
}

// DeleteJSON deletes a resource and decodes the JSON response into `out`.
func (c *Client) DeleteJSON(path string, out any) error {
	return c.do("DELETE", path, nil, out)
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

	return c.send(c.HTTP, req, full, out)
}

// UploadFile is one `files[]` multipart part: the file at Path is streamed from
// disk and sent under the filename Name (the entry-relative path on the server).
type UploadFile struct {
	Name string
	Path string
}

// SendMultipart sends `fields` and `files` as multipart/form-data (method POST or
// PUT) and decodes the JSON response into `out`. Files are streamed, never held in
// memory, so a large library upload does not need a matching amount of RAM.
func (c *Client) SendMultipart(method, path string, fields map[string]string, files []UploadFile, out any) error {
	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)

	go func() {
		pw.CloseWithError(writeMultipart(mw, fields, files))
	}()

	full := c.BaseURL + path
	req, err := http.NewRequest(method, full, pr)
	if err != nil {
		pr.Close()
		return fmt.Errorf("foreman: build request: %w", err)
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())

	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}

	// An upload of many large files legitimately outlives the 30s whole-exchange
	// timeout of ordinary JSON calls, so it uses the same client without one.
	// (Dial/TLS/header timeouts of the transport still apply.)
	hc := *c.HTTP
	hc.Timeout = 0

	return c.send(&hc, req, full, out)
}

func writeMultipart(mw *multipart.Writer, fields map[string]string, files []UploadFile) error {
	for name, value := range fields {
		if err := mw.WriteField(name, value); err != nil {
			return err
		}
	}

	for _, f := range files {
		part, err := mw.CreateFormFile("files[]", f.Name)
		if err != nil {
			return err
		}

		src, err := os.Open(f.Path)
		if err != nil {
			return err
		}

		_, copyErr := io.Copy(part, src)
		src.Close()

		if copyErr != nil {
			return copyErr
		}
	}

	return mw.Close()
}

// send executes the request and decodes a 2xx JSON response into `out`; any other
// status is surfaced as *Error.
func (c *Client) send(hc *http.Client, req *http.Request, full string, out any) error {
	resp, err := hc.Do(req)
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
