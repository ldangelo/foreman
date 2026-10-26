package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

const (
	chatPollWaitMS = 20000
	chatPageLimit  = 200

	// chatExitUnhealthy is the exit code when the coordinator reports `unhealthy`.
	chatExitUnhealthy = 3
	chatExitUsage     = 2
)

// chatStdin and chatStdinIsTerminal are variables so tests can feed input.
var chatStdin io.Reader = os.Stdin

var chatStdinIsTerminal = func() bool {
	fi, err := os.Stdin.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}

// chatMessage is the subset of a coordinator message the CLI interprets; the
// raw object is kept alongside for json/ndjson output.
type chatMessage struct {
	Seq  int    `json:"seq"`
	Role string `json:"role"`
	Kind string `json:"kind"`
	Text string `json:"text"`
}

type chatPage struct {
	Messages           []json.RawMessage `json:"messages"`
	NextCursor         int               `json:"next_cursor"`
	HasMore            bool              `json:"has_more"`
	TruncatedBeforeSeq *int              `json:"truncated_before_seq"`
	Status             string            `json:"status"`
	PendingMessages    int               `json:"pending_messages"`
}

type chatPostResponse struct {
	MessageID string `json:"message_id"`
	Seq       int    `json:"seq"`
}

type chatSession struct {
	c         *client.Client
	projectID string
	format    string
	timeout   time.Duration
	pending   []json.RawMessage // json format: flushed as one array
}

func projectChat(c *client.Client, args []string) error {
	fs := newFlagSet("project chat")
	message := fs.String("m", "", "Message text (alternative to positional words or stdin)")
	noWait := fs.Bool("no-wait", false, "Return right after sending, printing message_id and seq")
	since := fs.Int("since", 0, "Print messages after this seq cursor, then exit")
	history := fs.Int("history", 0, "Print the last N messages, then exit")
	format := fs.String("format", "text", "Output format (text|json|ndjson)")
	restart := fs.Bool("restart", false, "Restart the coordinator, then exit")
	timeout := fs.Duration("timeout", 10*time.Minute, "Overall time to wait for the coordinator's reply")
	fs.Usage = func() {
		fmt.Fprint(fs.Output(), "Usage of project chat:\n  foreman project chat [flags] <project-id> [message...]\n\nSend a message to the project's coordinator and print its replies. With no message on a\nterminal, runs an interactive loop (/restart restarts the coordinator, /quit or EOF exits).\nExit codes: 0 ok, 2 usage, 3 coordinator unhealthy, other non-zero on HTTP errors.\n\nFlags:\n")
		fs.PrintDefaults()
	}
	// Accept the project id before or after the flags.
	if err := fs.parse(args); err != nil {
		return chatUsageCode(err)
	}
	rest := fs.Args()
	if len(rest) == 0 {
		return chatUsageError(fs, "foreman project chat: expected <project-id>")
	}
	projectID := rest[0]
	if len(rest) > 1 {
		if err := fs.parse(rest[1:]); err != nil {
			return chatUsageCode(err)
		}
		rest = append([]string{projectID}, fs.Args()...)
	}
	words := rest[1:]

	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })

	switch *format {
	case "text", "json", "ndjson":
	default:
		return chatUsageError(fs, "foreman project chat: unsupported format %q (want text|json|ndjson)", *format)
	}
	if *timeout <= 0 {
		return chatUsageError(fs, "foreman project chat: --timeout must be positive")
	}
	if set["since"] && *since < 0 {
		return chatUsageError(fs, "foreman project chat: --since must be >= 0")
	}
	if set["history"] && *history < 1 {
		return chatUsageError(fs, "foreman project chat: --history must be >= 1")
	}
	if set["since"] && set["history"] {
		return chatUsageError(fs, "foreman project chat: --since and --history are mutually exclusive")
	}
	if set["m"] && len(words) > 0 {
		return chatUsageError(fs, "foreman project chat: use either -m or message words, not both")
	}
	hasMessage := set["m"] || len(words) > 0
	readOnly := set["since"] || set["history"]
	if *restart && (hasMessage || readOnly || *noWait) {
		return chatUsageError(fs, "foreman project chat: --restart cannot be combined with a message, --since, --history or --no-wait")
	}
	if readOnly && (hasMessage || *noWait) {
		return chatUsageError(fs, "foreman project chat: --since/--history cannot be combined with a message or --no-wait")
	}

	s := &chatSession{c: c, projectID: projectID, format: *format, timeout: *timeout}

	switch {
	case *restart:
		return s.restart()
	case set["since"]:
		return s.readHistory(*since, 0)
	case set["history"]:
		return s.readHistory(0, *history)
	}

	text := *message
	if len(words) > 0 {
		text = strings.Join(words, " ")
	}
	if !hasMessage {
		if chatStdinIsTerminal() {
			if *noWait {
				return chatUsageError(fs, "foreman project chat: --no-wait needs a message")
			}
			return s.interactive()
		}
		raw, err := io.ReadAll(chatStdin)
		if err != nil {
			return fmt.Errorf("foreman project chat: read stdin: %w", err)
		}
		text = strings.TrimRight(string(raw), "\r\n")
	}
	if strings.TrimSpace(text) == "" {
		return chatUsageError(fs, "foreman project chat: message is empty (pass words, -m, or pipe text on stdin)")
	}

	return s.sendOnce(text, *noWait)
}

