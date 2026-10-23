# Claude Projects parity audit (C1-C13)

Audit of `main` @ `13cf5e00` (re-run for bead E16-S9 after the scripted acceptance; first written at `33d7cb24`) against the capability list in the parity plan (`docs/plans/claude-projects-parity-plan.md`, untracked). Method: entry points were checked by grep at the cited file:line; behaviour claims come from code reading, the committed tests' existence, `docs/acceptance/claude-projects-live-run.md` (the first live run, "ACC"), `docs/acceptance/claude-projects-acceptance-2026-10-22.md` (the scripted acceptance, "ACC2"), `docs/acceptance/parity-gaps-live-run.md` ("LV"), `docs/acceptance/review-*.md` and `docs/lessons/multi-repo-e2e-2026-10-21.md` ("MR"). "LIVE" below always means "observed in ACC, ACC2, LV, MR or a review acceptance run", nothing else. File:line citations were not re-verified against `13cf5e00` except where a row says so. Test suites were not re-run here.

Status vocabulary: **LIVE** = shipped and observed in a live run; **TESTED** = shipped, covered by tests only; **PARTIAL** = something named is missing; **NOT SHIPPED**.

## Live-evidence caveats that apply to everything

- The default live provider is `pi` with `minimax/MiniMax-M2.7-highspeed` (ACC Environment; MR "Only `pi` + MiniMax was run"). The first live run had an expired Claude OAuth; `docs/acceptance/parity-gaps-live-run.md` ("LV", 2026-10-22) ran the real `claude` CLI (`haiku`) for the coordinator, a workflow-door thread, the reviewer, approval modes and steer resume, and `docs/acceptance/review-claude-reviewer-live-run.md` ran the Claude reviewer. Claude paths not named in LV are unverified.
- `gh` was **faked** (ACC, MR). Every PR / CI / merge observation is against a local bare repo and a scripted fake; real GitHub behaviour is unverified.
- ACC states: "Open P1 defects after this run: F1, F3. Acceptance is therefore **not declared fully passed**." Both have since been closed (see Bugs), the fixes are test-verified; F1 (crash recovery) is now also live-verified (ACC2); F2/F4/F5/F7 are explicitly "not live" per their close comments; F3 was live-verified.
- Scripted acceptance (**ACC2**, `docs/acceptance/claude-projects-acceptance-2026-10-22.md`): `claude_projects_flow.sh` and `failure_injection.sh` against a real throwaway server, the real CLI, a real `pi` + MiniMax agent, local bare origin and local webhook sink. Only targeted unit tests plus these scripts were run, not the full suite.

## Whole-plan table

