#!/usr/bin/env python3
"""LS1 probe: does a RUNNING `claude -p --input-format stream-json` session accept a user
message written to stdin mid-turn, and when does it act on it?
Usage: claude_probe.py <scenario A|B> <cwd> ; HOME must be a scratch home with claude auth symlinks."""
import json, os, subprocess, sys, threading, time
scenario, cwd = sys.argv[1], sys.argv[2]
for f in ("a.txt", "b.txt", "c.txt"):
    p = os.path.join(cwd, f)
    if os.path.exists(p): os.remove(p)
env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
argv = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
        "--verbose", "--permission-mode", "bypassPermissions", "--model", "haiku"] + (["--replay-user-messages"] if os.environ.get("REPLAY") else [])
t0 = time.time()
p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def send(text):
    p.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": text}}) + "\n")
    p.stdin.flush()
    print(f"[{time.time()-t0:6.2f}] SENT {text[:70]!r}", flush=True)
send("Run the bash command `sleep 12` and then create the file a.txt containing ALPHA. Do nothing else.")
sent2 = False
for line in p.stdout:
    ev = json.loads(line)
    t = ev.get("type"); sub = ev.get("subtype")
    summary = t + (":" + sub if sub else "")
    if t == "assistant":
        for c in ev["message"]["content"]:
            if c["type"] == "tool_use": summary += f" tool_use {c['name']} {json.dumps(c['input'])[:70]}"
            if c["type"] == "text": summary += f" text {c['text'][:70]!r}"
    if t == "result": summary += f" result={ev.get('result','')[:80]!r} session={ev.get('session_id')}"
    if t == "system" and sub == "init": summary += f" session={ev.get('session_id')}"
    if t == "user": summary += " " + json.dumps(ev.get("message",{}).get("content"))[:90] + " replay=" + str(ev.get("isReplay")) + " uuid=" + str(ev.get("uuid"))[:8]
    print(f"[{time.time()-t0:6.2f}] {summary}", flush=True)
    if scenario != "C" and t == "assistant" and "tool_use Bash" in summary and not sent2:
        sent2 = True
        send("Change of plan: ALSO create b.txt containing BETA, and write BETA not ALPHA into a.txt.")
    if t == "result":
        nres = globals().get("nres", 0) + 1; globals()["nres"] = nres
        if scenario == "C" and nres == 1:
            send("Now also create c.txt containing GAMMA.")
        else:
            p.stdin.close()
p.wait()
print("a.txt:", open(os.path.join(cwd,"a.txt")).read().strip() if os.path.exists(os.path.join(cwd,"a.txt")) else None,
      "| b.txt:", open(os.path.join(cwd,"b.txt")).read().strip() if os.path.exists(os.path.join(cwd,"b.txt")) else None)
