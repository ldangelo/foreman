#!/usr/bin/env python3
"""Minimal stdio MCP server standing in for Foreman's agent-facing allowlist (create/message/reply/remember).
Logs every tools/call (args as received) to $S1_MCP_LOG as JSONL. $S1_FAIL_NTH=N makes the Nth create call fail
(simulated partial execution). Validates workflow enum and required args like a real command gate would."""
import sys, json, os
LOG = os.environ.get("S1_MCP_LOG", "/tmp/s1-mcp.log"); FAIL_NTH = int(os.environ.get("S1_FAIL_NTH", "0"))
WF = ["fix", "assess", "prd", "implement-trd", "review"]
TOOLS = [
 {"name": "foreman_thread_create", "description": "Start a worker thread for one independent task.",
  "inputSchema": {"type": "object", "required": ["title", "workflow", "prompt"], "properties": {"title": {"type": "string"}, "workflow": {"type": "string", "enum": WF}, "prompt": {"type": "string"}}}},
 {"name": "foreman_thread_message", "description": "Send a follow-up to an EXISTING thread.",
  "inputSchema": {"type": "object", "required": ["thread_id", "text"], "properties": {"thread_id": {"type": "string"}, "text": {"type": "string"}}}},
 {"name": "foreman_project_reply", "description": "Reply to the user in the project chat.",
  "inputSchema": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}}},
 {"name": "foreman_memory_write", "description": "Save a standing preference/fact to project memory.",
  "inputSchema": {"type": "object", "required": ["note"], "properties": {"note": {"type": "string"}}}},
]
creates = 0
def log(o):
    with open(LOG, "a") as f: f.write(json.dumps(o) + "\n")
def send(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    try: m = json.loads(line)
    except Exception: continue
    mid, meth = m.get("id"), m.get("method")
    if meth == "initialize":
        log({"event": "initialize", "meta": (m.get("params") or {}).get("_meta"), "client": (m.get("params") or {}).get("clientInfo")})
        send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": (m["params"].get("protocolVersion") or "2024-11-05"), "capabilities": {"tools": {}}, "serverInfo": {"name": "s1mock", "version": "0"}}})
    elif meth == "tools/list": send({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
    elif meth == "tools/call":
        p = m["params"]; name, args = p["name"], p.get("arguments") or {}
        spec = next((t for t in TOOLS if t["name"] == name), None)
        err = None
        if not spec: err = "unknown tool"
        else:
            miss = [k for k in spec["inputSchema"]["required"] if not isinstance(args.get(k), str) or not args.get(k)]
            if miss: err = "missing/invalid: %s" % miss
            elif name == "foreman_thread_create":
                creates += 1
                if args["workflow"] not in WF: err = "invalid workflow %r" % args["workflow"]
                elif FAIL_NTH and creates == FAIL_NTH: err = "simulated transient failure"
        log({"event": "call", "tool": name, "args": args, "error": err})
        send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": ("ERROR: " + err) if err else json.dumps({"ok": True, "id": "X-%d" % creates})}], "isError": bool(err)}})
    elif mid is not None: send({"jsonrpc": "2.0", "id": mid, "result": {}})
