# Live Claude paths and in-flight approvals (beads foreman-nufr9, foreman-exofh), 2026-10-23

Everything below was observed unless marked UNVERIFIED or SIMULATED. Times are UTC, 2026-10-23.
Companions: `parity-gaps-live-run.md` (nufr9, first pass), `inflight-approvals-live-run.md` (exofh, first pass),
`live-steering-live-run.md`, `review-claude-reviewer-live-run.md`.

## Environment
- Worktree `foreman-wt/liveclaude` off origin/main `126ff019`. A PRIVATE stack from `scripts/e2e/live_claude/stack.sh`
  (reuses `scripts/e2e/claude_projects/lib.sh`): real `mix run` server (dev env) on port 47811, private Postgres database
  `foreman_e2e_claude_projects_liveclaude` (dropped afterwards), scratch git repo + local bare origin + own `br` 0.6.0 database
  under `foreman-wt/liveclaude-scratch`, `HOME` and `TMPDIR` redirected there (symlinks `~/.claude`, `~/.claude.json`,
  `~/Library/Keychains`), `CLAUDECODE*` and API-key variables unset for the server. Real `claude` 2.1.308, model alias `haiku`.
- Workflows (`scripts/e2e/live_claude/workflows/`): `claudeedit` (`provider: claude`, `approval_mode: auto_approve`) and
  `claudeprompt` (`approval_mode: prompt`, the in-flight path). Coordinator `claude/haiku`; reviewer
  `FOREMAN_REVIEW_PROVIDER=claude FOREMAN_REVIEW_MODEL=haiku`. Jobsites: `FOREMAN_JOBSITES_ALLOW_REMOTE_START=true`, host sandbox.
- UI driven with Playwright 1.64.1 / Chromium 156 (`scripts/e2e/live_claude/approvals_ui.mjs`, headless) on
  `http://localhost:47811` (not `127.0.0.1`: the dev origin check refuses the LiveView socket for it). What the agent saw is
  read from Claude Code's own session files (`~/.claude/projects/<cwd>/<session>.jsonl`), not from Foreman.
- Host note: `~/.claude/settings.json` has `defaultMode: auto` and a Bash hook that blocks a standalone `sleep N`
  ("use run_in_background"), so a `sleep` task ends the claude turn at once; `python3 -c 'import time; time.sleep(60)'` keeps the
  tool call (and the live input) open.

## Commands
```
devbox run -- bash scripts/e2e/live_claude/stack.sh up|restart|crash|stop|start|down    # crash = kill -9 the server tree
foreman run submit --project-id lc --workflow claudeprompt --prompt "Use the Write tool to create hello.txt ..."
foreman project chat --timeout 4m -m "Start a thread ... Use the claudeedit workflow." lc
foreman thread stop --reason "..." run:<id>      foreman approvals list --run <id> --all --format json
node scripts/e2e/live_claude/approvals_ui.mjs approve|deny|stop|state --base http://localhost:47811 --token <api token> --project lc [--call <tool_call_id>]
POST /api/jobsites (spec: provider claude, strategy branch, sandbox host)   POST /api/jobsites/:id/resume
E2E_APPROVAL_TIMEOUT_MS=30000 stack.sh restart        E2E_EXTRA_ENV=FOREMAN_CLAUDE_CLI=<fake-old-claude.sh> stack.sh restart
```

## foreman-nufr9: Claude provider paths
| Path | Result | Evidence |
|---|---|---|
| Claude coordinator turn starts a thread | PASS | chat 12:55:59; reply 12:56:05.7 (6.5 s), `CoordinatorActionRecorded executed`, `CoordinatorTurnCompleted actions=1 executed=1`; run `run-e5fd...` (claude, session `eae04320`) completed; verdict reported back into the chat |
| Second coordinator turn routes a follow-up to the RUNNING thread; same claude session | PASS | chat 12:59:19; `RunSteerQueued` 12:59:25.179, `RunSteerDelivered mode live` .182, `RunSteerConsumed delivery live` 13:00:03.757 (after the in-flight 60 s tool call); one `WorkerStarted`, ONE provider session `61ec038c`; `slow2.txt` and `extra3.txt` committed; Claude's session file holds the whole conversation |
| Follow-up when live input is already closed | PASS (fallback) | `run-bf9a...` (claude ended its turn on a background task): `no live steering (:input_closed); pausing`, `RunPaused`/`RunResumed`, `RunSteerConsumed delivery prompt`, a NEW session (`cc13e06b` -> `b80cfe14`) that re-runs the phase prompt with the steer appended; it does NOT carry the first session's history (no `--resume`). Both files committed |
| Claude reviewer | PASS | every terminal run reviewed: `ReviewRecorded evaluator agent:claude model haiku`; archive `manifest.json request.md transcript.jsonl diff.patch changed-files.txt analysis.json analysis.md evaluator-transcript.jsonl`, `capture_errors []`, `transcript_source run_logs`. Failed/denied/cancelled runs reviewed too (`not_met` for the old-CLI failure). Bead path: `lc-uqa` got `# Review verdict: met` (scores 5/3/5/4) as a comment from a claude review |
| Coordinator turn interrupted by a server crash | PASS | `TurnStarted a1` 13:04:49.95, `kill -9` 13:04:51, after restart `TurnFailed error_code interrupted` 13:04:56.3, `TurnStarted a2`, reply 13:05:01.157, `TurnCompleted`; no duplicate reply |
| Workflow thread running when the server dies (TERM and kill -9) | PASS (re-run, new session) | run re-driven ~15 s after restart with a new claude process; `provider_sessions` is `[]` while a worker runs (the id is bound when the worker run ends), so a crash loses it and the phase re-runs from its prompt |
| Claude `--resume` inside a jobsite (`max_iterations 2`) | PASS | `js-cf03cf67...`: both iterations carry session `3579fa6f`; one Claude session file holds both prompts |
| Jobsite crashed mid-FIRST-iteration, then `resume` | FAIL | no session id recorded; resume sends `Continue.` (or the custom prompt) to a fresh claude: `UNKNOWN` for a code word asked about earlier; default prompt: "I don't see any work in progress", jobsite `completed`, worktree untouched (`js-3706471c...`, `js-ee21a4cc...`). Bead foreman-cm8nv |
| PrFix claude `resume_session` (fix threads) | UNVERIFIED | GitHub/PR path, owned by the LiveGithub slice; the jobsite-door `--resume` above is the same harness mechanism |

