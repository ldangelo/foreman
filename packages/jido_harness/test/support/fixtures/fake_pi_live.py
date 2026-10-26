#!/usr/bin/env python3
"""Fake `pi --mode rpc` for streaming input.

Replays REAL records captured from pi (pi_live_input.jsonl, pi 1.3.0, produced by
docs/spikes/LS1/pi_raw.py; only the ~160 KB system-prompt message pair and `message_update`
deltas were dropped). Reads the `prompt` and `get_state` commands, then replays the recording;
after `tool_execution_start` it pauses STEER_WINDOW seconds, the window in which a test writes a
`steer` line, which is substituted into the recorded steer user message. Exits 0 on stdin EOF.

FAKE_PI_OUTCOME picks what the run ends in (default `steer`, the success above):
  error     pi_live_error.jsonl, REAL records of pi 1.4.0 whose provider call failed (HTTP 401):
            `agent_end` with `stopReason: "error"`, then `agent_settled`. The process then stays
            alive on its stdin like the real rpc CLI and exits 0 on EOF. With FAKE_PI_IGNORE_EOF=1
            it outlives the EOF too (an rpc CLI wedged in its own shutdown).
  steer_error  the `steer` run above, except that its last turn fails: the REAL `agent_end` of
            pi_live_error.jsonl (HTTP 401, `stopReason: "error"`) precedes `agent_settled`. A
            provider error after the steered work is done, the shape of the e2e hang.
  rejected  pi's answer to a `prompt` it cannot start (no API key for the model): a failed
            `response`, then silence, alive until stdin EOF."""
import json, os, select, sys, time

here = os.path.dirname(os.path.abspath(__file__))
outcome = os.environ.get("FAKE_PI_OUTCOME", "steer")
recordings = {
    "steer": "pi_live_input.jsonl",
    "steer_error": "pi_live_input.jsonl",
    "error": "pi_live_error.jsonl",
    "rejected": None,
}
if outcome not in recordings:
    sys.exit("fake_pi_live: unknown FAKE_PI_OUTCOME %r" % outcome)
records = [json.loads(l) for l in open(os.path.join(here, recordings[outcome]))] if recordings[outcome] else []
failed_end = next(
    (ev for ev in (json.loads(l) for l in open(os.path.join(here, "pi_live_error.jsonl"))) if ev["type"] == "agent_end"),
    None,
)
window = float(os.environ.get("STEER_WINDOW", "0.8"))
recorded_steer = "Reply with the word STEERED instead."
steer_text = recorded_steer

for line in sys.stdin:
    if json.loads(line).get("type") == "prompt":
        break

def emit(ev): print(json.dumps(ev), flush=True)

def wait_for_eof():
    # Like the real rpc CLI: it only shuts down when its stdin closes.
    for _ in sys.stdin:
        pass
    if os.environ.get("FAKE_PI_IGNORE_EOF") == "1":
        time.sleep(120)

if outcome == "rejected":
    emit({"id": "foreman-prompt", "type": "response", "command": "prompt", "success": False,
          "error": "No API key found for minimax.\n\nUse /login to log into a provider via OAuth or API key."})
    wait_for_eof()
    sys.exit(0)

for ev in records:
    if ev.get("type") == "message_start" and ev.get("message", {}).get("role") == "user" and \
            ev["message"]["content"][0]["text"] == recorded_steer:
        ev = json.loads(json.dumps(ev))
        ev["message"]["content"][0]["text"] = steer_text
    if ev.get("type") == "queue_update" and ev.get("steering"):
        ev = dict(ev, steering=[steer_text])
    if outcome == "steer_error" and ev.get("type") == "agent_settled":
        emit(failed_end)
    emit(ev)
    if ev.get("type") == "tool_execution_start":
        deadline = time.time() + window
        while time.time() < deadline:
            ready, _, _ = select.select([sys.stdin], [], [], 0.05)
            if ready:
                cmd = json.loads(sys.stdin.readline())
                if cmd.get("type") == "steer":
                    steer_text = cmd["message"]
                    break
# agent settled: wait for stdin EOF like the real CLI, then exit 0
wait_for_eof()
