# Trying out Claude Projects

A short front door for someone testing the Projects feature set (epics E0-E16). It says what to run, in what order, what has been proven, and what is known not to work. Detail lives in the linked sections of `docs/user-guide.md`; the per-capability verdicts (C1-C13) are in `docs/acceptance/parity-audit.md`.

## Prerequisites

- A checkout of `main`, and `devbox run --` for every server and script command. Devbox pins Elixir 1.20.4 / OTP 28, Postgres, `jq`, `git` and `gh`; it does NOT provide `go`, `br` or `pi`, which must already be on your `PATH` (the e2e scripts check and exit 1 when one is missing).
- The `foreman` CLI: build it with `cd packages/foreman_cli && go build -o foreman ./cmd/foreman` and put the binary on `PATH` (or call it by path). Do not trust an old binary: rebuild after pulling.
- Postgres on `localhost:55432` (user and password `postgres`): `docker start foreman-postgres` (see `docs/dev-setup.md`).
- For anything that runs an agent: a provider credential for `pi` (the acceptance runs used minimax) or an authenticated `claude` CLI. The checks under "Checks that need no model" run without one.
- Use a scratch repository and **throwaway secrets**. See "Known issues", first bullet.

## Start

```bash
devbox run server            # http://127.0.0.1:4766
foreman project create --id try-it --path /path/to/scratch-repo
foreman doctor --project try-it
```