| Cap | Claude Projects behaviour | Epics | Status | Evidence |
|---|---|---|---|---|
| C1 | Project goal, instructions, model/effort | E1, E3 | **LIVE** (settings, injection); model reaching a Claude run LIVE for `haiku` only (LV) | ACC step 1 (settings via CLI), 7d; ACC2 steps 1, 3 (instruction token reached `notes.txt`); limits 422 (ACC "Exceed limits") |
| C2 | Project memory | E2 | **LIVE** for operator-written memory (re-verified by script) and agent-written memory through MCP (LV) | ACC 7d (`PINEAPPLE-42`); ACC2 step 3; LV foreman-pz1ie section |
| C3 | Repos, Library, thread-produced files | E5, E12 | Library **LIVE** (re-verified by script); multi-repo **LIVE** (fake gh, pi only) including env contract, thread self-add and fanout (LV); thread-produced files **LIVE** (LV) | ACC 7c (`7319-ZEBRA`); ACC2 step 3 (library token reached `notes.txt`); MR 110 assertions; LV foreman-pz1ie / foreman-he4yf sections |
| C4 | Environment: env vars, secrets, setup script, network | E0-S3, E4 | **LIVE** (env, secrets redaction, setup script, docker network policy); in-container blocking UNVERIFIED | LV foreman-8vf0s section |
| C5 | Coordinator routing and tuning | E15 | **LIVE** (pi); tuning/"remember" PARTIAL-evidence; crash recovery live (server crash) with one open duplicate-action risk | ACC steps 2, 6, failure injection; ACC2 chat, provider-down, `coordinator-crash`, `server-crash` |
| C6 | Overview groups, tabs, attention | E7, E16 | **LIVE** (groups, PR, Library tabs); Scheduled tab TESTED; CI-failing-in-Waiting fixed (foreman-c1i34) | ACC 2, 4c, 7f; ACC2 asserts Working / Waiting on you / Resolved group membership through the API |
| C7 | Thread control: transcript, steer, approvals, stop, resolve | E6, E8 | steer/stop/resolve/reopen **LIVE** (scripted, re-run); approvals: Claude `approval_mode: prompt` asks in flight, **LIVE** approve (CLI) / deny (UI) / timeout (`docs/acceptance/inflight-approvals-live-run.md`); pi keeps post-hoc pause (no per-call approvals) | ACC 3, 5; ACC2 step 4 (steer obeyed, transcript shows `operator/steer`, stop -> cancelled, resolve -> Resolved group); approvals never raised (pi has none) |
| C8 | PR lifecycle: watch, fix CI, comments, conflicts, merge | E9 | **LIVE with FAKED gh**; PARTIAL (UI buttons added, foreman-i6kws; real GitHub unverified) | ACC 4a-4c, 5 |
| C9 | Scheduled tasks | E11 | **LIVE** (cron fired, pause/resume/delete); Scheduled tab not looked at | LV foreman-8vf0s section |
| C10 | Adopt existing session; setup recommendations | E13 | **LIVE** (move/mint/continue, recommend) | LV foreman-8vf0s section |
| C11 | Pause/archive/delete; usage; thread cap | E1, E14 | pause, caps, rollup, per-thread usage **LIVE**; archive/delete TESTED | ACC 7a, 7e, "Exceed limits"; ACC2 `project-paused`, step 6; LV `usage --by thread` |
| C12 | Notifications | E10 | webhook **LIVE** (run_update, action_needed, failure classes observed); Telegram/Slack TESTED | ACC 7b; ACC2 step 6 + `agent-crash` failure delivery |
| C13 | Run a thread on the user's own machine | E0-SP/S5 (design only) | **NOT SHIPPED** | `docs/spikes/S5.md` §13 "DEFER"; no remote-worker code in `lib/` (grep) |
| R | (not in C1-C13) Archive every finished run and auto-review it (verdict, comment on the bead, gap beads) | review plan | **LIVE** (pi reviewer; Claude reviewer run recorded in `docs/acceptance/review-claude-reviewer-live-run.md`) | `docs/acceptance/review-*.md`; ACC2 step 7: all seven archive files, verdict `met` with four scores, comment posted on the source bead |

## Per capability

### C1 Project record, goal, instructions, model/effort
- **Behaviour**: a project carries `goal` (max 2000 chars), `instructions` (max 16 000), thread model/effort, coordinator provider/model/effort, `max_concurrent_runs`, `daily_thread_cap`, `pr_auto_fix`, `coordinator_*`, `repo_allowlist`, `max_repos_per_run`, `library_collect_produced`, `notification_preference` (key whitelist `packages/foreman_server/lib/foreman_server/project_settings.ex`; limits `aggregates/project/settings.ex:26-27`). Instructions flow through `ProjectContext` into the workflow-door and jobsite-door prompts.
- **Entry points** (all grepped): HTTP `GET /api/projects[/:id]` `router.ex:58-59`, `.../settings` `:61`, `.../context` `:63`; MCP `foreman_project_get/list` (`mcp/tools.ex:343/351`), `foreman_project_settings_get` `:378`, `foreman_project_settings_update` (write set, `mcp/policy.ex:17`); CLI `foreman project settings|context|update|create` (`foreman_cli/cmd/foreman/project.go:38-40`); LiveView `/dashboard/projects/:id/settings` `router.ex:146`.
- **Limits**: too-long inputs return 422 `instructions_too_long` / `goal_too_long`, and `max_concurrent_runs_invalid` (ACC, live).
- **Model/effort on Claude**: LV ran a Claude thread and coordinator with `haiku` (session files and `provider_sessions[].model=haiku`); a `provider: claude` phase cannot pin a model (`foreman-ezj0m`). Other Claude models and effort levels are unverified.

