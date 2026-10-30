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

Each boots its own throwaway server and database, so run them one at a time. The first two rows were observed on `main` at `096e29d3` (2026-10-30); the third on the branch that added the two failing-paste scenarios:

| Script | Result |
|---|---|
| `devbox run -- bash scripts/e2e/mcp_schedule_update.sh` | 84 passed, 0 failed (18 s) |
| `E2E_TICK_SLOTS=0 devbox run -- bash scripts/e2e/scheduled_tab_flow.sh` (headless Chromium) | 86 passed, 0 failed, 1 UNVERIFIED: the ~10 min wait that proves the ticker does not fire a deleted schedule is skipped (32 s) |
| `bash scripts/e2e/claude_projects/overlap.sh` (self-test, no stack) | 28 passed, 0 failed (`main` at `096e29d3` ran 26, before those two scenarios existed) |

The scripts that run a real agent (`claude_projects_flow.sh`, `project_archive_flow.sh`, `coordinator_live_actions.sh`, ...) and their recorded evidence are indexed in `docs/acceptance/README.md`.

## Known issues and gaps

- **The server log can contain what you type.** At the default `:debug` level Phoenix logs request parameters verbatim: chat text and the arguments of MCP tool calls (memory content). A stored secret with a non-secret name (for example `DEPLOY_TARGET`) was redacted from every persisted store but appeared in the server log. Tracked as `foreman-mw5rz` (P2, fix direction not chosen). Do not use real secrets or real data in a test project.
- **Related redaction gaps:** the `jido_harness` cache stores the agent's event stream unredacted, including injected stored secret values (`foreman-4ohex`); the end-to-end live check of value-based redaction (`foreman-ngky4`) cannot pass until the log leak above is fixed.
- **Coordinator live actions** (setup proposal, `apply N`, honest refusal) are proven live with `claude` (haiku). The `pi`/minimax leg and the invented-quote case are not (`foreman-fas1b`).
- **Context over 200k tokens** has not been exercised live (`foreman-gppjx`).
- **Not built:** Telegram and Slack delivery of notifications (C12, `foreman-mivo7`) and remote execution on your own machine (C13, `foreman-zn7de`). Do not test them; the audit marks them as gaps, not as verification debt.
- **By decision:** archiving or pausing a project between iterations does not stop a multi-iteration jobsite already running (`foreman-7p068`, `docs/decisions/project-delete.md`).
- **MCP errors:** a typed tool failure is a JSON-RPC error with an integer `error.code` and the typed reason in `error.data.code`. Domain failures without a dedicated code share `-32000` ([MCP tool integration](../user-guide.md#9-mcp-tool-integration)).

The full residual list is the bead `foreman-25sqf.1` (`br show foreman-25sqf.1`).
