#!/usr/bin/env python3
"""A stand-in for an Anthropic-compatible gateway (what a LiteLLM proxy looks like to the claude CLI), for
scripts/e2e/context_window_probe/probe.sh (bead foreman-gppjx).

It answers every /v1/messages request with a tiny streamed reply, but REPORTS whatever context size it is told to in the reply's
`usage` (the number the claude CLI uses to decide when to auto-compact), and it logs one JSON line per request to --log: the
path, the model name, how many messages and bytes the request carried, whether it is a compaction (summarisation) request, and
the system prompt's size. Nothing here talks to any provider and nothing costs money.

  python3 fake_anthropic.py --port 4999 --log requests.jsonl --report-tokens 190000

--report-tokens N        the input_tokens the reply claims (cache reads/writes are reported as 0)
--report-file FILE       when given, the number is read from FILE on every request (the harness changes it between turns)
The /v1/messages/count_tokens endpoint answers bytes/4 (the CLI's own estimate rule), any other path answers 404.
"""
import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARGS = None
LOCK = threading.Lock()
COMPACTION_MARKERS = (
    "create a detailed summary of the conversation",
    "summary of the conversation so far",
    "Your task is to create a detailed summary",
)


def reported_tokens():
    if ARGS.report_file:
        try:
            with open(ARGS.report_file) as f:
                return int(f.read().strip())
        except (OSError, ValueError):
            pass
    return ARGS.report_tokens


def flatten(content):
    if isinstance(content, str):
        return content
    out = []
    for block in content or []:
        if isinstance(block, dict):
            out.append(block.get("text") or json.dumps(block.get("content", ""))[:200] if block.get("type") in ("text", "tool_result") else "")
    return "\n".join(out)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet
        pass

    def _json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._record({"path": self.path, "method": "GET"})
        self._json(404, {"type": "error", "error": {"type": "not_found_error", "message": "fake gateway: " + self.path}})

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b""
        path = self.path.split("?")[0]
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}
        if path.endswith("/count_tokens"):
            est = max(1, len(raw) // 4)
            self._record({"path": path, "method": "POST", "bytes": len(raw), "model": body.get("model"), "estimate": est})
            return self._json(200, {"input_tokens": est})
        if not path.endswith("/messages"):
            self._record({"path": path, "method": "POST", "bytes": len(raw)})
            return self._json(404, {"type": "error", "error": {"type": "not_found_error", "message": "fake gateway: " + path}})

        messages = body.get("messages") or []
        system = body.get("system")
        system_text = system if isinstance(system, str) else "\n".join(b.get("text", "") for b in (system or []) if isinstance(b, dict))
        last_user = ""
        for m in reversed(messages):
            if m.get("role") == "user":
                last_user = flatten(m.get("content"))
                break
        haystack = (last_user + "\n" + system_text)
        compaction = any(marker.lower() in haystack.lower() for marker in COMPACTION_MARKERS)
        tokens = reported_tokens()
        self._record({
            "path": path, "method": "POST", "bytes": len(raw), "model": body.get("model"), "stream": bool(body.get("stream")),
            "messages": len(messages), "system_chars": len(system_text), "max_tokens": body.get("max_tokens"),
            "compaction": compaction, "last_user_head": last_user[:90].replace("\n", " "), "reported_input_tokens": tokens,
        })
        reply = "COMPACTION SUMMARY: nothing to summarise." if compaction else "OK"
        usage = {"input_tokens": tokens, "output_tokens": 3, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
        if not body.get("stream"):
            return self._json(200, {"id": "msg_fake", "type": "message", "role": "assistant", "model": body.get("model"),
                                    "content": [{"type": "text", "text": reply}], "stop_reason": "end_turn", "stop_sequence": None, "usage": usage})
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()

        def chunk(event, data):
            payload = ("event: %s\ndata: %s\n\n" % (event, json.dumps(data))).encode()
            self.wfile.write(("%x\r\n" % len(payload)).encode() + payload + b"\r\n")
            self.wfile.flush()

        chunk("message_start", {"type": "message_start", "message": {"id": "msg_fake", "type": "message", "role": "assistant", "model": body.get("model"),
                                 "content": [], "stop_reason": None, "stop_sequence": None, "usage": usage}})
        chunk("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
        chunk("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": reply}})
        chunk("content_block_stop", {"type": "content_block_stop", "index": 0})
        chunk("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 3}})
        chunk("message_stop", {"type": "message_stop"})
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def _record(self, entry):
        entry["at"] = time.strftime("%H:%M:%S")
        with LOCK:
            with open(ARGS.log, "a") as f:
                f.write(json.dumps(entry) + "\n")


def main():
    global ARGS
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--log", required=True)
    p.add_argument("--report-tokens", type=int, default=1000)
    p.add_argument("--report-file")
    ARGS = p.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    print("fake gateway on 127.0.0.1:%d" % ARGS.port, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
