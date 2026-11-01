#!/usr/bin/env python3
"""Everything scripts/e2e/context_window_live.sh needs from the LiteLLM proxy, with the key handled INSIDE this process only
(bead foreman-gppjx). The file named by the environment variable CW_LITELLM_FILE holds `url: <base url>` and `key: <key>` lines;
the key is read here, sent as an Authorization header over the socket, and is never printed, never put on a command line and
never written anywhere. Error text is passed through `redact` first.

  litellm_tool.py check                       health and readiness, the model aliases the proxy serves
  litellm_tool.py model-info ALIAS            the limits and prices the proxy declares for ALIAS (numbers only)
  litellm_tool.py smoke ALIAS                 ONE tiny POST /v1/messages (max_tokens 16): the endpoint exists, ALIAS is accepted verbatim,
                                              the reply is Anthropic-shaped and its usage block reports input tokens (shape and numbers only)
  litellm_tool.py spend ALIAS SINCE [UNTIL]   the proxy's own per-request log for ALIAS from SINCE (UTC ISO-8601) to UNTIL:
                                              request count, max/sum prompt tokens, completion tokens, spend, one row per request
  litellm_tool.py scan [--exclude PATH]... [--delete] ROOT...   count the files under each ROOT that contain the key (raw, hex or
                                              URL-encoded); prints counts and file names, never the key or the matching text;
                                              --delete removes the files that contain it (for evidence copies, never for a work tree)

Only `smoke` sends anything but a GET. Exit status 0, or 1 when the proxy does not answer as expected.
"""
import binascii
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

TIMEOUT = float(os.environ.get("CW_PROXY_TIMEOUT", "120"))


def credentials():
    path = os.environ.get("CW_LITELLM_FILE")
    if not path:
        raise SystemExit("CW_LITELLM_FILE is not set")
    fields = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            name, sep, value = line.partition(":")
            if sep:
                fields[name.strip()] = value.strip()
    if not fields.get("url") or not fields.get("key"):
        raise SystemExit("%s must hold a `url:` line and a `key:` line" % os.path.basename(path))
    return fields["url"].rstrip("/"), fields["key"]


URL, KEY = credentials()


def redact(text):
    return str(text).replace(KEY, "<KEY>")


def get(path, auth=True):
    request = urllib.request.Request(URL + path, headers={"Authorization": "Bearer " + KEY} if auth else {})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except Exception as error:  # a refused connection, a timeout, DNS: the caller gets a status of None and the reason
        return None, redact(repr(error)).encode()


def get_json(path, auth=True):
    status, body = get(path, auth)
    try:
        return status, json.loads(body)
    except ValueError:
        return status, redact(body[:300].decode("utf-8", "replace"))


def cmd_check(_args):
    live_status, live = get_json("/health/liveliness", auth=False)
    ready_status, ready = get_json("/health/readiness", auth=False)
    models_status, models = get_json("/v1/models")
    ids = [m.get("id") for m in models.get("data", [])] if isinstance(models, dict) else []
    print(json.dumps({"url": URL, "liveliness": [live_status, live], "readiness": [ready_status, ready], "models_status": models_status, "models": ids}))
    return 0 if live_status == 200 and ready_status == 200 and models_status == 200 else 1


def cmd_model_info(args):
    alias = args[0]
    status, body = get_json("/model/info")
    if status != 200 or not isinstance(body, dict):
        print(json.dumps({"status": status, "error": body if isinstance(body, str) else "unexpected body"}))
        return 1
    for entry in body.get("data", []):
        if entry.get("model_name") != alias:
            continue
        info = entry.get("model_info") or {}
        keep = ("max_input_tokens", "max_output_tokens", "max_tokens", "input_cost_per_token", "output_cost_per_token",
                "cache_read_input_token_cost", "supports_prompt_caching", "supports_function_calling", "litellm_provider", "mode")
        out = {k: info.get(k) for k in keep if k in info}
        out["alias"] = alias
        out["upstream_model"] = (entry.get("litellm_params") or {}).get("model")
        print(json.dumps(out))
        return 0
    print(json.dumps({"error": "alias not served", "alias": alias}))
    return 1


