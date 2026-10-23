#!/usr/bin/env python3
"""LS1 probe: `pi --mode rpc`: write {"type":"steer"} while a tool call is running. Usage: pi_probe.py <cwd>"""
import json, os, subprocess, sys, time
cwd = sys.argv[1]
for f in ("a.txt", "b.txt"):
    if os.path.exists(os.path.join(cwd, f)): os.remove(os.path.join(cwd, f))
argv = ["pi", "--mode", "rpc", "--provider", "minimax", "--model", "MiniMax-M2.7-highspeed", "--no-session"]
t0 = time.time()
p = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def send(cmd):
    p.stdin.write(json.dumps(cmd) + "\n"); p.stdin.flush()
    print(f"[{time.time()-t0:6.2f}] SENT {json.dumps(cmd)[:110]}", flush=True)
send({"type": "prompt", "message": "Run the bash command `sleep 12` and then create the file a.txt containing ALPHA. Do nothing else."})
sent = False; ends = 0
for line in p.stdout:
    try: ev = json.loads(line)
    except ValueError: continue
    t = ev.get("type")
    extra = ""
    if t == "tool_execution_start": extra = f" {ev.get('toolName')}"
    if t == "response": extra = f" cmd={ev.get('command')} success={ev.get('success')}"
    if t == "message_start": extra = f" role={ev.get('message',{}).get('role')}"
    if t in ("message_update",): continue
    print(f"[{time.time()-t0:6.2f}] {t}{extra}", flush=True)
    if t == "tool_execution_start" and not sent:
        sent = True
        send({"type": "steer", "message": "Change of plan: write BETA (not ALPHA) into a.txt and ALSO create b.txt containing BETA."})
    if t == "agent_end":
        break
p.stdin.close(); p.terminate()
rd = lambda f: open(os.path.join(cwd, f)).read().strip() if os.path.exists(os.path.join(cwd, f)) else None
print("a.txt:", rd("a.txt"), "| b.txt:", rd("b.txt"))