// chatUsageError is usageError with the chat verb's exit code 2.
func chatUsageError(fs *flagSet, format string, args ...any) error {
	return chatUsageCode(usageError(fs, format, args...))
}

func chatUsageCode(err error) error {
	var help *client.HelpError
	if errors.As(err, &help) {
		return err
	}
	return client.NewExitError(chatExitUsage, err.Error())
}

func (s *chatSession) path(parts ...string) string {
	all := append([]string{"/api/projects", url.PathEscape(s.projectID), "coordinator"}, parts...)
	return client.JoinPath(all...)
}

func newChatMessageID() string {
	var b [4]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf("cli-%d-%s", time.Now().UnixNano(), hex.EncodeToString(b[:]))
}

func (s *chatSession) post(text string) (chatPostResponse, error) {
	var resp chatPostResponse
	body := map[string]any{"text": text, "message_id": newChatMessageID(), "source": "cli"}
	err := s.c.PostJSON(s.path("messages"), body, &resp)
	return resp, err
}

func (s *chatSession) fetch(after, limit, waitMS int) (chatPage, error) {
	q := url.Values{}
	q.Set("after", strconv.Itoa(after))
	q.Set("limit", strconv.Itoa(limit))
	q.Set("wait_ms", strconv.Itoa(waitMS))
	var page chatPage
	err := s.c.GetJSON(s.path("messages")+"?"+q.Encode(), &page)
	return page, err
}

func (s *chatSession) sendOnce(text string, noWait bool) error {
	resp, err := s.post(text)
	if err != nil {
		return err
	}
	if noWait {
		return s.printSent(resp)
	}
	return s.stream(resp.Seq)
}

func (s *chatSession) printSent(resp chatPostResponse) error {
	switch s.format {
	case "text":
		_, err := fmt.Fprintf(os.Stdout, "sent message_id=%s seq=%d\n", resp.MessageID, resp.Seq)
		return err
	case "json":
		return printJSON(resp)
	default:
		return json.NewEncoder(os.Stdout).Encode(resp)
	}
}

// stream long-polls for messages after cursor, printing everything that is not
// the operator's own echo, until the coordinator is idle again.
func (s *chatSession) stream(cursor int) error {
	deadline := time.Now().Add(s.timeout)
	sawReply := false
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			if err := s.flush(); err != nil {
				return err
			}
			return fmt.Errorf("foreman project chat: timed out after %s waiting for the coordinator; read on with `foreman project chat --since %d %s`", s.timeout, cursor, s.projectID)
		}
		wait := int(remaining.Milliseconds())
		if wait > chatPollWaitMS {
			wait = chatPollWaitMS
		}
		page, err := s.fetch(cursor, chatPageLimit, wait)
		if err != nil {
			_ = s.flush()
			return err
		}
		for _, raw := range page.Messages {
			var m chatMessage
			if err := json.Unmarshal(raw, &m); err != nil {
				return fmt.Errorf("foreman project chat: decode message: %w", err)
			}
			if m.Seq > cursor {
				cursor = m.Seq
			}
			if m.Role == "operator" {
				continue
			}
			sawReply = true
			if err := s.emit(raw, m); err != nil {
				return err
			}
		}
		if page.NextCursor > cursor {
			cursor = page.NextCursor
		}

		switch {
		case page.Status == "unhealthy":
			if err := s.flush(); err != nil {
				return err
			}
			return s.unhealthyError()
		case page.HasMore:
		case page.Status == "idle" && page.PendingMessages == 0 && (sawReply || len(page.Messages) == 0):
			return s.flush()
		}
	}
}

