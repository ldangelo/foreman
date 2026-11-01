#!/usr/bin/env python3
"""A SCRIPTED stand-in for a LiteLLM-style gateway, for the zero-spend rehearsal of scripts/e2e/context_window_live.sh
(bead foreman-gppjx). No model and no provider: it plays the part of the model with a fixed plan and tells the claude CLI
how many input tokens each request "used" (the request body's bytes / 4: the CLI's own estimate rule), so the CLI's context
grows the way it does in the real run and its auto-compaction decision can be watched through Foreman at no cost.

The plan, per request (the claude CLI sends the whole conversation every time):
  * a compaction (summarisation) request   -> a short summary that records "PROGRESS reads_done=<n> last_part=<p> ..."
  * parts still to read                    -> a `Read` tool call for the next ballast/part-XX.txt (an absolute path under the
                                              "Primary working directory" the CLI announced in the request)
  * the corpus is complete                 -> a `Write` tool call for report.txt: the CHECKSUM lines of part-01 and of the last part read
  * report written                         -> the text `done`
The corpus is complete when <files> parts have been read, or, with "until_missing" true, when a Read answered that a part does not
exist (the harness adds parts while the run goes on, and stops adding them). <files> and until_missing come from --control FILE
(JSON {"files": N, "until_missing": false}, read on every request: the harness changes it between runs) or from --files.
--delay S makes every answer take S seconds, like a model does.

It also answers the few LiteLLM management endpoints the harness reads (health, /model/info, /v1/models, /spend/logs,
/global/activity/model) from its own request log, so the harness's proxy-side code runs against it too.

  python3 fake_agent_gateway.py --port 4999 --log requests.jsonl --control control.json [--window 512000] [--model Minimax-M3] [--delay 3]
"""
import argparse
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARGS = None
LOCK = threading.Lock()
ROWS = []  # spend-log rows, as LiteLLM's /spend/logs?summarize=false returns them (the fields the harness reads)

COMPACTION_MARKERS = (
    "create a detailed summary of the conversation",
    "summary of the conversation so far",
    "your task is to create a detailed summary",
)


def now_iso(ts=None):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ts or time.time())) + ".000000Z"


def control():
    try:
        with open(ARGS.control) as handle:
            data = json.load(handle)
        return int(data.get("files", ARGS.files)), bool(data.get("until_missing", False))
    except (OSError, ValueError, TypeError):
        return ARGS.files, False


def texts(content):
    if isinstance(content, str):
        return [content]
    out = []
    for block in content or []:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            out.append(block.get("text", ""))
        elif block.get("type") == "tool_result":
            out.extend(texts(block.get("content")))
    return out


