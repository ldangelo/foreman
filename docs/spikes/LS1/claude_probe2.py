#!/usr/bin/env python3
"""LS1 probe 2 (claude): (1) does a caller-supplied `uuid` on a stdin user message come back on the
--replay-user-messages echo? (2) background-task case (foreman-b3jtt): stdin kept open after the first
`result`, a steer sent while the background task is still running. Usage: claude_probe2.py <cwd>"""
import json, os, subprocess, sys, time
cwd = sys.argv[1]
for f in ("bg.txt", "d.txt"):
    if os.path.exists(os.path.join(cwd, f)): os.remove(os.path.join(cwd, f))
env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
argv = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--replay-user-messages", "--permission-mode", "bypassPermissions", "--model", "haiku"]
t0 = time.time()
p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def send(text, uuid=None):
    m = {"type": "user", "message": {"role": "user", "content": text}}
    if uuid: m["uuid"] = uuid
    p.stdin.write(json.dumps(m) + "\n"); p.stdin.flush()
    print(f"[{time.time()-t0:6.2f}] SENT uuid={uuid} {text[:60]!r}", flush=True)
send("Start the shell command `sleep 15 && echo hi > bg.txt` as a BACKGROUND task (run_in_background), then reply with just 'started' and end your turn.",
     "11111111-1111-4111-8111-111111111111")
nres = 0; steered = False
for line in p.stdout:
    ev = json.loads(line); t = ev.get("type"); sub = ev.get("subtype")
    if t == "system" and sub in ("hook_started", "hook_response", "thinking_tokens"): continue
    s = t + (":" + sub if sub else "")
    if t == "user": s += f" replay={ev.get('isReplay')} uuid={ev.get('uuid')} synthetic={ev.get('isSynthetic')} " + json.dumps(ev['message']['content'])[:80]
    if t == "assistant":
        for c in ev["message"]["content"]:
            if c["type"] == "tool_use": s += f" tool_use {c['name']} {json.dumps(c['input'])[:60]}"
            if c["type"] == "text": s += f" text {c['text'][:60]!r}"
    if t == "result": s += f" {ev.get('result','')[:60]!r}"
    print(f"[{time.time()-t0:6.2f}] {s}", flush=True)
    if t == "result":
        nres += 1
        if nres == 1 and not steered:
            steered = True
            send("Also create d.txt containing DELTA.", "22222222-2222-4222-8222-222222222222")
        elif nres >= 2 and time.time() - t0 > 20:
            p.stdin.close()
    if time.time() - t0 > 60: p.stdin.close(); break
try: p.wait(timeout=20)
except Exception: p.kill()
print("exit", p.returncode, "bg.txt", os.path.exists(os.path.join(cwd, "bg.txt")), "d.txt", os.path.exists(os.path.join(cwd, "d.txt")))
