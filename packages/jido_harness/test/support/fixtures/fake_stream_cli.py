#!/usr/bin/env python3
"""Fake provider CLI that emits canned JSONL streams.

Python (not an `elixir` script) on purpose: every invocation boots a fresh
interpreter, and an Elixir VM boot takes seconds on a loaded host, which made
the 5s run-await in DirectCLIAdapterTest a race against VM startup.
"""
import sys

CODEX = [
    '{"type":"thread.started","thread_id":"codex-fixture-session"}',
    '{"type":"item.completed","thread_id":"codex-fixture-session","item":{"type":"agent_message","text":"codex-ok"}}',
    '{"type":"turn.completed","thread_id":"codex-fixture-session","status":"completed","usage":{"input_tokens":2,"output_tokens":1}}',
]

GEMINI = [
    '{"type":"init","session_id":"gemini-fixture-session","model":"fixture"}',
    '{"type":"message","role":"assistant","content":"gemini-ok","delta":true}',
    '{"type":"result","status":"success","stats":{"input_tokens":2,"output_tokens":1}}',
]

CLAUDE = [
    '{"type":"system","subtype":"init","session_id":"claude-fixture-session","model":"fixture","tools":[]}',
    '{"type":"stream_event","session_id":"claude-fixture-session","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"claude-ok"}}}',
    '{"type":"result","subtype":"success","session_id":"claude-fixture-session","result":"claude-ok","usage":{"input_tokens":2,"output_tokens":1}}',
]

AMP = [
    '{"type":"system","subtype":"init","session_id":"amp-fixture-session","tools":[]}',
    '{"type":"assistant","session_id":"amp-fixture-session","message":{"content":[{"type":"text","text":"amp-ok"}]}}',
    '{"type":"result","subtype":"success","session_id":"amp-fixture-session","result":"amp-ok","usage":{"input_tokens":2,"output_tokens":1}}',
]

GROK = [
    '{"type":"thought","data":"checking"}',
    '{"type":"tool_call","toolCallId":"call-read","toolName":"read_file","rawInput":{"target_file":"missing.md"}}',
    '{"type":"tool_call_update","toolCallId":"call-read","status":"failed","rawOutput":{"FileNotFound":"missing.md does not exist"}}',
    '{"type":"text","data":"grok-ok"}',
    '{"type":"usage","usage":{"input_tokens":2,"output_tokens":1}}',
    '{"type":"end","stopReason":"end_turn","sessionId":"grok-fixture-session","requestId":"grok-request","num_turns":1,"usage":{"input_tokens":2,"output_tokens":1}}',
]


def main(args):
    if "exec" in args and "--json" in args:
        events = CODEX
    elif "--prompt" in args:
        events = GEMINI
    elif "--print" in args:
        events = CLAUDE
    elif "--execute" in args:
        events = AMP
    elif "-p" in args and "streaming-json" in args:
        events = GROK
    else:
        print("unsupported fixture invocation", file=sys.stderr)
        return 2
    for line in events:
        print(line, flush=True)
    return 0


sys.exit(main(sys.argv[1:]))