def plan(body):
    """What the scripted model does for this request: (kind, payload)."""
    messages = body.get("messages") or []
    everything = []
    for message in messages:
        everything.extend(texts(message.get("content")))
    haystack = "\n".join(everything)
    last_user = ""
    for message in reversed(messages):
        if message.get("role") == "user":
            last_user = "\n".join(texts(message.get("content")))
            break
    system = body.get("system")
    system_text = system if isinstance(system, str) else "\n".join(b.get("text", "") for b in (system or []) if isinstance(b, dict))

    results = {}
    for message in messages:
        if message.get("role") == "user" and isinstance(message.get("content"), list):
            for block in message["content"]:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    results[block.get("tool_use_id")] = (bool(block.get("is_error")), "\n".join(texts(block.get("content"))))
    ok_parts = set()
    missing = False
    wrote_report = False
    for message in messages:
        if message.get("role") != "assistant" or isinstance(message.get("content"), str):
            continue
        for block in message.get("content") or []:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            args = block.get("input") or {}
            path = str(args.get("file_path", ""))
            found = re.search(r"part-(\d+)\.txt$", path)
            if block.get("name") == "Read" and found:
                answer = results.get(block.get("id"))
                if answer is None:
                    continue
                failed = answer[0] or "does not exist" in answer[1] or "No such file" in answer[1]
                if failed:
                    missing = True
                else:
                    ok_parts.add(int(found.group(1)))
            if block.get("name") == "Write" and path.endswith("report.txt"):
                wrote_report = True
    # a compacted conversation starts with the summary, which carries the progress the compaction recorded
    before_reads = [int(n) for n in re.findall(r"PROGRESS reads_done=(\d+)", haystack)]
    before_last = [int(n) for n in re.findall(r"PROGRESS last_part=(\d+)", haystack)]
    done = max([len(ok_parts)] + before_reads)
    last_part = max(list(ok_parts) + before_last + [0])
    complete = missing or "PROGRESS corpus_complete=1" in haystack
    wrote_report = wrote_report or "PROGRESS report_written=1" in haystack

    if any(m in (last_user + "\n" + system_text).lower() for m in COMPACTION_MARKERS):
        return "summary", {"reads_done": done, "last_part": last_part, "complete": complete, "report_written": wrote_report}

    if not body.get("tools"):
        return "text", "ok"

    cwd = re.search(r"Primary working directory: (\S+)", haystack)
    cwd = cwd.group(1) if cwd else os.getcwd()
    total, until_missing = control()
    if not complete and (until_missing or done < total) and last_part < 99:
        return "tool", {"name": "Read", "input": {"file_path": "%s/ballast/part-%02d.txt" % (cwd, last_part + 1)}}
    if not wrote_report:
        lines = []
        for number in (1, last_part):
            try:
                with open("%s/ballast/part-%02d.txt" % (cwd, number)) as handle:
                    lines.append(handle.read().rstrip("\n").split("\n")[-1])
            except OSError:
                lines.append("CHECKSUM part-%02d unreadable" % number)
        return "tool", {"name": "Write", "input": {"file_path": cwd + "/report.txt", "content": "\n".join(lines) + "\n"}}
    return "text", "done"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _record(self, entry):
        entry["at"] = now_iso()
        with LOCK:
            with open(ARGS.log, "a") as handle:
                handle.write(json.dumps(entry) + "\n")

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/health/liveliness":
            return self._json(200, "I'm alive!")
        if path == "/health/readiness":
            return self._json(200, {"status": "healthy", "db": "connected"})
        if path == "/v1/models":
            return self._json(200, {"data": [{"id": ARGS.model, "object": "model"}]})
        if path == "/model/info":
            info = {"max_input_tokens": ARGS.window, "max_output_tokens": 131072, "input_cost_per_token": 3e-07,
                    "output_cost_per_token": 1.2e-07, "supports_prompt_caching": True, "litellm_provider": "stand-in", "mode": "chat"}
            return self._json(200, {"data": [{"model_name": ARGS.model, "litellm_params": {"model": "stand-in/" + ARGS.model}, "model_info": info}]})
        if path == "/spend/logs":
            with LOCK:
                return self._json(200, list(ROWS))
        if path == "/global/activity/model":
            with LOCK:
                total = sum(r["total_tokens"] for r in ROWS)
                return self._json(200, [{"model": ARGS.model, "sum_api_requests": len(ROWS), "sum_total_tokens": total}] if ROWS else [])
        self._record({"path": path, "method": "GET", "unhandled": True})
        return self._json(404, {"type": "error", "error": {"type": "not_found_error", "message": "stand-in: " + path}})

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b""
        path = self.path.split("?")[0]
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}
        if path.endswith("/count_tokens"):
            return self._json(200, {"input_tokens": max(1, len(raw) // 4)})
        if not path.endswith("/messages"):
            self._record({"path": path, "method": "POST", "unhandled": True})
            return self._json(404, {"type": "error", "error": {"type": "not_found_error", "message": "stand-in: " + path}})

        kind, payload = plan(body)
        claimed = max(1, len(raw) // 4)
        started = time.time()
        entry = {"path": path, "bytes": len(raw), "model": body.get("model"), "stream": bool(body.get("stream")),
                 "messages": len(body.get("messages") or []), "kind": kind, "compaction": kind == "summary", "claimed_input_tokens": claimed}
        if kind == "tool":
            entry["tool"] = "%s %s" % (payload["name"], os.path.basename(str(payload["input"].get("file_path", ""))))
        self._record(entry)
        if ARGS.delay > 0 and body.get("tools"):
            time.sleep(ARGS.delay)

        usage = {"input_tokens": claimed, "output_tokens": 12, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
        if kind == "summary":
            text = ("Summary of the conversation so far: the ballast files are being read in order.\n"
                    "PROGRESS reads_done=%d\nPROGRESS last_part=%d\nPROGRESS corpus_complete=%d\nPROGRESS report_written=%d"
                    % (payload["reads_done"], payload["last_part"], int(payload["complete"]), int(payload["report_written"])))
            blocks = [{"type": "text", "text": text}]
            stop = "end_turn"
        elif kind == "tool":
            blocks = [{"type": "tool_use", "id": "toolu_%08d" % int(time.time() * 1000 % 10 ** 8), "name": payload["name"], "input": payload["input"]}]
            stop = "tool_use"
        else:
            blocks = [{"type": "text", "text": payload}]
            stop = "end_turn"

        if not body.get("stream"):
            self._json(200, {"id": "msg_%d" % int(started * 1000), "type": "message", "role": "assistant", "model": body.get("model"),
                             "content": blocks, "stop_reason": stop, "stop_sequence": None, "usage": usage})
        else:
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("cache-control", "no-cache")
            self.send_header("transfer-encoding", "chunked")
            self.end_headers()

            def chunk(event, data):
                payload_bytes = ("event: %s\ndata: %s\n\n" % (event, json.dumps(data))).encode()
                self.wfile.write(("%x\r\n" % len(payload_bytes)).encode() + payload_bytes + b"\r\n")
                self.wfile.flush()

            chunk("message_start", {"type": "message_start", "message": {"id": "msg_%d" % int(started * 1000), "type": "message", "role": "assistant",
                                    "model": body.get("model"), "content": [], "stop_reason": None, "stop_sequence": None, "usage": usage}})
            for index, block in enumerate(blocks):
                if block["type"] == "text":
                    chunk("content_block_start", {"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}})
                    chunk("content_block_delta", {"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": block["text"]}})
                else:
                    chunk("content_block_start", {"type": "content_block_start", "index": index,
                                                  "content_block": {"type": "tool_use", "id": block["id"], "name": block["name"], "input": {}}})
                    chunk("content_block_delta", {"type": "content_block_delta", "index": index,
                                                  "delta": {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}})
                chunk("content_block_stop", {"type": "content_block_stop", "index": index})
            chunk("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 12}})
            chunk("message_stop", {"type": "message_stop"})
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()

        with LOCK:
            ROWS.append({"startTime": now_iso(started), "endTime": now_iso(), "model": "stand-in/" + ARGS.model, "model_group": ARGS.model,
                         "prompt_tokens": claimed, "completion_tokens": 12, "total_tokens": claimed + 12, "spend": 0.0, "status": "success",
                         "call_type": "anthropic_messages", "request_id": "chatcmpl-%d" % len(ROWS), "request_duration_ms": int((time.time() - started) * 1000)})


def main():
    global ARGS
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--control")
    parser.add_argument("--files", type=int, default=2)
    parser.add_argument("--window", type=int, default=512000)
    parser.add_argument("--model", default="Minimax-M3")
    parser.add_argument("--delay", type=float, default=0.0)
    ARGS = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    print("scripted stand-in gateway on 127.0.0.1:%d" % ARGS.port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
