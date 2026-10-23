#!/usr/bin/env python3
"""LS1 probe 2 (pi rpc): payloads of queue_update and the user message_start that mark consumption of a
steer; does pi exit when stdin is closed after agent_end? Usage: pi_probe2.py <cwd>"""
import json, os, subprocess, sys, time, threading
cwd = sys.argv[1]
argv = ["pi", "--mode", "rpc", "--provider", "minimax", "--model", "MiniMax-M2.7-highspeed", "--no-session"]
t0 = time.time()
p = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def send(cmd):
    p.stdin.write(json.dumps(cmd) + "\n"); p.stdin.flush(); print(f"[{time.time()-t0:6.2f}] SENT {json.dumps(cmd)[:100]}", flush=True)
send({"id": "req-1", "type": "prompt", "message": "Run the bash command `sleep 8` then reply 'done'."})
sent = False; closed = None
def watchdog():
    time.sleep(70); p.kill()
threading.Thread(target=watchdog, daemon=True).start()
for line in p.stdout:
    try: ev = json.loads(line)
    except ValueError: continue
    t = ev.get("type")
    if t in ("message_update", "extension_ui_request", "tool_execution_update"): continue
    extra = ""
    if t in ("queue_update", "response"): extra = " " + json.dumps(ev)[:200]
    if t in ("message_start", "message_end") and ev.get("message", {}).get("role") == "user": extra = " " + json.dumps(ev)[:260]
    if t in ("agent_end", "agent_settled"): extra = " keys=" + ",".join(ev.keys())
    print(f"[{time.time()-t0:6.2f}] {t}{extra}", flush=True)
    if t == "tool_execution_start" and not sent:
        sent = True; send({"id": "steer-1", "type": "steer", "message": "Reply with the word STEERED instead."})
    if t == "agent_settled" and closed is None:
        closed = time.time(); p.stdin.close(); print(f"[{closed-t0:6.2f}] CLOSED STDIN", flush=True)
rc = p.wait()
print(f"exit rc={rc} after {time.time()-closed:.1f}s from stdin close" if closed else f"exit rc={rc}")