### C2 Project memory
- **Behaviour**: topic files under `.foreman/memory/` with an index; event log keeps audit only; injected into every thread; `remember` is a coordinator action (`coordinator/executor.ex:229`, machine turns allowed, `coordinator/policy.ex:20`).
- **Entry points**: HTTP `GET/PUT/DELETE /api/projects/:id/memory[/:name]`, `POST .../memory/sync` (`router.ex:68-72`); MCP `foreman_project_memory_list|read|write|forget` (`tools.ex:1035`, write set `policy.ex:20-21`); CLI `foreman project memory` (`project.go:66`).
- **Agent-written memory**: LIVE in LV (pi called `foreman_project_memory_write`, `project memory list` shows `agent-learned`, author `agent`); in ACC/ACC2 the memory was operator-written. Open CodeRabbit follow-ups on E2: `foreman-3xrtg` (e.g. doc lines, duplicated invalid-input code lists, `ProjectMemory.Store` guard applies below 200 bytes).

### C3 Repositories and Library
- **Library (LIVE)**: read-only mount, `FOREMAN_LIBRARY_PATH`; HTTP `router.ex:73-77`; MCP `foreman_project_library_list|read` (`mcp/library_tools.ex:66-67`); CLI `project library` (`project.go:64`); LiveView Library tab (broken "Not available yet." in the live run, F10, fixed in #604). Thread-produced files (`library_collect_produced`): LIVE in LV (`produced-<run>-<hash>` entries with `archive/analysis.md`, `archive/diff.patch`, phase output; side effect: every later thread prompt lists all earlier produced entries).
- **Multi-repo (E12, #603, LIVE with fake gh)**: one worktree per repo, one branch/PR per repo, per-PR merge gate, partial completion + `run retry-pr`, archive `diffs/<repo>.patch`; `runs: true` default (`config.exs:65`, kill switch). HTTP `GET /api/projects/:id/repositories` (`router.ex:62`); CLI `foreman project repo` (`project.go:72`); MCP `foreman_project_repo_list` (`tools.ex:364`), writes `foreman_run_request_repo` (`policy.ex:29`), `foreman_task_fanout` (`mcp/repo_tools.ex:24`).
- **Live in LV (fake gh)**: the `$FOREMAN_REPOS` env contract, thread self-add via `foreman_run_request_repo`, fanout (`repo_ids:"all"`, idempotent per `fanout_id`; called over MCP directly, not by an agent). **Not live**: per-phase repo selection, real GitHub, any provider but pi for multi-repo; jobsite multi-repo is refused by design (`403 spec_forbidden_key`). Rolling back to a pre-E12 binary is unsafe after the first multi-repo run (user guide).
- **Difference**: not a "Project knowledge" file picker UI; adding/removing library entries is CLI/HTTP only (LiveView has no upload handler: `project_workspace_live.ex` events are tab/stop/thread_action/post_message/steer/schedule/start_proposed/restart/load_earlier).

### C4 Environment
- **Behaviour**: `config.env` delivered to workflow workers (fix E0-S3 #567), secret store (`SecretStore`, 0600 file backend outside repos; OS keychain rejected; names `^[A-Z][A-Z0-9_]{0,63}$`, 16 KiB cap; values never in events), setup script, docker-sandbox network policy (host sandbox network policy is not enforceable; documented).
- **Entry points**: HTTP `GET/PUT /api/projects/:id/environment`, `PUT/DELETE .../secrets/:name` (`router.ex:82-85`); MCP `foreman_project_environment_get` (`tools.ex:433`; values redacted, read-only; no MCP secret write); CLI `project env|secret|setup-script|network` (`project.go:42-48`).
- **Status**: **LIVE** in LV: env vars reached a real pi agent on both doors, secrets did not appear in events, server log or `transcript.jsonl` (but appear in `diff.patch` if an agent commits them, `foreman-gkrfw`), a failing setup script failed the run `{:setup_script_failed, 7, ...}`, network `none`/`allowlist` produced the expected docker invocations. In-container blocking itself is UNVERIFIED and a host sandbox with a non-default policy produces a ghost jobsite (`foreman-bg2kq`).

### C5 Coordinator
- **Behaviour**: per-project conversation, JSON actions validated by `Coordinator.Policy` (machine turns may only answer/ask/propose/route_followup/remember; start/approve/tuning/add-repo/schedule need operator authority and quote verification). Propose-before-start, max active threads, reuse threads, restart on unhealthy.
- **Entry points**: HTTP `GET|POST /api/projects/:id/coordinator/messages`, `GET .../coordinator`, `POST .../coordinator/restart` (`router.ex:64-67`); MCP `foreman_project_conversation` (`tools.ex:1113`), `foreman_project_message` (write, `policy.ex:26`); CLI `foreman project chat [--restart]` (`project.go:70`); LiveView conversation pane.
- **Live (pi)**: started 3 threads in parallel from one message, propose then "go ahead", provider-down (3 failures then `unhealthy`, restart ok), restart mid-turn re-ran the turn without duplicate actions (ACC). ACC2 re-ran provider-down on a genuinely unavailable provider (`claude` with no credentials: exit 3, unhealthy notice, no thread; after `--restart` the coordinator answers and the queued request is served once) and a coordinator-worker kill (6 valid runs: 1 with duplicate threads, `foreman-42t7a`). **Live (Claude, LV)**: `--coordinator-provider=claude --coordinator-model=haiku` replied and started a thread in 23 s; coordinator -> claude thread -> claude reviewer -> report back into the chat in one message.
- **Known weaknesses**: status quality was poor (F7, fixed #606, not live-verified); quality measured with MiniMax and one short Claude haiku session (LV); the bundled workflows' litellm model pin was removed in #622 (`foreman-pv11k`, bead still open until closed by its owner, not re-run live).

### C6 Overview
- **Behaviour**: groups Ready for review / Waiting on you / Working / Landing / Idle / Resolved, Library / PRs / Scheduled tabs, attention flag.
- **Entry points**: HTTP `GET /api/projects/:project_id/overview` (`router.ex:60`); MCP `foreman_overview` (`tools.ex:229`); LiveView `/dashboard/projects/:id` (`router.ex:145`).
- **Live**: counts, failed threads in Waiting on you, Ready for review, Resolved after merge, PR tab (ACC 2, 5, 7f).
- **Gaps**: a PR with failing CI stayed in Ready for review because the Overview grouped by PR gate (ACC 4c); fixed by foreman-c1i34 (`ci_failing` now places it in Waiting on you); Scheduled tab not observed live.

### C7 Thread control
- **Behaviour**: transcript, stop, resolve/reopen, steering, approvals.
- **Entry points**: HTTP `GET /api/projects/:project_id/threads[/find]`, `GET /api/threads/:id[/transcript|/stream]`, `POST /api/threads/:id/stop|steer` (`router.ex:92-98`); MCP `foreman_thread_list|find|get|transcript` (`tools.ex:212-280`), `foreman_thread_stop|steer` (`tools.ex:296/311`); CLI `foreman thread stop|resolve|reopen|steer` (`thread.go:32-38`); LiveView stop/pause/resume/resolve/reopen/steer (`project_workspace_live.ex:91-123`).
- **Steering is pause-then-resume**: `Threads.Steerer.capability/1` returns `"pause_resume"` for every provider (`threads/steerer.ex:25`; S2 NO-GO for live mid-turn). Live: `RunPaused`/`RunSteerQueued`/`RunResumed`/`RunSteerConsumed`, agent obeyed (ACC 3). The message lands at a phase boundary, not in a running turn.
- **Approvals (in flight, Claude)**: a phase with `approval_mode: prompt` routes permission prompts to Foreman's per-run endpoint (`claude --permission-prompt-tool`); the call blocks, the operator approves/denies with CLI `foreman approvals`, `tool.approve|deny` or the workspace thread card buttons, timeout denies; live-proven in `docs/acceptance/inflight-approvals-live-run.md` (UI Approve click and restart/stop while blocked not exercised). **Approvals (post-hoc, pi and everything else)**: A phase whose agent had tools denied pauses the run (`awaiting_approval`); approving resumes with an `approval_mode_override` that applies to the next phase (user guide ~2293-2297; only producer is `approvals/phase_pause.ex:80`). Entry: `foreman approvals list|approve|deny` and `foreman questions answer` (`cmd/foreman/needs_you.go:18-31`), HTTP `GET /api/projects/:id/approvals|questions` (`router.ex:79-80`), read-only MCP `foreman_approvals_list` / `foreman_questions_list` (`tools.ex:1080/1097`). **No LiveView approve/deny/answer control** (grep of workspace events). **pi has no tool permission mechanism, so ACC/ACC2 never exercised this path**; LV ran it live with Claude `approval_mode: prompt`: tools denied in-session, run paused with `perm-1-Write-1`/`perm-1-Bash-1`, `foreman approvals approve` resumed it with `permissionMode acceptEdits` and it completed. That run found and fixed a real bug (#621: the denial arrives as a `%FailureCause{}`, so no approval request was ever created before). ACC2 only checks that the approval and question list surfaces answer.

### C8 PR lifecycle
- **Behaviour**: PrWatcher (enabled by default, `config.exs:289`) observes checks/reviews/conflicts; PrMonitor polling is opt-in (`FOREMAN_PR_MONITOR_ENABLED=true`, `runtime.exs:63`); GitHub webhook `POST /webhooks/github` (`router.ex:110`); auto-fix is opt-in per project via `pr_auto_fix` (default off; example `max_attempts: 2`; `pr_watcher/auto_fix.ex:4-6`); merge is operator-only (`merge_approve` then `run.pr.merge` pinned to the head SHA).
- **Entry points**: HTTP `GET /api/runs/:id/prs` (`router.ex:90`); MCP `foreman_pr_status` (`tools.ex:1151`), `foreman_pr_fix`, `foreman_pr_watch_stop` (`policy.ex:27-28`; no merge tool by design); CLI `foreman run prs|fix-ci|address-comments|resolve-conflicts|create-pr|retry-pr|watch-start|watch-stop|approve-merge|merge` (`run.go:47-65`).
- **Live (FAKED gh)**: PR created per thread, injected CI failure detected, fix thread pushed a fix, checks passing; operator merge to Resolved (ACC 4a-4b, 5). Before #604 (F9) no `stack_pr` run ever reached the merge gate.
- **Unverified**: real GitHub, webhooks, review comments, conflicts, force-push, re-run. The workspace UI now has Fix CI / Address comments / Resolve conflicts / Create PR buttons (foreman-i6kws); there is intentionally no Merge button.

### C9 Scheduled tasks
- **Entry points**: HTTP `GET /api/projects/:id/schedules` (`router.ex:78`); MCP `foreman_schedule_list` (`tools.ex:550`), `foreman_schedule_create` (`tools.ex:562`), pause/resume/delete (write set `policy.ex:22-25`); CLI `foreman project schedule` (`project.go:68`, subverbs `project_schedule.go`); LiveView pause/resume/delete (`project_workspace_live.ex:154`).
- **Settings**: ticker on by default (`config.exs`, `FOREMAN_SCHEDULE_TICKER_ENABLED`), minimum `every` interval, per-project cap, misfire grace.
- **Status**: **LIVE** in LV (cron `* * * * *` fired runs, `pause` stopped firing, resume/delete worked); the Scheduled dashboard tab was not looked at.

### C10 Adopt / setup recommendations
- **Entry points**: `POST /api/project-adoptions` (`router.ex:55`), `GET /api/projects/:id/recommendations` (`router.ex:57`); MCP `foreman_project_recommendations` (`tools.ex:392`); CLI `foreman project recommend|adopt` (`project.go:60-62`), `foreman doctor --project`.
- **Behaviour**: pure detector set (`projects/recommendations.ex` ids such as `task_provider.wire_beads`, `repo.agents_md_missing`, `gh.unauthenticated`, `settings.instructions_empty`, `memory.empty`). No move/continue of a live Claude Code session; adoption re-homes a Foreman task/jobsite/run archive.
- **Status**: **LIVE** in LV (move a run into another project, mint with the `path_in_use` refusal, continue a new task from an archive that needed a manual `task.approve` (`foreman-7nvf8`); recommend with `--fail-on` exit codes). Continuing a live Claude Code session is not a feature.

### C11 Lifecycle, usage, caps
- **Entry points**: CLI `project pause|resume|reactivate|delete` (`project.go:50-56`); MCP `foreman_project_pause|resume` (`tools.ex:521`); HTTP `GET /api/projects/:id/usage` (`router.ex:81`); MCP `foreman_usage_get` (`tools.ex:406`); CLI `foreman usage [thread]` (`usage_cmd.go`).
- **Semantics**: `delete` is archive-only, rejected while runs are active, reversible with `reactivate`, never removes event data or on-disk archives (`docs/decisions/project-delete.md`). Pause refuses new admissions, in-flight runs continue.
- **Live**: pause rejection `{:project_paused,...}` and resume (ACC 7a; ACC2 `project-paused`: a bead held while paused starts after resume), cap deferrals, usage by model 9.19M tokens / $0.9546 (ACC 7e), per-thread usage rows (`foreman usage --by thread`, LV). **Not observed**: archive/delete live; coordinator turns have no usage row (LV).
- **Defaults**: `max_concurrent_runs`, `daily_thread_cap` are unset unless the operator sets them (settings keys above); global caps remain. F2 (run-limit deferrals never re-admitted) closed #606, not reproduced live.

### C12 Notifications
- **Behaviour**: `Notifier` maps projected events to classes `failure`, `stall`, `run_update`, `action_needed` (`notifier/mapping.ex`); per-project `notification_preference`; Messaging providers Telegram/Slack/webhook; no desktop notifications.
- **Entry points**: no HTTP/MCP surface; configuration via `FOREMAN_NOTIFY_WEBHOOK_URL` (`runtime.exs`, ACC), `foreman project update --notification-preference`.
- **Live**: 27 webhook deliveries (9 failure, 15 run_update, 3 action_needed) in ACC; ACC2 saw `run_update` deliveries in the flow and a `failure` delivery after an agent kill. Telegram/Slack not exercised.

### C13 Remote worker
- **NOT SHIPPED.** `docs/spikes/S5.md` §13: "DEFER (leaning GO as a later epic)"; design recommends a reverse-WebSocket worker agent. No remote-worker code exists in `packages/foreman_server/lib` (grep for `remote.worker|worker_agent` returned nothing). All execution is on the server host.

## Bugs and open items (from `br`)

Filed by the first live run (ACC): F1 `foreman-qxmye` CLOSED (#607; live-verified by ACC2 `server-crash` for the exec-port+server kill case); F2 `foreman-s19h6` CLOSED (#606, not reproduced live); F3 `foreman-qp5d3` CLOSED (#605, live pi verified git log unchanged); F4 `foreman-3r79u` CLOSED (#605; ACC2 `agent-crash` shows `{:other, :execution}: execution: pi: exit_status 137` - the class is still `:other` but the exit status is now in the reason); F5 `foreman-z4czv` CLOSED (#607, test-verified); F6 `foreman-pv11k` fixed on main (#622 removed the litellm pin from the bundled workflows; bead still open until closed by its owner; not re-run live); F7 `foreman-rkfxs` CLOSED (#606, keyword-triggered, live UNVERIFIED).

Other open: `foreman-3xrtg` P2 CodeRabbit findings on admin-merged #573/#577/#579 (E2/E7/E11: minor doc/duplication/`rescue` coverage in `Overview.Tabs`, validation fallbacks, test weakness); `foreman-i97tz` P3 spike review items; `foreman-8ta8x` P2 test-hygiene audit; `foreman-b1ypr` (E13 epic) still open although shipped (#578); the E16 stories S6/S7 task beads are still open.

Found by the scripted acceptance (ACC2, 2026-10-22; all OPEN, none carry `foreman-exec`): `foreman-42t7a` P2 (a killed coordinator `ProjectWorker` leaves its turn task running and a second turn can duplicate actions; seen live once in 6 valid runs of the scenario), `foreman-zmhzw` P3 (an agent orphaned by a dying exec-port under a live server is never reaped; agent tool children also survive `run cancel`, `thread stop` and graceful shutdown), `foreman-uxfwb` P3 (one `undetermined` review verdict, cause not captured). F1 is now live-verified (see C5 and item 11). Found by LV (`docs/acceptance/parity-gaps-live-run.md`): `foreman-ezj0m`, `foreman-gl3nu`, `foreman-bg2kq`, `foreman-b3jtt`, `foreman-gkrfw`, `foreman-7nvf8`.

## Gap beads filed by this audit (label `parity-gap`)

| Bead | Pri | Gap |
|---|---|---|
| foreman-exofh | P2 | approvals post-hoc, no UI approve/deny; pause-for-approval exercised live with Claude prompt mode in LV (#621), never with pi |
| foreman-ksy0q | P2 | real GitHub paths (PR/CI/webhook/merge) unverified |
| foreman-nufr9 | P2 | Claude provider paths: PARTIAL in LV (coordinator, thread, reviewer, prompt-mode approvals, steer resume PASS; fix-thread resume UNVERIFIED; background-task steer FAIL `foreman-b3jtt`) |
| foreman-s48kc | P3 | steering is pause/resume only |
| foreman-c1i34 | P3 | failing CI -> Waiting on you: shipped on main (#619), not re-observed live; bead still open until closed by its owner |
| foreman-i6kws | P3 | PR action buttons in the workspace UI: shipped on main (#627); bead still open until closed by its owner |
| foreman-8vf0s | P3 | env/secrets/setup script/network/schedules/adopt/recommend LIVE in LV; open: in-container network blocking, Scheduled tab, secrets in `diff.patch` (`foreman-gkrfw`), host-sandbox ghost jobsite (`foreman-bg2kq`) |
| foreman-mivo7 | P3 | Telegram/Slack unexercised |
| foreman-zn7de | P3 | C13 remote worker not built |
| foreman-he4yf | P3 | multi-repo env contract, thread self-add, fanout LIVE in LV (fake gh); jobsite multi-repo is refused by design; real GitHub not run |
| foreman-pz1ie | P3 | produced files, agent-written memory, per-thread usage, BeadSink-br-down: LIVE in LV (br-down also in ACC2); remaining: coordinator turns have no usage row, br outage misreported as `BR_PARSE_ERROR` on finalize |
| foreman-4qtk4 | P3 | stale architecture doc line: fixed on main (#624); the E13 epic bead remains open |
| foreman-42t7a | P2 | coordinator worker crash leaves its turn task running; a second turn can duplicate actions (found by ACC2) |
| foreman-zmhzw | P3 | agent orphaned when its exec-port dies while the server lives is never reaped (found by ACC2) |
| foreman-uxfwb | P3 | review verdict `undetermined`/`evaluator_failed` seen once for a healthy pi run, cause not captured (found by ACC2) |

## What a Claude Projects user would notice is different or missing

1. **Provider coverage is thin.** pi + MiniMax carries almost everything. LV ran the Claude coordinator, workflow-door thread, reviewer, approval prompt mode and thread-steer session resume live with `haiku` (one short session each); Claude as a PR fix-thread resume, steer while Claude waits on a background task (`foreman-b3jtt`, FAIL), pinning a model in a `provider: claude` phase (`foreman-ezj0m`) and any Claude model other than haiku are not. Do not assume the full Claude experience.
2. **GitHub is unproven.** Every PR, CI check, merge and "fix CI" observation came from a scripted fake `gh` and local bare repos. Webhooks (E9), review comments, merge conflicts and branch protection are unverified live.
3. **Steering is not live.** Your message is applied by pausing and resuming at the next prompt boundary, not injected into the running turn.
4. **No in-flight tool approval.** There is no per-call "Allow this?" prompt. The mechanism is: tools denied, phase pauses, you approve, the next phase runs with elevated mode (broader than the one tool). With Claude `approval_mode: prompt` the pause/approve path was run live in LV (after the #621 fix); pi has no permission system at all, so ACC/ACC2 never exercise it. The LiveView page cannot approve, deny or answer; you must use the CLI or HTTP.
5. **PR buttons live in the CLI.** Fix CI, Address comments, Resolve conflicts, Create PR and Merge are CLI/HTTP/MCP verbs, not buttons in the workspace. Merge is deliberately operator-only (no MCP merge tool).
6. **Failing CI now raises attention in the code** (`foreman-c1i34`, #619: `ci_failing` places the thread in Waiting on you); it was observed in the Ready-for-review group in the first live run (ACC 4c) and has not been re-observed live.
7. **No remote execution (C13).** Nothing runs on your own machine; design only, DEFER.
8. **Uploading and managing files is CLI/API only**, no drag-and-drop library UI; memory is edited via CLI/HTTP/MCP.
9. **Some features have still never been seen running:** Telegram/Slack, the Scheduled dashboard tab, in-container network blocking, the review of coordinator-only work. LV has since run environment/secrets/setup script, schedules (cron fired, pause stopped it), adopt/recommend, thread-produced library files, agent-written memory and per-thread usage rows.
10. **Coordinator quality is proven for MiniMax and for one short Claude haiku session (LV), not beyond**, and status accuracy was weak in the first live run (fix is keyword-triggered and not live-verified). The bundled workflows no longer pin the unreachable litellm model (#622, `foreman-pv11k`), but that was not re-run live here (ACC2 uses its own pi workflows).
11. **Recovery** after `kill -9` of the server is now live-verified for the #607 case (ACC2 `server-crash`: exec-port and server killed together, the orphaned `pi` was reparented to pid 1, the restarted server's `OrphanReaper` killed it and the run resumed in a fresh agent). Two caveats are open: an agent orphaned while the server stays alive is never reaped (`foreman-zmhzw`), and a coordinator worker crash can leave its turn task running (`foreman-42t7a`).
12. **Delete is archive.** There is no hard delete; this is a deliberate decision.
13. **Multi-repo is real but narrow in evidence**: two scratch repos, pi, fake gh; rolling back to an older binary after the first multi-repo run is not safe.
14. **Acceptance is now scripted and green for pi, but still narrow**: `scripts/e2e/claude_projects_flow.sh` (48 PASS, 0 FAIL, 1 UNVERIFIED) and `scripts/e2e/failure_injection.sh` (six scenarios, 32 PASS, 0 FAIL) ran against a real throwaway server on 2026-10-22 (`docs/acceptance/claude-projects-acceptance-2026-10-22.md`). They cover the pi path only: no GitHub, no Claude provider, no tool approvals (the Claude provider was exercised by hand in LV). Three new defect beads came out of them (`foreman-42t7a`, `foreman-zmhzw`, `foreman-uxfwb`, all open, none P0/P1). The full unit suite is not part of those scripts.
