#!/usr/bin/env python3
"""Fake `pi --mode rpc` for streaming input.

Replays the REAL records captured from pi 1.3.0 (pi_live_input.jsonl, produced by
docs/spikes/LS1/pi_raw.py; only the ~160 KB system-prompt message pair and `message_update`
deltas were dropped). Reads the `prompt` and `get_state` commands, then replays the recording;
after `tool_execution_start` it pauses STEER_WINDOW seconds, the window in which a test writes a
`steer` line, which is substituted into the recorded steer user message. Exits 0 on stdin EOF."""
import json, os, select, sys, time

here = os.path.dirname(os.path.abspath(__file__))
records = [json.loads(l) for l in open(os.path.join(here, "pi_live_input.jsonl"))]
window = float(os.environ.get("STEER_WINDOW", "0.8"))
recorded_steer = "Reply with the word STEERED instead."
steer_text = recorded_steer

for line in sys.stdin:
    if json.loads(line).get("type") == "prompt":
        break

def emit(ev): print(json.dumps(ev), flush=True)

for ev in records:
    if ev.get("type") == "message_start" and ev.get("message", {}).get("role") == "user" and \
            ev["message"]["content"][0]["text"] == recorded_steer:
        ev = json.loads(json.dumps(ev).replace(recorded_steer, steer_text))
    if ev.get("type") == "queue_update" and ev.get("steering"):
        ev = dict(ev, steering=[steer_text])
    emit(ev)
    if ev.get("type") == "tool_execution_start":
        deadline = time.time() + window
        while time.time() < deadline:
            ready, _, _ = select.select([sys.stdin], [], [], 0.05)
            if ready:
                cmd = json.loads(sys.stdin.readline())
                if cmd.get("type") == "steer":
                    steer_text = cmd["message"]
# agent settled: wait for stdin EOF like the real CLI, then exit 0
for _ in sys.stdin:
    pass
