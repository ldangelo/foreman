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
| Jobsite crashed mid-FIRST-iteration, then `resume` | FAIL on 2026-10-23 (no session recorded; `Continue.` went to a blank claude: `UNKNOWN` for the code word, `js-3706471c...`, `js-ee21a4cc...`, bead foreman-cm8nv); **PASS after the fix** (2026-10-25, `failure_injection.sh jobsite-resume`, passed=17 failed=0 twice) | session bound 0.77 s into the iteration (`JobsiteSessionBound`), `kill -9`, restart pauses the jobsite as resumable (not `executor_lost`), resume with a prompt lacking the word: `answer.txt` holds the recall word, same claude session before and after (transcript 27 -> 61 lines); with the watcher disabled the same scenario FAILs (passed=2 failed=4). See `p2m2t-live-run.md` |
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
| Server restart (TERM and kill -9) while blocked | PARTIAL | the agent dies and the run is re-driven within ~15 s, asking again (new `tool_use_id`). The pre-restart request stays `requested`: two actionable rows; approving the stale one is `Done` in the UI/CLI but the log says `delivery_failed: :no_live_request`; after the run completes the stale request keeps the thread in "Waiting on you" until the sweeper: `run-91a7...` request 12:54:30.49 -> `ToolCallExpired reason timeout` 13:25:29.70 (30 min + one sweep), after which the thread became `idle`. Bead foreman-u0646 |
| Older claude CLI without `--permission-prompt-tool` | SIMULATED, fails loudly | `fake-old-claude.sh` (commander-style `error: unknown option`, exit 1) via `FOREMAN_CLAUDE_CLI`: run `failed` in seconds with `{:other, :execution}: execution: claude: %{"exit_status" => 1, ...}`; the flag name is only in the transcript; no fallback to the pause path. Bead foreman-dc618 |

## foreman-exofh: operator questions in the workspace (2026-10-26, UTC)
Private stack (`stack.sh up`, port 4841, database `foreman_e2e_wsq`, real claude `haiku`), UI driven with
`scripts/e2e/live_claude/questions_ui.mjs` (Playwright, headless Chromium on `http://localhost:4841`). A question is raised the way an agent
does it: `curl -X POST $API/webhooks/operator/ingest -d '{"question_id":..., "question":..., "agent_id":"<task id>"}'` (202), which
opens it under the task's live run and project. Commands: `questions_ui.mjs watch|answer|blank|keep|gone|state --base http://localhost:4841
--token <api token> --project lc [--question <id>] [--text <answer>]`; events read with `rpc.sh` (`EventStore.read_stream_forward`).
| Case | Result | Evidence |
|---|---|---|
| Open question shown | PASS | `Questions for you (1)`: text, `asked by <task>`, run id, time, labelled answer box; the thread card sits in "Waiting on you" |
| Answer typed in the browser reaches the running agent | PASS | `run-6022...` (claude, a 120 s tool call in flight); question `q-live-answer-5` answered 01:36:10.12: notice `Done: question.answer run-6022.../q-live-answer-5.`, card gone at once; `QuestionAnswered` text `Use postgres, version 16.`, `answered_by dashboard`; run stream `RunSteerQueued` (`message_id question:q-live-answer-5`, text `Answer to your question q-live-answer-5: Use postgres, version 16.`) then `RunSteerDelivered mode live`; the agent wrote `answer2.txt` = `Use postgres, version 16.` and committed it (branch `foreman/adhoc-36ea78ac5f608c04/run-6022...`) |
| Blank answer | PASS | whitespace through the real form (the browser's `required` lets it pass): notice `Write an answer first.` (error style), card stays, `status open`, no command sent |
| Typed answer kept while the page re-renders | FAIL, fixed in this change | `keep` probe: the textarea was `""` right after the focus moved (LiveView rewrites an unfocused input from the server markup). With `phx-update="ignore"` on the textarea: kept after the re-render and after a refresh caused by a new question |
| Answered over the CLI while the page is open | PASS | `foreman questions answer` at 01:40:11.115, card gone from the open page at 01:40:11.378 (the 250 ms refresh window) |
| Expired while the page is open | PASS | `question.expire` at 01:40:24.9, card gone at 01:40:25.2 |
| Unanswered question | PASS | three questions became `expired`, reason `timeout`, about 5 minutes after they were asked (`Approvals.Sweeper`; the question's own `timeout_ms`, default 5 min) and left the pane |
| Answer after the asking run ended | OBSERVED, not changed | the UI says `Done`, `QuestionAnswered` is recorded, the deliverer logs `questions: answer to q-a11y-1 was not delivered: {:run_terminal, "completed"}`; nothing warns the operator (the CLI and HTTP behave the same) |
| Accessibility | PASS | `ui_a11y.mjs` with open questions: axe 0 violations on the workspace (39 rules), the answer box is reached after 5 stops then the `Answer` button, idle 0 frames |
| pi | cannot ask | `Jido.Harness.RequestResolver.resolve(:pi, ...)`: `default`, `auto_approve` accepted; `prompt` and `auto_edit` -> `provider does not support normalized option value` (`field: :approval_mode`); `claude` `prompt` accepted. `pi --help` has no permission flag (`--approve` only trusts project-local files) |
UNVERIFIED: a pi run (it has nothing to raise), the delivery of a question outside any run (the deliverer publishes on
`com.foreman.reply.operator`; no subscriber in this stack), and the stale-submit race (a click in the 250 ms before the refresh removes the
card) is covered by the LiveView tests only.

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
PrFix claude resume (GitHub); the 30 min default approval timeout (a 30 s one was used); other providers; real GitHub;
the `approval_mode` default on hosts without `defaultMode: auto`.

## Cleanup
Server and notification sink stopped by recorded PID, database dropped, scratch removed, worktree removed after the PR was pushed.