`foreman doctor` and `foreman project recommend try-it` list what is missing or misconfigured ([Set up a project](../user-guide.md#set-up-a-project)).

## Try, in this order

| Step | Do | Where it is described |
|---|---|---|
| 1 | Set a goal and instructions, write a memory topic, add a library folder, run `foreman project context try-it` to see what an agent would receive | [Instructions, memory and library](../user-guide.md#instructions-memory-and-library) |
| 2 | Open `http://127.0.0.1:4766/dashboard/projects/try-it?token=<FOREMAN_API_TOKEN>` (workspace) and `/settings` | [Project workspace (LiveView)](../user-guide.md#141-project-workspace-liveview) |
| 3 | Chat with the coordinator: `foreman project chat -m "..." try-it`; paste several tasks in one message and watch the threads appear | [Chat with the project coordinator](../user-guide.md#chat-with-the-project-coordinator) |
| 4 | `foreman thread list --project try-it`, then `steer`, `stop` and `resolve` a thread | [Work in threads, and steer them](../user-guide.md#work-in-threads-and-steer-them) |
| 5 | Create a schedule (`foreman project schedule create --project-id try-it --name hourly --every 1h --workflow fix --prompt "..."`; the minimum interval is 5m), pause and resume it in the Scheduled tab; edit it from Settings | [Project settings](../user-guide.md#project-settings) |
| 6 | Archive and reactivate the project | [Delete a project](../user-guide.md#delete-a-project), `docs/decisions/project-delete.md` |

## Checks that need no model

Each boots its own throwaway server and database, so run them one at a time. The first two rows were observed on `main` at `096e29d3` (2026-10-30); the third on the branch that added the two failing-paste scenarios; the fourth on `main` at `78b75fc3` plus the script itself (2026-10-30):

| Script | Result |
|---|---|
| `devbox run -- bash scripts/e2e/mcp_schedule_update.sh` | 84 passed, 0 failed (18 s) |
| `E2E_TICK_SLOTS=0 devbox run -- bash scripts/e2e/scheduled_tab_flow.sh` (headless Chromium) | 86 passed, 0 failed, 1 UNVERIFIED: the ~10 min wait that proves the ticker does not fire a deleted schedule is skipped (32 s) |
| `bash scripts/e2e/claude_projects/overlap.sh` (self-test, no stack) | 28 passed, 0 failed (`main` at `096e29d3` ran 26, before those two scenarios existed) |
| `devbox run -- bash scripts/e2e/notifier_live_negative.sh` (outbound HTTPS to `api.telegram.org` and `hooks.slack.com`; no model) | 82 passed, 0 failed, 0 UNVERIFIED (58 s) on `main` at `78b75fc3` plus the script; run once. Real Telegram and Slack hosts, deliberately fake credentials: **this proves no delivery**, see the C12 bullet below and `docs/acceptance/notifier-live-negative-run.md` |

The scripts that run a real agent (`claude_projects_flow.sh`, `project_archive_flow.sh`, `coordinator_live_actions.sh`, ...) and their recorded evidence are indexed in `docs/acceptance/README.md`.

## Known issues and gaps

- **The server log could contain what you type.** Phoenix logs request parameters at the default `:debug` level; a stored secret with a non-secret name (for example `DEPLOY_TARGET`) was redacted from every persisted store but appeared in the server log via chat text and MCP tool arguments. That is fixed in two layers: free-text param keys, the MCP `params` envelope and the dashboard `?token=` are filtered by name (`foreman-mw5rz`, PR #775; a live run showed 0 hits of the value in the server logs, 2026-10-31), and a `:logger` filter now redacts every stored secret value of 8+ characters from every log event whatever key carries it (`foreman-25sqf.1.1`; verified by tests including an HTTP request with the secret under an unlisted key, and live on 2026-10-31 with the by-name list reverted to `password`/`value` only, so the value filter alone protected the log: 0 hits in both server logs). It does not match a value shorter than 8 characters or a transformed copy, and a value set by hand in the secrets directory is covered after up to 30 s. Still use a scratch repository and throwaway secrets.
- **Related redaction gaps:** the `jido_harness` cache stores the agent's event stream on disk unredacted, including injected stored secret values; this is accepted by policy, like the agent's own session files (`foreman-4ohex`, see the Secrets row of the user guide). In the live redaction run the real coordinator may rewrite the memory topic before the later thread starts; then the "standing context carries the marker" check is UNVERIFIED rather than passed.
- **Coordinator live actions** (setup proposal, `apply N`, honest refusal) are proven live with `claude` (haiku) and, since 2026-10-31, with `pi` (`minimax/MiniMax-M2.7-highspeed`), including a refused operator-instructed invented quote and a refused omitted quote (`docs/acceptance/coordinator-live-actions-live-run.md`, `foreman-fas1b`). A model inventing a quote unprompted and a null cost are not reproduced live (tests only).
- **Context over 200k tokens** has not been exercised live (`foreman-gppjx`). The CLI's window assumption and auto-compaction threshold for a gateway model name were measured against a stand-in gateway (`docs/acceptance/context-window-probe.md`); the run through the real proxy awaits approval.
- **Telegram and Slack delivery (C12, `foreman-mivo7`): built, tested with fakes, NOT verified live.** The providers, the Slack URL rules and the `FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN` / `_CHAT_ID` and `FOREMAN_NOTIFY_SLACK_WEBHOOK_URL` wiring exist and are covered by tests against fake HTTP clients. `scripts/e2e/notifier_live_negative.sh` adds a live NEGATIVE-path check with fake credentials against the real hosts: Telegram answers a fake token 401 and Slack a fake webhook 404 (`no_team`), each recorded as a non-retryable `NotificationDeliveryFailed` (`telegram_http_401`, `slack_http_404`), the fake secrets are found nowhere in the event store, logs or `/api/doctor`, and a half-set Telegram pair aborts boot naming the variables. That shows real TLS, DNS, URL shape, status classification and redaction on the failure path. It does **not** show a message arriving: a first delivery with a real bot token and chat id, or a real Slack webhook, is still unproven and needs your own credentials (the audit keeps C12 PARTIAL until then). To try it yourself, set exactly one provider's variables on the server (a mix, or half of the Telegram pair, aborts boot) and read the outcome from the `NotificationDeliverySucceeded` / `NotificationDeliveryFailed` events (`foreman doctor` only counts what was enqueued).
- **Not built:** remote execution on your own machine (C13, `foreman-zn7de`). Do not test it; the audit marks it as a gap, not as verification debt.
- **By decision:** archiving or pausing a project between iterations does not stop a multi-iteration jobsite already running (`foreman-7p068`, `docs/decisions/project-delete.md`).
- **MCP errors:** a typed tool failure is a JSON-RPC error with an integer `error.code` and the typed reason in `error.data.code`. Domain failures without a dedicated code share `-32000` ([MCP tool integration](../user-guide.md#9-mcp-tool-integration)).

The full residual list is the bead `foreman-25sqf.1` (`br show foreman-25sqf.1`).
