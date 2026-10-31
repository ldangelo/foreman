# Telegram and Slack notifications: live negative-path run (C12, `foreman-mivo7`)

**This run delivered nothing and proves no delivery.** It used deliberately fake credentials against the real Telegram and Slack hosts. A successful delivery (a real bot token and chat id, a real Slack incoming webhook, the message arriving) was NOT run: the credentials belong to the owner, and `foreman-mivo7` stays open for them. The audit row C12 stays PARTIAL (`parity-audit.md`, "Update 2026-10-30 (foreman-mivo7, negative path only)").

## Environment

| | |
|---|---|
| Script | `scripts/e2e/notifier_live_negative.sh` (shared harness `scripts/e2e/claude_projects/lib.sh`) |
| Code | `main` at `78b75fc3` plus the script and docs of this change; the providers and wiring are unchanged |
| Host | macOS arm64, devbox shell (Elixir 1.20.4 / OTP 28), Postgres `localhost:55432`, outbound HTTPS to `api.telegram.org` and `hooks.slack.com` |
| Stack | throwaway server, own port 4860, own database `foreman_e2e_notifier_live_negative`, own `HOME` under the work dir; no model, no agent (`E2E_REVIEW_ANALYSIS=0`); the harness's local webhook variables blanked (one provider per node) |
| Command | `HEAVY_TESTDB=0 ~/.omp/foreman-ledger/heavy.sh devbox run -- bash scripts/e2e/notifier_live_negative.sh` (the machine-wide heavy-process lock) |
| Runs | one; it passed first time |
| Result | `passed=82 failed=0 unverified=0 wall=58s`, exit 0 |

The credentials are random per run and never printed or written down: a Telegram token `<10 digits>:<35 characters>` and chat id `-100<10 digits>`, and a Slack URL `https://hooks.slack.com/services/T00000000/B00000000/<24 characters>`. The transcript below carries no value of either (the script replaces them by labels before it prints a line).

## How the event is forced without a model

A run of the scratch workflow `broken-model` (a pi phase whose model `minimax/no-such-model-e2e` does not exist) is submitted with `foreman run submit`. The kickoff preflight refuses it before any agent starts (`pi --list-models` answers locally), the run is `failed` within a second, and `RunFailed` maps to a `failure` notification (`S/notifier/mapping.ex`, first row). Observed failure reason, both stages:

```
{:provider_model_preflight_failed, [%ForemanServer.Workflow.PreflightFailure{phase: "edit", provider: :pi, class: :model_not_found, model: "minimax/no-such-model-e2e", model_source: :phase_declared, detail: nil}]}
```

## Observed, per provider (transcript lines of the run)

Telegram (server started with `FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN` and `FOREMAN_NOTIFY_TELEGRAM_CHAT_ID`):

```
doctor notifier row before: {"detail":"0 enqueued since the server started.","id":"notifier","status":"ok","title":"Notifications are on (telegram)"}
telegram run run-a3627dc1683505c5c0d12a23a369f9e9: enqueued=1 attempted=1 failed=1 succeeded=0
enqueued: {"event_class":"failure","provider":"telegram","subject":"Run failed"}
failed:   {"provider":"telegram","retryable":false,"reason":"telegram_http_401: {\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}"}
doctor notifier row after: {"detail":"1 enqueued since the server started.","id":"notifier","status":"ok","title":"Notifications are on (telegram)"}
```

Slack (same database, server restarted with `FOREMAN_NOTIFY_SLACK_WEBHOOK_URL` and no Telegram variable):

```
doctor notifier row before: {"detail":"0 enqueued since the server started.","id":"notifier","status":"ok","title":"Notifications are on (slack)"}
slack run run-c9bf20e04d9622020281aa78b1dbb5c4: enqueued=1 attempted=1 failed=1 succeeded=0
enqueued: {"event_class":"failure","provider":"slack","subject":"Run failed"}
failed:   {"provider":"slack","retryable":false,"reason":"slack_http_404: no_team"}
doctor notifier row after: {"detail":"1 enqueued since the server started.","id":"notifier","status":"ok","title":"Notifications are on (slack)"}
```

The events were read from the event store (`event_store_dump.exs`, run on the server node), not from a log. The statuses are the real hosts' answers on 2026-10-30, the same as a prior `curl` probe with invented credentials (Telegram 401 Unauthorized, Slack 404 `no_team`).

