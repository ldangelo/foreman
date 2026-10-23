#!/usr/bin/env python3
"""LS1: capture RAW `pi --mode rpc` lines for a prompt + mid-tool steer (fixture source). Usage: pi_raw.py <out> <cwd>"""
import json, subprocess, sys
out, cwd = sys.argv[1], sys.argv[2]
p = subprocess.Popen(["pi","--mode","rpc","--provider","minimax","--model","MiniMax-M2.7-highspeed","--no-session"], cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def send(c): p.stdin.write(json.dumps(c)+"\n"); p.stdin.flush()
send({"id":"foreman-prompt","type":"prompt","message":"Run the bash command `sleep 4` then reply 'done'."})
send({"id":"foreman-get-state","type":"get_state"})
sent = False
with open(out, "w") as f:
    for line in p.stdout:
        try: ev = json.loads(line)
        except ValueError: continue
        if ev.get("type") == "extension_ui_request": continue
        f.write(line)
        if ev.get("type") == "tool_execution_start" and not sent:
            sent = True; send({"id":"input-steer-1","type":"steer","message":"Reply with the word STEERED instead."})
        if ev.get("type") == "agent_settled": p.stdin.close()
p.wait()