def cmd_smoke(args):
    alias = args[0]
    body = {"model": alias, "max_tokens": 16, "messages": [{"role": "user", "content": "Reply with the single word: ok"}]}
    request = urllib.request.Request(URL + "/v1/messages", data=json.dumps(body).encode(), method="POST", headers={
        "Authorization": "Bearer " + KEY, "content-type": "application/json", "anthropic-version": "2023-06-01"})
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read()
    except Exception as error:
        print(json.dumps({"status": None, "error": redact(repr(error))}))
        return 1
    try:
        reply = json.loads(raw)
    except ValueError:
        print(json.dumps({"status": status, "error": "not JSON", "head": redact(raw[:120].decode("utf-8", "replace"))}))
        return 1
    if not isinstance(reply, dict):
        print(json.dumps({"status": status, "error": "not a JSON object"}))
        return 1
    usage = reply.get("usage") if isinstance(reply.get("usage"), dict) else {}
    content = reply.get("content")
    print(json.dumps({
        "status": status, "seconds": round(time.time() - started, 2), "type": reply.get("type"), "role": reply.get("role"), "model": reply.get("model"),
        "stop_reason": reply.get("stop_reason"), "content_block_types": [b.get("type") for b in content] if isinstance(content, list) else None,
        "usage": {k: usage.get(k) for k in ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")},
        "error": redact(json.dumps(reply.get("error")))[:200] if reply.get("error") else None,
    }))
    return 0 if status == 200 else 1


def parse_time(text):
    text = text.strip().replace("Z", "+00:00")
    stamp = datetime.fromisoformat(text)
    return stamp if stamp.tzinfo else stamp.replace(tzinfo=timezone.utc)


def cmd_spend(args):
    alias, since = args[0], parse_time(args[1])
    until = parse_time(args[2]) if len(args) > 2 else datetime.now(timezone.utc) + timedelta(seconds=5)
    start_date = since.strftime("%Y-%m-%d")
    end_date = (until + timedelta(days=1)).strftime("%Y-%m-%d")
    status, body = get_json("/spend/logs?start_date=%s&end_date=%s&summarize=false" % (start_date, end_date))
    if status != 200 or not isinstance(body, list):
        print(json.dumps({"status": status, "error": body if isinstance(body, str) else "unexpected body"}))
        return 1
    rows = []
    for row in body:
        if row.get("model_group") != alias:
            continue
        try:
            started = parse_time(row["startTime"])
        except (KeyError, ValueError):
            continue
        if started < since - timedelta(seconds=2) or started > until:  # two seconds of slack: the script's clock and the proxy's are the same host's, the log's timestamps are not
            continue
        rows.append({"t": row["startTime"], "prompt": int(row.get("prompt_tokens") or 0), "completion": int(row.get("completion_tokens") or 0),
                     "spend": float(row.get("spend") or 0), "status": row.get("status"), "duration_ms": row.get("request_duration_ms")})
    rows.sort(key=lambda r: r["t"])
    ok = [r for r in rows if r["status"] == "success"]
    print(json.dumps({
        "alias": alias, "since": args[1], "count": len(rows), "success": len(ok), "failed": len(rows) - len(ok),
        "max_prompt_tokens": max([r["prompt"] for r in rows], default=0), "sum_prompt_tokens": sum(r["prompt"] for r in rows),
        "sum_completion_tokens": sum(r["completion"] for r in rows), "sum_spend": round(sum(r["spend"] for r in rows), 6), "rows": rows,
    }))
    return 0


def variants():
    raw = KEY.encode("utf-8")
    return [raw, binascii.hexlify(raw), urllib.parse.quote(KEY, safe="").encode("ascii")]


def file_hits(path, needles):
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError:
        return 0
    return sum(1 for needle in needles if needle in data)


def cmd_scan(args):
    excludes, roots, delete, it = [], [], False, iter(args)
    for arg in it:
        if arg == "--exclude":
            excludes.append(os.path.realpath(next(it)))
        elif arg == "--delete":
            delete = True
        else:
            roots.append(arg)
    needles = variants()
    total = 0
    for root in roots:
        scanned, hits = 0, []
        if not os.path.exists(root):
            print("scan %s: missing" % root)
            continue
        walk = [(os.path.dirname(root), [], [os.path.basename(root)])] if os.path.isfile(root) else os.walk(root)
        for directory, dirs, files in walk:
            dirs[:] = [d for d in dirs if os.path.realpath(os.path.join(directory, d)) not in excludes]
            for name in files:
                full = os.path.join(directory, name)
                if os.path.islink(full) or os.path.realpath(full) in excludes:
                    continue
                scanned += 1
                if file_hits(full, needles):
                    hits.append(os.path.relpath(full, root) if os.path.isdir(root) else name)
                    if delete:
                        os.remove(full)
        total += len(hits)
        print("scan %s: %d file(s) scanned, %d with the key%s%s" % (root, scanned, len(hits), " (deleted)" if delete and hits else "", (": " + ", ".join(hits[:8])) if hits else ""))
    print("scan total: %d file(s) with the key" % total)
    return 0


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    commands = {"check": cmd_check, "model-info": cmd_model_info, "smoke": cmd_smoke, "spend": cmd_spend, "scan": cmd_scan}
    if argv[0] not in commands:
        print("unknown command %s" % argv[0], file=sys.stderr)
        return 2
    return commands[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