## foreman-exofh: in-flight approvals (`claudeprompt`, Write call)
| Case | Result | Evidence |
|---|---|---|
| UI Approve click on a live run | PASS | `run-4948...`: row visible 2.3 s after page load; request 12:39:00.19; click 12:39:00.82 -> `Done: tool.approve ...`; claude `tool_result` "File created successfully" 12:39:00.93; same session `8dc03a30`; `hello.txt` committed; request `finished`, `decided_by dashboard`. Screenshot `live-approvals-ui-approve.png` |
| UI Deny; exact denial text | PASS | `tool_result` (`is_error true`): `The operator denied permission to use the `Write` tool. Do not use it; continue without it, or say plainly what you cannot do.` The agent quoted it back; no file; run failed `{:permission_denied, ["Write"]}: run ended with status completed` (documented) |
| Stop while blocked, CLI | PASS | `foreman thread stop` 12:41:46.7: run `cancelled`, request `expired reason run_ended` 12:41:46.85, agent saw `The run ended before the `Write` tool was approved.` then `[Request interrupted by user]`, no `claude` process left, no file |
| Stop while blocked, UI | FAIL, fixed in this PR | the card of a blocked run offered only `Resolve` (`Overview.ThreadCard.actions`). After the fix: `["Stop","Resolve"]`; UI Stop + Confirm stop -> run `cancelled`, request `expired run_ended` (13:12:38) |
| Block ~41 s, then approve (UI) | PASS | requested 12:42:38.9, approved 12:43:20.36; one `Write`, same session, `slow.txt` committed |
| Block longer than 60 s | FAIL, fixed in this PR | the Inflight waiter registry went from 1 entry (12:48:58) to 0 (12:49:08), i.e. ~60 s after the request (Cowboy `idle_timeout`: no data RECEIVED; progress events sent do not count, `reset_idle_timeout_on_send` is off). Approve at 118 s (12:50:04): UI "Done", event `ToolCallFinished outcome "delivery_failed: :no_live_request"`. Claude dropped the call at 12:50:36.10 (+150 s: `transport dropped mid-call; response for tool "approve" was lost`) and the model re-asked (new request 12:50:38.9). After the fix, live: approve at 100.0 s (13:10:36 -> 13:12:16) and at 172.8 s (13:10:40 -> 13:13:33): `outcome "delivered"`, same session, files committed |
| Unanswered past `approval_timeout_ms` | PASS | `E2E_APPROVAL_TIMEOUT_MS=30000`: requested 12:52:40.267, `ToolCallDenied decided_by system reason timeout` 12:53:10.281 (30.01 s); agent saw `Nobody answered the request to use the `Write` tool in time, so it was denied. Do not use it; continue without it, or say plainly what you cannot do.`; run failed `permission_denied`. The 30 min default is UNVERIFIED (not waited) |
| Server restart (TERM and kill -9) while blocked | PARTIAL | the agent dies and the run is re-driven within ~15 s, asking again (new `tool_use_id`). The pre-restart request stays `requested`: two actionable rows; approving the stale one is `Done` in the UI/CLI but the log says `delivery_failed: :no_live_request`; after the run completes the stale request keeps the thread in "Waiting on you" until the 30 min sweeper (`run-91a7...`: still `requested` 20 min later; the sweep itself UNVERIFIED if not noted below). Bead foreman-u0646 |
| Older claude CLI without `--permission-prompt-tool` | SIMULATED, fails loudly | `fake-old-claude.sh` (commander-style `error: unknown option`, exit 1) via `FOREMAN_CLAUDE_CLI`: run `failed` in seconds with `{:other, :execution}: execution: claude: %{"exit_status" => 1, ...}`; the flag name is only in the transcript; no fallback to the pause path. Bead foreman-dc618 |

## Defects
Fixed in this PR (failing test first): (1) 60 s Cowboy idle timeout kills a blocked prompt:
`AgentPermissionController` lifts the idle timeout of that one stream (`:cowboy_req.cast(set_options)`, `approval_timeout_ms` + 60 s);
test `agent_permission_listener_test.exs` drives a real Cowboy listener (idle timeout 250 ms) and fails without the fix
("Cowboy closed the connection after its idle timeout"). (2) `Overview.ThreadCard` offers `run.cancel` for a running workflow
thread waiting on an approval; assertion added to `overview_test.exs` (was `["thread.resolve"]`).
Filed: foreman-u0646 (orphaned in-flight requests), foreman-dc618 (old CLI), foreman-cm8nv (jobsite resume without a session).
Observations, not filed: run logs join claude stream deltas with newlines (transcript text reads "The\n Write call\n was refused");
the failure text is a raw Elixir term (`{:permission_denied, ["Write"]}: ...`).

## Not done / UNVERIFIED
PrFix claude resume (GitHub); the 30 min default timeout; the sweeper's 30 min expiry of an orphaned request (see note);
other providers; real GitHub; the `approval_mode` default on hosts without `defaultMode: auto`.

## Cleanup
Server and notification sink stopped by recorded PID, database dropped, scratch removed, worktree removed after the PR was pushed.
