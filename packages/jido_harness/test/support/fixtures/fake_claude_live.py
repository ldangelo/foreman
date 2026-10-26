#!/usr/bin/env python3
"""Fake `claude -p --input-format stream-json --replay-user-messages`.

Replays the REAL records captured from claude 2.1.308 (claude_live_input.jsonl, produced by
docs/spikes/LS1/claude_raw.py): one recorded turn per stdin user message, substituting the
caller's uuid and text into the isReplay echo. A turn takes TURN_SECONDS (default 0.6) between its
echo and its `result`, which is the window in which a test steers mid-turn. Exits 0 on stdin EOF.
FAKE_CLAUDE_RECORDING names another recording to replay; claude_live_error.jsonl is a turn the
provider rejected (unknown model): a `result` with `is_error: true`, after which claude, like the
real CLI, stays alive on its stdin until EOF."""
import json, os, sys, time

here = os.path.dirname(os.path.abspath(__file__))
turns, current = [], []
for line in open(os.path.join(here, os.environ.get("FAKE_CLAUDE_RECORDING", "claude_live_input.jsonl"))):
    current.append(json.loads(line))
    if current[-1]["type"] == "result":
        turns.append(current); current = []
delay = float(os.environ.get("TURN_SECONDS", "0.6"))
n = 0
for raw in sys.stdin:
    msg = json.loads(raw)
    if msg.get("type") != "user":
        continue
    record = turns[min(n, len(turns) - 1)]; n += 1
    for ev in record:
        if ev["type"] == "user" and ev.get("isReplay"):
            ev = json.loads(json.dumps(ev))
            ev["uuid"] = msg.get("uuid")
            ev["message"]["content"] = msg["message"]["content"]
        print(json.dumps(ev), flush=True)
        if ev["type"] == "user" and ev.get("isReplay"):
            time.sleep(delay)
