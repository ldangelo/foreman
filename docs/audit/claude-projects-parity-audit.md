# Claude Projects parity audit (C1-C13)

Audit of `main` @ `33d7cb24` (after #607) against the capability list in the parity plan (`docs/plans/claude-projects-parity-plan.md`, untracked) for bead E16-S9. Method: entry points were checked by grep at the cited file:line; behaviour claims come from code reading, the committed tests' existence, `docs/acceptance/claude-projects-live-run.md` (the live run, "ACC") and `docs/lessons/multi-repo-e2e-2026-10-21.md` ("MR"). **No new live probes were run for this audit** (no server was started); "LIVE" below always means "observed in ACC or MR", nothing else. Test suites were not re-run here.

Status vocabulary: **LIVE** = shipped and observed in a live run; **TESTED** = shipped, covered by tests only; **PARTIAL** = something named is missing; **NOT SHIPPED**.

## Live-evidence caveats that apply to everything

- The only provider exercised live is `pi` with `minimax/MiniMax-M2.7-highspeed` (ACC Environment; MR "Only `pi` + MiniMax was run"). Claude OAuth was expired. Every Claude-specific path is unverified.
- `gh` was **faked** (ACC, MR). Every PR / CI / merge observation is against a local bare repo and a scripted fake; real GitHub behaviour is unverified.
- ACC states: "Open P1 defects after this run: F1, F3. Acceptance is therefore **not declared fully passed**." Both have since been closed (see Bugs), the fixes are test-verified; F1 (crash recovery) and F2/F4/F5/F7 are explicitly "not live" per their close comments; F3 was live-verified.
- Only targeted tests were run in ACC, not the full suite.

## Whole-plan table

| Cap | Claude Projects behaviour | Epics | Status | Evidence |
|---|---|---|---|---|
| C1 | Project goal, instructions, model/effort | E1, E3 | **LIVE** (settings, injection); model/effort setting TESTED | ACC step 1 (settings via CLI), 7d (instruction/memory text reached agent output); limits 422 (ACC "Exceed limits") |
| C2 | Project memory | E2 | **LIVE** for operator-written memory reaching agents; agent-written TESTED | ACC 7d (`PINEAPPLE-42`) |
| C3 | Repos, Library, thread-produced files | E5, E12 | Library **LIVE**; multi-repo **LIVE** (fake gh, pi only); thread-produced files and thread self-add repo TESTED | ACC 7c (`7319-ZEBRA`); MR 110 assertions |
| C4 | Environment: env vars, secrets, setup script, network | E0-S3, E4 | **TESTED** | not in ACC or MR |
| C5 | Coordinator routing and tuning | E15 | **LIVE** (pi); tuning/"remember" PARTIAL-evidence | ACC steps 2, 6, failure injection |
| C6 | Overview groups, tabs, attention | E7, E16 | **LIVE** (groups, PR, Library tabs); Scheduled tab TESTED; CI-failing-in-Waiting fixed (foreman-c1i34) | ACC 2, 4c, 7f |
| C7 | Thread control: transcript, steer, approvals, stop, resolve | E6, E8 | steer/stop/resolve **LIVE**; approvals **TESTED** and PARTIAL by design | ACC 3, 5; approvals not run (pi has none) |
| C8 | PR lifecycle: watch, fix CI, comments, conflicts, merge | E9 | **LIVE with FAKED gh**; PARTIAL (no UI buttons; real GitHub unverified) | ACC 4a-4c, 5 |
| C9 | Scheduled tasks | E11 | **TESTED** | not in ACC |
| C10 | Adopt existing session; setup recommendations | E13 | **TESTED** | not in ACC |
| C11 | Pause/archive/delete; usage; thread cap | E1, E14 | pause, caps, rollup **LIVE**; archive/delete TESTED; per-thread usage PARTIAL | ACC 7a, 7e, "Exceed limits" |
| C12 | Notifications | E10 | webhook **LIVE**; Telegram/Slack TESTED | ACC 7b |
| C13 | Run a thread on the user's own machine | E0-SP/S5 (design only) | **NOT SHIPPED** | `docs/spikes/S5.md` §13 "DEFER"; no remote-worker code in `lib/` (grep) |

## Per capability

### C1 Project record, goal, instructions, model/effort
- **Behaviour**: a project carries `goal` (max 2000 chars), `instructions` (max 16 000), thread model/effort, coordinator provider/model/effort, `max_concurrent_runs`, `daily_thread_cap`, `pr_auto_fix`, `coordinator_*`, `repo_allowlist`, `max_repos_per_run`, `library_collect_produced`, `notification_preference` (key whitelist `packages/foreman_server/lib/foreman_server/project_settings.ex`; limits `aggregates/project/settings.ex:26-27`). Instructions flow through `ProjectContext` into the workflow-door and jobsite-door prompts.
- **Entry points** (all grepped): HTTP `GET /api/projects[/:id]` `router.ex:58-59`, `.../settings` `:61`, `.../context` `:63`; MCP `foreman_project_get/list` (`mcp/tools.ex:343/351`), `foreman_project_settings_get` `:378`, `foreman_project_settings_update` (write set, `mcp/policy.ex:17`); CLI `foreman project settings|context|update|create` (`foreman_cli/cmd/foreman/project.go:38-40`); LiveView `/dashboard/projects/:id/settings` `router.ex:146`.
- **Limits**: too-long inputs return 422 `instructions_too_long` / `goal_too_long`, and `max_concurrent_runs_invalid` (ACC, live).
- **Not verified**: model/effort actually reaching a *Claude* RunRequest (only pi live).

### C2 Project memory
- **Behaviour**: topic files under `.foreman/memory/` with an index; event log keeps audit only; injected into every thread; `remember` is a coordinator action (`coordinator/executor.ex:229`, machine turns allowed, `coordinator/policy.ex:20`).
- **Entry points**: HTTP `GET/PUT/DELETE /api/projects/:id/memory[/:name]`, `POST .../memory/sync` (`router.ex:68-72`); MCP `foreman_project_memory_list|read|write|forget` (`tools.ex:1035`, write set `policy.ex:20-21`); CLI `foreman project memory` (`project.go:66`).
- **Limitation**: in ACC the memory was operator-written; an agent writing memory through MCP was not observed (bead foreman-pz1ie). Open CodeRabbit follow-ups on E2: `foreman-3xrtg` (e.g. doc lines, duplicated invalid-input code lists, `ProjectMemory.Store` guard applies below 200 bytes).

### C3 Repositories and Library
- **Library (LIVE)**: read-only mount, `FOREMAN_LIBRARY_PATH`; HTTP `router.ex:73-77`; MCP `foreman_project_library_list|read` (`mcp/library_tools.ex:66-67`); CLI `project library` (`project.go:64`); LiveView Library tab (broken "Not available yet." in the live run, F10, fixed in #604). Thread-produced files: setting `library_collect_produced`; not observed live.
- **Multi-repo (E12, #603, LIVE with fake gh)**: one worktree per repo, one branch/PR per repo, per-PR merge gate, partial completion + `run retry-pr`, archive `diffs/<repo>.patch`; `runs: true` default (`config.exs:65`, kill switch). HTTP `GET /api/projects/:id/repositories` (`router.ex:62`); CLI `foreman project repo` (`project.go:72`); MCP `foreman_project_repo_list` (`tools.ex:364`), writes `foreman_run_request_repo` (`policy.ex:29`), `foreman_task_fanout` (`mcp/repo_tools.ex:24`).
- **Not live** (MR "Not covered"): jobsite multi-repo, per-phase repo selection, thread self-add (`run.repo.request`), env contract (`FOREMAN_REPOS`), real GitHub, any provider but pi. Rolling back to a pre-E12 binary is unsafe after the first multi-repo run (user guide).
- **Difference**: not a "Project knowledge" file picker UI; adding/removing library entries is CLI/HTTP only (LiveView has no upload handler: `project_workspace_live.ex` events are tab/stop/thread_action/post_message/steer/schedule/start_proposed/restart/load_earlier).

### C4 Environment
- **Behaviour**: `config.env` delivered to workflow workers (fix E0-S3 #567), secret store (`SecretStore`, 0600 file backend outside repos; OS keychain rejected; names `^[A-Z][A-Z0-9_]{0,63}$`, 16 KiB cap; values never in events), setup script, docker-sandbox network policy (host sandbox network policy is not enforceable; documented).
- **Entry points**: HTTP `GET/PUT /api/projects/:id/environment`, `PUT/DELETE .../secrets/:name` (`router.ex:82-85`); MCP `foreman_project_environment_get` (`tools.ex:433`; values redacted, read-only; no MCP secret write); CLI `project env|secret|setup-script|network` (`project.go:42-48`).
- **Status**: TESTED only. Not exercised in ACC or MR.

### C5 Coordinator
- **Behaviour**: per-project conversation, JSON actions validated by `Coordinator.Policy` (machine turns may only answer/ask/propose/route_followup/remember; start/approve/tuning/add-repo/schedule need operator authority and quote verification). Propose-before-start, max active threads, reuse threads, restart on unhealthy.
- **Entry points**: HTTP `GET|POST /api/projects/:id/coordinator/messages`, `GET .../coordinator`, `POST .../coordinator/restart` (`router.ex:64-67`); MCP `foreman_project_conversation` (`tools.ex:1113`), `foreman_project_message` (write, `policy.ex:26`); CLI `foreman project chat [--restart]` (`project.go:70`); LiveView conversation pane.
- **Live (pi)**: started 3 threads in parallel from one message, propose then "go ahead", provider-down (3 failures then `unhealthy`, restart ok), restart mid-turn re-ran the turn without duplicate actions.
- **Known weaknesses**: status quality was poor (F7, fixed #606, not live-verified); quality measured only with MiniMax; bundled workflows need a litellm model that was unreachable, `foreman-pv11k` OPEN (P2).

### C6 Overview
- **Behaviour**: groups Ready for review / Waiting on you / Working / Landing / Idle / Resolved, Library / PRs / Scheduled tabs, attention flag.
- **Entry points**: HTTP `GET /api/projects/:project_id/overview` (`router.ex:60`); MCP `foreman_overview` (`tools.ex:229`); LiveView `/dashboard/projects/:id` (`router.ex:145`).
- **Live**: counts, failed threads in Waiting on you, Ready for review, Resolved after merge, PR tab (ACC 2, 5, 7f).
- **Gaps**: a PR with failing CI stayed in Ready for review because the Overview grouped by PR gate (ACC 4c); fixed by foreman-c1i34 (`ci_failing` now places it in Waiting on you); Scheduled tab not observed live.

### C7 Thread control
- **Behaviour**: transcript, stop, resolve/reopen, steering, approvals.
- **Entry points**: HTTP `GET /api/projects/:project_id/threads[/find]`, `GET /api/threads/:id[/transcript|/stream]`, `POST /api/threads/:id/stop|steer` (`router.ex:92-98`); MCP `foreman_thread_list|find|get|transcript` (`tools.ex:212-280`), `foreman_thread_stop|steer` (`tools.ex:296/311`); CLI `foreman thread stop|resolve|reopen|steer` (`thread.go:32-38`); LiveView stop/pause/resume/resolve/reopen/steer (`project_workspace_live.ex:91-123`).
- **Steering is pause-then-resume**: `Threads.Steerer.capability/1` returns `"pause_resume"` for every provider (`threads/steerer.ex:25`; S2 NO-GO for live mid-turn). Live: `RunPaused`/`RunSteerQueued`/`RunResumed`/`RunSteerConsumed`, agent obeyed (ACC 3). The message lands at a phase boundary, not in a running turn.
- **Approvals**: post-hoc. A phase whose agent had tools denied pauses the run (`awaiting_approval`); approving resumes with an `approval_mode_override` that applies to the next phase (user guide ~2293-2297; only producer is `approvals/phase_pause.ex:80`). Entry: `foreman approvals list|approve|deny` and `foreman questions answer` (`cmd/foreman/needs_you.go:18-31`), HTTP `GET /api/projects/:id/approvals|questions` (`router.ex:79-80`), read-only MCP `foreman_approvals_list` / `foreman_questions_list` (`tools.ex:1080/1097`). **No LiveView approve/deny/answer control** (grep of workspace events). **pi has no tool permission mechanism, so this path was never exercised live** (ACC "Denied tool").

### C8 PR lifecycle
- **Behaviour**: PrWatcher (enabled by default, `config.exs:289`) observes checks/reviews/conflicts; PrMonitor polling is opt-in (`FOREMAN_PR_MONITOR_ENABLED=true`, `runtime.exs:63`); GitHub webhook `POST /webhooks/github` (`router.ex:110`); auto-fix is opt-in per project via `pr_auto_fix` (default off; example `max_attempts: 2`; `pr_watcher/auto_fix.ex:4-6`); merge is operator-only (`merge_approve` then `run.pr.merge` pinned to the head SHA).
- **Entry points**: HTTP `GET /api/runs/:id/prs` (`router.ex:90`); MCP `foreman_pr_status` (`tools.ex:1151`), `foreman_pr_fix`, `foreman_pr_watch_stop` (`policy.ex:27-28`; no merge tool by design); CLI `foreman run prs|fix-ci|address-comments|resolve-conflicts|create-pr|retry-pr|watch-start|watch-stop|approve-merge|merge` (`run.go:47-65`).
- **Live (FAKED gh)**: PR created per thread, injected CI failure detected, fix thread pushed a fix, checks passing; operator merge to Resolved (ACC 4a-4b, 5). Before #604 (F9) no `stack_pr` run ever reached the merge gate.
- **Unverified**: real GitHub, webhooks, review comments, conflicts, force-push, re-run. The workspace UI has no Fix CI / Address comments / Resolve conflicts / Create PR / Merge buttons (bead foreman-i6kws).

### C9 Scheduled tasks
- **Entry points**: HTTP `GET /api/projects/:id/schedules` (`router.ex:78`); MCP `foreman_schedule_list` (`tools.ex:550`), `foreman_schedule_create` (`tools.ex:562`), pause/resume/delete (write set `policy.ex:22-25`); CLI `foreman project schedule` (`project.go:68`, subverbs `project_schedule.go`); LiveView pause/resume/delete (`project_workspace_live.ex:154`).
- **Settings**: ticker on by default (`config.exs`, `FOREMAN_SCHEDULE_TICKER_ENABLED`), minimum `every` interval, per-project cap, misfire grace.
- **Status**: TESTED only; no schedule was fired in ACC.

### C10 Adopt / setup recommendations
- **Entry points**: `POST /api/project-adoptions` (`router.ex:55`), `GET /api/projects/:id/recommendations` (`router.ex:57`); MCP `foreman_project_recommendations` (`tools.ex:392`); CLI `foreman project recommend|adopt` (`project.go:60-62`), `foreman doctor --project`.
- **Behaviour**: pure detector set (`projects/recommendations.ex` ids such as `task_provider.wire_beads`, `repo.agents_md_missing`, `gh.unauthenticated`, `settings.instructions_empty`, `memory.empty`). No move/continue of a live Claude Code session; adoption re-homes a Foreman task/jobsite/run archive.
- **Status**: TESTED only.

### C11 Lifecycle, usage, caps
- **Entry points**: CLI `project pause|resume|reactivate|delete` (`project.go:50-56`); MCP `foreman_project_pause|resume` (`tools.ex:521`); HTTP `GET /api/projects/:id/usage` (`router.ex:81`); MCP `foreman_usage_get` (`tools.ex:406`); CLI `foreman usage [thread]` (`usage_cmd.go`).
- **Semantics**: `delete` is archive-only, rejected while runs are active, reversible with `reactivate`, never removes event data or on-disk archives (`docs/decisions/project-delete.md`). Pause refuses new admissions, in-flight runs continue.
- **Live**: pause rejection `{:project_paused,...}` and resume (ACC 7a), cap deferrals, usage by model 9.19M tokens / $0.9546 (ACC 7e). **Not observed**: per-thread usage rows ("Not done"), archive/delete live.
- **Defaults**: `max_concurrent_runs`, `daily_thread_cap` are unset unless the operator sets them (settings keys above); global caps remain. F2 (run-limit deferrals never re-admitted) closed #606, not reproduced live.

### C12 Notifications
- **Behaviour**: `Notifier` maps projected events to classes `failure`, `stall`, `run_update`, `action_needed` (`notifier/mapping.ex`); per-project `notification_preference`; Messaging providers Telegram/Slack/webhook; no desktop notifications.
- **Entry points**: no HTTP/MCP surface; configuration via `FOREMAN_NOTIFY_WEBHOOK_URL` (`runtime.exs`, ACC), `foreman project update --notification-preference`.
- **Live**: 27 webhook deliveries (9 failure, 15 run_update, 3 action_needed). Telegram/Slack not exercised.

### C13 Remote worker
- **NOT SHIPPED.** `docs/spikes/S5.md` §13: "DEFER (leaning GO as a later epic)"; design recommends a reverse-WebSocket worker agent. No remote-worker code exists in `packages/foreman_server/lib` (grep for `remote.worker|worker_agent` returned nothing). All execution is on the server host.

## Bugs and open items (from `br`)

Filed by the live run (ACC): F1 `foreman-qxmye` CLOSED (#607, test-verified, "live-verified: resumed run completion unverified"); F2 `foreman-s19h6` CLOSED (#606, not reproduced live); F3 `foreman-qp5d3` CLOSED (#605, live pi verified git log unchanged); F4 `foreman-3r79u` CLOSED (#605, unit-tested); F5 `foreman-z4czv` CLOSED (#607, test-verified); F6 `foreman-pv11k` **OPEN P2** (bundled fix/prd/review workflows pin a litellm model); F7 `foreman-rkfxs` CLOSED (#606, keyword-triggered, live UNVERIFIED).

Other open: `foreman-3xrtg` P2 CodeRabbit findings on admin-merged #573/#577/#579 (E2/E7/E11: minor doc/duplication/`rescue` coverage in `Overview.Tabs`, validation fallbacks, test weakness); `foreman-i97tz` P3 spike review items; `foreman-8ta8x` P2 test-hygiene audit; `foreman-b1ypr` (E13 epic) still open although shipped (#578); the E16 stories S6/S7/S8/S9 task beads are still open.

## Gap beads filed by this audit (label `parity-gap`)

| Bead | Pri | Gap |
|---|---|---|
| foreman-exofh | P2 | approvals post-hoc, no UI approve/deny, never exercised live |
| foreman-ksy0q | P2 | real GitHub paths (PR/CI/webhook/merge) unverified |
| foreman-nufr9 | P2 | Claude provider paths unverified live |
| foreman-s48kc | P3 | steering is pause/resume only |
| foreman-c1i34 | P3 | failing CI does not move thread to Waiting on you |
| foreman-i6kws | P3 | no PR action buttons in the workspace UI |
| foreman-8vf0s | P3 | env/secrets/schedules/adopt/recommend not live-run |
| foreman-mivo7 | P3 | Telegram/Slack unexercised |
| foreman-zn7de | P3 | C13 remote worker not built |
| foreman-he4yf | P3 | multi-repo jobsite/self-add/fanout/env not live |
| foreman-pz1ie | P3 | produced files, agent-written memory, per-thread usage, BeadSink-br-down not live |
| foreman-4qtk4 | P3 | stale architecture doc line (fixed here), E13 epic bead open |

## What a Claude Projects user would notice is different or missing

1. **It only really works with one provider.** Everything live was `pi` + MiniMax. Claude paths (coordinator, threads, reviewer, session resume, approvals) have never run end to end in this programme. Do not assume the Claude experience.
2. **GitHub is unproven.** Every PR, CI check, merge and "fix CI" observation came from a scripted fake `gh` and local bare repos. Webhooks (E9), review comments, merge conflicts and branch protection are unverified live.
3. **Steering is not live.** Your message is applied by pausing and resuming at the next prompt boundary, not injected into the running turn.
4. **No in-flight tool approval.** There is no per-call "Allow this?" prompt. The mechanism is: tools denied, phase pauses, you approve, the next phase runs with elevated mode (broader than the one tool). pi has no permission system at all, so the whole path is unexercised live. The LiveView page cannot approve, deny or answer; you must use the CLI or HTTP.
5. **PR buttons live in the CLI.** Fix CI, Address comments, Resolve conflicts, Create PR and Merge are CLI/HTTP/MCP verbs, not buttons in the workspace. Merge is deliberately operator-only (no MCP merge tool).
6. **Failing CI does not raise attention.** A PR with failing checks sat in Ready for review in the live run.
7. **No remote execution (C13).** Nothing runs on your own machine; design only, DEFER.
8. **Uploading and managing files is CLI/API only**, no drag-and-drop library UI; memory is edited via CLI/HTTP/MCP.
9. **Several features have never been seen running:** environment/secrets/setup script/network policy, scheduled tasks, adopt/recommend, Telegram/Slack, thread-produced library files, per-thread usage, agent-written memory.
10. **Coordinator quality is unproven beyond MiniMax**, and status accuracy was weak in the live run (fix is keyword-triggered and not live-verified). Bundled workflows still pin a litellm model that fails without that host (`foreman-pv11k`).
11. **Recovery** after `kill -9` of the server was a failed acceptance scenario in the live run; the fix (#607) is test-verified only.
12. **Delete is archive.** There is no hard delete; this is a deliberate decision.
13. **Multi-repo is real but narrow in evidence**: two scratch repos, pi, fake gh; rolling back to an older binary after the first multi-repo run is not safe.
14. **Acceptance was never declared fully passed**, and the full test suite was not run as part of it.
