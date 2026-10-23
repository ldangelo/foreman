#!/usr/bin/env python3
"""LS1: capture RAW stream-json lines of a two-message live-input claude session (fixture source)."""
import json, os, subprocess, sys
out = sys.argv[1]
env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
p = subprocess.Popen(["claude","-p","--input-format","stream-json","--output-format","stream-json","--include-partial-messages","--verbose","--replay-user-messages","--permission-mode","bypassPermissions","--model","haiku"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def send(text, uuid):
    p.stdin.write(json.dumps({"type":"user","uuid":uuid,"message":{"role":"user","content":text}})+"\n"); p.stdin.flush()
send("Reply with the single word one.", "11111111-1111-4111-8111-111111111111")
n = 0
with open(out, "w") as f:
    for line in p.stdout:
        f.write(line); ev = json.loads(line)
        if ev.get("type") == "result":
            n += 1
            if n == 1: send("Reply with the single word two.", "22222222-2222-4222-8222-222222222222")
            else: p.stdin.close()
p.wait()