// readHistory prints messages after `after`; with tail > 0 only the last
// `tail` messages are kept.
func (s *chatSession) readHistory(after, tail int) error {
	var all []json.RawMessage
	cursor := after
	for {
		page, err := s.fetch(cursor, chatPageLimit, 0)
		if err != nil {
			return err
		}
		if page.TruncatedBeforeSeq != nil && s.format == "text" {
			fmt.Fprintf(os.Stderr, "(history truncated before seq %d)\n", *page.TruncatedBeforeSeq)
		}
		all = append(all, page.Messages...)
		if tail > 0 && len(all) > tail {
			all = all[len(all)-tail:]
		}
		if !page.HasMore || page.NextCursor <= cursor {
			break
		}
		cursor = page.NextCursor
	}
	for _, raw := range all {
		var m chatMessage
		if err := json.Unmarshal(raw, &m); err != nil {
			return fmt.Errorf("foreman project chat: decode message: %w", err)
		}
		if err := s.emit(raw, m); err != nil {
			return err
		}
	}
	return s.flush()
}

func (s *chatSession) restart() error {
	var out map[string]any
	if err := s.c.PostJSON(s.path("restart"), nil, &out); err != nil {
		return err
	}
	if s.format == "text" {
		status, _ := out["status"].(string)
		_, err := fmt.Fprintf(os.Stdout, "coordinator restarted for project %s (status: %s)\n", s.projectID, status)
		return err
	}
	if s.format == "json" {
		return printJSON(out)
	}
	return json.NewEncoder(os.Stdout).Encode(out)
}

func (s *chatSession) interactive() error {
	scanner := bufio.NewScanner(chatStdin)
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for {
		fmt.Fprint(os.Stderr, "> ")
		if !scanner.Scan() {
			return scanner.Err()
		}
		line := strings.TrimSpace(scanner.Text())
		var err error
		switch line {
		case "":
			continue
		case "/quit", "/exit":
			return nil
		case "/restart":
			err = s.restart()
		default:
			err = s.sendOnce(line, false)
		}
		var httpErr *client.Error
		if errors.As(err, &httpErr) {
			// Keep the session alive on request-level errors (e.g. message_too_large).
			fmt.Fprintln(os.Stderr, err)
			continue
		}
		if err != nil {
			return err
		}
	}
}

func (s *chatSession) unhealthyError() error {
	var st struct {
		ConsecutiveFailures int `json:"consecutive_failures"`
		LastError           *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"last_error"`
	}
	var b strings.Builder
	fmt.Fprintf(&b, "foreman project chat: the coordinator for project %s is unhealthy", s.projectID)
	if err := s.c.GetJSON(s.path(), &st); err != nil {
		fmt.Fprintf(&b, " (status lookup failed: %v)", err)
	} else {
		if st.ConsecutiveFailures > 0 {
			fmt.Fprintf(&b, " after %d consecutive failures", st.ConsecutiveFailures)
		}
		if st.LastError != nil {
			fmt.Fprintf(&b, "; last error: %s: %s", st.LastError.Code, st.LastError.Message)
		}
	}
	fmt.Fprintf(&b, "\nrestart it with `foreman project chat --restart %s`", s.projectID)
	return client.NewExitError(chatExitUnhealthy, b.String())
}

// emit prints (text/ndjson) or buffers (json) one message.
func (s *chatSession) emit(raw json.RawMessage, m chatMessage) error {
	switch s.format {
	case "json":
		s.pending = append(s.pending, raw)
		return nil
	case "ndjson":
		var buf bytes.Buffer
		if err := json.Compact(&buf, raw); err != nil {
			return err
		}
		buf.WriteByte('\n')
		_, err := os.Stdout.Write(buf.Bytes())
		return err
	default:
		_, err := fmt.Fprintln(os.Stdout, formatChatMessage(m))
		return err
	}
}

// flush writes the buffered json-format array.
func (s *chatSession) flush() error {
	if s.format != "json" {
		return nil
	}
	out := s.pending
	s.pending = nil
	if out == nil {
		out = []json.RawMessage{}
	}
	return printJSON(out)
}

func formatChatMessage(m chatMessage) string {
	if m.Role == "coordinator" && (m.Kind == "reply" || m.Kind == "message" || m.Kind == "") {
		return m.Text
	}
	return fmt.Sprintf("[%s %s] %s", m.Role, m.Kind, m.Text)
}
