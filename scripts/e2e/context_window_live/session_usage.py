#!/usr/bin/env python3
"""What a claude session file says about the size of every request (scripts/e2e/context_window_live.sh, bead foreman-gppjx).

  python3 session_usage.py FILE.jsonl [FILE.jsonl ...]     prints ONE JSON object on stdout

A claude session file is one JSON object per line. Every model response is an `assistant` record whose message.usage reports the
tokens that request consumed; a response with several content blocks is written as several consecutive records that repeat the
same usage, so consecutive assistant records with the same message id are ONE request. The context of a request is
input_tokens + cache_read_input_tokens + cache_creation_input_tokens (the whole conversation as the provider counted it).

Compaction is recorded by claude as a `system` record with subtype `compact_boundary` (compactMetadata: trigger, preTokens,
postTokens) and as a `user` record with isCompactSummary true; both are listed. The summarisation request itself is not an
assistant record, so the session file shows its size only as preTokens.

Output keys: files, requests (n, id, timestamp, model, context, input, cache_read, cache_write, output, sidechain, reads_before: how many
Read tool calls the session had made before that request, reads_in_request: how many it made in it), request_count, max_context,
sum_context (the contexts of the requests plus preTokens of every compaction: the input side of the whole session), sum_output,
compactions (timestamp, trigger, pre_tokens, post_tokens), summary_records, tool_calls (name -> count; a tool call is counted once
whatever the number of records that repeat it), read_files (the file names the Read tool was asked for, in order), max_part_ref (the
largest N of any `part-N` in any tool call's input: Read, Bash, ...), max_reads_per_request, final_text (the text of the last assistant
record that has any), models (model -> requests).
"""
import json
import os
import re
import sys


def usage_of(message):
    usage = (message or {}).get("usage") or {}
    return {
        "input": int(usage.get("input_tokens") or 0),
        "cache_read": int(usage.get("cache_read_input_tokens") or 0),
        "cache_write": int(usage.get("cache_creation_input_tokens") or 0),
        "output": int(usage.get("output_tokens") or 0),
    }


def analyse(paths):
    requests = []
    compactions = []
    summary_records = 0
    tool_calls = {}
    read_files = []
    final_text = ""
    last_assistant_id = None
    reads_so_far = 0
    max_part_ref = 0
    seen_tools = set()

    for path in paths:
        previous_was_assistant = False
        last_assistant_id = None
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                kind = record.get("type")
                if kind == "assistant" and record.get("message"):
                    message = record["message"]
                    ident = message.get("id")
                    use = usage_of(message)
                    same_request = previous_was_assistant and ident is not None and ident == last_assistant_id
                    if same_request and requests:
                        # the same response again: its usage can only grow while it streams
                        current = requests[-1]
                        for key in ("input", "cache_read", "cache_write", "output"):
                            current[key] = max(current[key], use[key])
                        current["context"] = current["input"] + current["cache_read"] + current["cache_write"]
                    else:
                        requests.append({
                            "n": len(requests) + 1, "id": ident, "timestamp": record.get("timestamp"), "model": message.get("model"),
                            "input": use["input"], "cache_read": use["cache_read"], "cache_write": use["cache_write"], "output": use["output"],
                            "context": use["input"] + use["cache_read"] + use["cache_write"], "sidechain": bool(record.get("isSidechain")),
                            "reads_before": reads_so_far, "reads_in_request": 0, "file": os.path.basename(path),
                        })
                    previous_was_assistant = True
                    last_assistant_id = ident
                    content = message.get("content")
                    if isinstance(content, list):
                        for block in content:
                            if not isinstance(block, dict):
                                continue
                            if block.get("type") == "tool_use":
                                tool_id = block.get("id")
                                if tool_id is not None and tool_id in seen_tools:
                                    continue
                                seen_tools.add(tool_id)
                                name = block.get("name")
                                tool_calls[name] = tool_calls.get(name, 0) + 1
                                refs = [int(n) for n in re.findall(r"part-(\d+)", json.dumps(block.get("input") or {}))]
                                max_part_ref = max([max_part_ref] + refs)
                                if name == "Read":
                                    target = str((block.get("input") or {}).get("file_path", ""))
                                    read_files.append(os.path.basename(target))
                                    reads_so_far += 1
                                    requests[-1]["reads_in_request"] += 1
                            elif block.get("type") == "text" and block.get("text"):
                                final_text = block["text"]
                    continue
                if kind == "user":
                    previous_was_assistant = False
                if kind == "system" and record.get("subtype") == "compact_boundary":
                    meta = record.get("compactMetadata") or {}
                    compactions.append({"timestamp": record.get("timestamp"), "trigger": meta.get("trigger"),
                                        "pre_tokens": meta.get("preTokens"), "post_tokens": meta.get("postTokens")})
                elif kind == "user" and record.get("isCompactSummary"):
                    summary_records += 1

    models = {}
    for request in requests:
        models[request["model"]] = models.get(request["model"], 0) + 1
    contexts = [r["context"] for r in requests]
    return {
        "files": [os.path.basename(p) for p in paths],
        "requests": requests,
        "request_count": len(requests),
        "max_context": max(contexts) if contexts else 0,
        "sum_context": sum(contexts) + sum(int(c.get("pre_tokens") or 0) for c in compactions),
        "sum_output": sum(r["output"] for r in requests),
        "compactions": compactions,
        "summary_records": summary_records,
        "tool_calls": tool_calls,
        "read_files": read_files,
        "final_text": final_text[:300],
        "models": models,
        "max_part_ref": max_part_ref,
        "max_reads_per_request": max([r["reads_in_request"] for r in requests], default=0),
    }


def main(argv):
    if not argv:
        print("usage: session_usage.py FILE.jsonl [FILE.jsonl ...]", file=sys.stderr)
        return 2
    print(json.dumps(analyse(argv)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