## What each check shows

| Check | Expected | Observed |
|---|---|---|
| Real status classification | a fake token is 401, a fake webhook 404; both final (`retryable? false`), no redelivery, no `NotificationDeliverySucceeded` | as expected, per stage: one enqueue, one attempt, one failure, 0 successes (counted 12 s after the first outcome; the dispatcher redelivers a retryable failure only on a restart catch-up, which this run did not exercise) |
| Doctor row | names the provider, no destination | `Notifications are on (telegram)` / `(slack)`; 0 hits of `api.telegram.org` and `hooks.slack.com` in the answer; 0 hits of any secret |
| Secrets, events table | 0 | the token (46 characters), its 35-character secret part, the chat id, the Slack URL (77), its 24-character secret segment and `T00000000/B00000000`: 0 rows each, bytes of `data` and `metadata` of EVERY event |
| Secrets, server stdout log and every file under the work dir (file logs, webhook capture, scratch repo, run files) | 0 | 0 hits each, per stage; one file log under `home/.foreman/logs` |
| Secrets, whole-database `pg_dump` (text and the hex of bytea) | 0 | 0 hits each (37 639 bytes after the Telegram stage, 68 287 after the Slack stage) |
| Positive controls (the searches can see) | the run id found in the events table, the server log and the dump; the readiness marker in the log | found: 14 and 17 event rows, 15 and 16 log hits, 1 dump hit each stage |
| Local webhook sink | empty (the harness's own webhook is blanked) | 0 lines |
| Boot refusal, token only | `mix run` aborts, documented text, no value | exit 1, `** (RuntimeError) FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN and FOREMAN_NOTIFY_TELEGRAM_CHAT_ID must be set together`; 0 hits of the token |
| Boot refusal, chat id only | same | exit 1, the same text; 0 hits of the chat id |
| Boot refusal, Telegram pair plus Slack URL | aborts naming the variables | exit 1, `notification variables for more than one provider are set (FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN, FOREMAN_NOTIFY_TELEGRAM_CHAT_ID, FOREMAN_NOTIFY_SLACK_WEBHOOK_URL); the node has one notification provider - unset all but one provider's variables`; 0 hits of any value |
| Control: the full pair | config loads | exit 0 |

## What this proves

- The Telegram and Slack providers reach the real hosts over real TLS and DNS with the right URL shape: both hosts answered in the shape the providers parse (an HTTP status and a short body).
- The status classification works against the real answers: 401 and 404 are non-retryable and produce one `NotificationDeliveryFailed` carrying `telegram_http_401` / `slack_http_404`.
- A failed delivery, and the boot refusals, leave the fake secrets out of the event store, the whole database, the server logs, the work directory and the doctor answer.
- The doctor row shows the provider and no destination.

## What it does NOT prove (UNVERIFIED)

- **A delivery.** No `NotificationDeliverySucceeded` was ever produced; nothing reached a chat or a channel. The 2xx path against the real hosts, the rendered message in a real chat (Telegram `sendMessage`, Slack incoming-webhook text), rate limits and the `429` / `5xx` retry path stay unrun live. `foreman-mivo7` stays open until the owner's credentials run them.
- **That the redactor worked live.** Neither host echoed the credential back: the Telegram 401 body is `{"ok":false,"error_code":401,"description":"Unauthorized"}` and the Slack 404 body is `no_team`. The zero-hit result shows no leak on this failure path; it does not show `Redactor` removing a credential from a text that contains one (that is covered by unit tests only).
- A transport failure (an unreachable host, which is retryable), a Telegram 400 for a wrong chat id with a valid token, and a Slack webhook of a real workspace: none was exercised.
- Desktop notifications (excluded by design) and the generic webhook (live-verified elsewhere, `claude-projects-live-run.md`, ACC 7b).

## Re-run

```
devbox run -- bash scripts/e2e/notifier_live_negative.sh
```

It needs outbound HTTPS to both hosts. If a host changes what it answers a fake credential, the script prints the new answer as a FAIL with the reason text rather than passing. A failing run keeps its evidence under `tmp/e2e-evidence/nln-*/`; the fake values are in it only if a leak is the failure.
