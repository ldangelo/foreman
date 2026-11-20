# Retire the jobsite dispatch path

Status: **Phase 1 approved 2026-11-19** (kata `5z8s`); Phase 2 in progress, one kata issue per PR.
Supersedes the 2026-10-23 owner decision to KEEP the remote API (kata `9mds`, closed);
that decision was about the remote HTTP door and recorded "2 audited POSTs, door off by default".

## 0. What "jobsite" is today: two different things

The word covers a *dispatch door* and an *execution substrate*. Only the door can be retired.

| Part | Modules (approx. lines) | Verdict |
|---|---|---|
| **Door** (own aggregate, own executor, own admission, own API) | `Jobsite` facade (480), `Jobsite.Executor` (1267) + `Executor.Observer` (218), `Supervisor`/`Registry`/`Control` (140), `BootRecovery` (285), `Spec` (762), `Template` + `Template.Script/Feature` (600), `Aggregates.Jobsite` (586), `Aggregates.JobsiteAudit` (126), `JobsiteController` (406) + 8 routes, CLI `jobsite.go` + 5 embedded templates + `init --template`, `foreman_client`, skill `foreman-jobsite-template`, `runtime.exs` `FOREMAN_JOBSITES_*` env | **Retire** (~4.9k lines + tests) |
| **Substrate** (what runs execute on) | `Engine` (807), `Program`, `Step`, `Runner`, `Runners.Overwatch` (633), `AgentRunner` (568), `Git` (671), `Worktree` (393), `Sandbox*`/`Sandboxes.{Docker,Host}` (~620), `NetworkPolicy` (362), `HostCommand`, `Hooks`, `Prompt`, `Agent`, `Options`, `Logging`, `Output`, `Result`, `Error` | **Keep, rename out of `Jobsite.*`** (last PR) |

**Do workflows depend on the jobsite Program/Engine? Yes, heavily.** `RunExecutor` aliases
`Jobsite.Engine`, `Jobsite.Git`, `Jobsite.Runners.Overwatch`; `Workflow.Lowering` compiles a manifest
into a `Jobsite.Program` (`Step`s) and `Engine.run_program/3` executes it; `Workflow.Worktree`,
`Workflow.JobsiteObserver`, `Projects.SourceBranch`, `Review.Capture`, `VcsAdapter.Default`, `ProjectSetup`,
`ProjectEnvironmentDTO`, `Approvals.Capability`, `Workflow.Interpreter` and `Aggregates.Run` call
`Jobsite.{Git,HostCommand,NetworkPolicy,Agent}`. So "remove jobsite" = delete the door, keep the engine.
Note `Lowering` emits **no** `:sandbox`/`:release` step (lowering.ex:45), so runs execute unsandboxed on the host.

## 1. Caller inventory (what must change)

| Caller | Dependency on the door | Plan |
|---|---|---|
| `pr_watcher.ex`, `pr_fix.ex`, `pr_fix/prompt.ex` | `Jobsite.run_async/1` starts the fix; waits on `JobsiteCompleted/Failed`; `PrFix.plan/4` builds `jobsite_opts` via `Jobsite.Spec` (`strategy: {:branch, head}`, `sync_remote`, `push: true`, `resume_session`, `path:`) | Re-point at a **follow-up run** (§3, §4). PrFix keeps its pure planner; output becomes run-start params. |
| `threads/steerer.ex`, `threads/actions.ex` | `Jobsite.steer/3`, `Jobsite.cancel/2`, `Executor.pid_for/1`; `door: :jobsite` | Steer/stop use run commands only. `jobsite` door stays as a read-only legacy door (§6). |
| `projects/fork_source.ex` | `resolve("jobsite", id)` reads `JobsiteSessionBound` | Keep (reads frozen history). |
| `workflow/lowering.ex`, `run_executor.ex`, `workflow/worktree.ex`, `workflow/jobsite_observer.ex` | substrate only | No behavior change; renamed in the last PR. |
| `JobsiteController` + `router.ex` (`/api/jobsites`, `:jobsite_api` pipeline) | the door | Delete. |
| `threads/*`, `overview/*`, `notifier/mapping.ex` (`JobsiteCompleted/Failed`, `JobsiteCancelled` rules), `usage/*`, `review/*` (`Subject`, `Analyzer`, `Capture`, `Archive`), `coordinator/reporter.ex`, `projection_store.ex` (133 refs), `workspace/nav_runs.ex` + `components.ex` (Jobsite sidebar panel), `adoption*`, `library/collector.ex`, `mcp/approvals_tool.ex` | read the `jobsite:*` projections | Keep folds (legacy history). New work stops producing jobsite events; drop the Jobsite nav panel once no live jobsites can exist. |
| MCP (`mcp/tools.ex`) | **no jobsite tool exists**; only the `door` enum on `foreman_thread_list` and descriptions | Keep `door` enum value `jobsite` (legacy filter), reword descriptions. `tool_inventory_test` should change only in text assertions. |
| CLI (`jobsite.go`, `main.go`, `thread.go`, `init.go`, `needs_you.go`, `project_*.go`, tests incl. `usage_drift_test.go`) | `foreman jobsite template`, `init --template`, `thread list --door` | Remove `jobsite` verb + templates; keep `--door` (legacy). |
| `config/{config,runtime,test}.exs`, `application.ex` | `:jobsites` config, `Jobsite.Registry/Control/Supervisor/BootRecovery` children | Remove with the door. |
| `scripts/e2e/*` (network_policy_flow, project_archive_flow, multi_repo*, failure_injection, claude_projects/*) | drive jobsites | Rewrite onto runs / fix-runs. |
| ~76 test files mention `Jobsite` | | Substrate tests move with the rename; door tests deleted. |

Not verified in Phase 1 (to confirm before the relevant PR): what a project `config.environment.network` policy does
for a *run* today (jobsites refuse it on a host sandbox: `network_policy_unsupported`); whether `Skills.Installer`
leaves an already-installed `foreman-jobsite-template` skill in `~/.foreman/skills` (it only copies missing ones, so
yes, stale skill stays until operators delete it); whether `hooks`, `exclude_paths`, `copy_to_worktree` have any
non-door users.

## 2. Capability decisions

| Capability (jobsite) | Decision | How it lands in runs |
|---|---|---|
| **Docker sandbox** | **Keep** | New optional manifest/phase field `sandbox: docker` (default: none = today's run behavior). `Lowering` emits the existing `:sandbox`/`:release` steps. Strict approval rendering shows it. Image from `.foreman/Dockerfile` as today. |
| **Host sandbox** | **Drop (no-op)** | Runs *are* host execution; the concept and `allow_host_sandbox` flag disappear. |
| **NetworkPolicy** | **Keep, docker only** | Same enforcement as today (docker jobsites only). Corrected after PR1: a run WITHOUT `sandbox: docker` still cannot enforce a project network policy (the documented workflow-door limitation, unchanged); a run WITH it applies the policy exactly as a jobsite did, and refuses the run with `{:network_policy, code}` if it cannot. Boot sweep (`NetworkPolicy.sweep_orphans/1`) stays. |
| **Push to existing PR head, fast-forward only** | **Keep** | Follow-up run with `attach_branch` (worktree at the branch tip on `origin`, `sync_remote` ff-only, never force) and `push: true` publishing exactly that branch. Required by PrFix. New `Workflow.Worktree` "attach" mode beside "create from base". |
| **Crash-resume of a provider session with a custom prompt** | **Keep** | `RunExecutor` resume uses the last `WorkerSessionBound` session id (the `put_fork` path at run_executor.ex:1574 already carries `provider_session_id`) plus the pending steer text as prompt. Parity rule from `BootRecovery`: no recorded session => run fails `executor_lost`, never starts a blank agent. Replaces `Jobsite.BootRecovery`; `Workflow.BootReconciliation` owns it. |
| **Steer** | **Drop jobsite's, runs already have it** | `run.steer` (live via `LiveSteer`, pause/resume fallback). `Jobsite.steer/3` deleted. |
| **`merge_branch` / `merge_into`** (`POST /api/jobsites/:id/merge`) | **Drop** | It merges into a checked-out branch of the operator's main checkout, which contradicts "Foreman owns worktrees; nothing writes the main checkout" (CLAUDE.md §12, §23) and bypasses the operator-only merge gate (§20.2). Merging stays `merge_approve` -> `run.pr.merge`. **Loss to confirm:** no local-merge shortcut. |
| Iteration loop (`max_iterations`, `completion_signal`) | **Drop from the public surface** (engine keeps `Overwatch` iteration) | Not on your list; the only users are the 5 templates. Cheap to re-expose as a phase field later. **Confirm.** |
| Remote spec API, templates, prompt-to-template, `foreman_client`, audit | **Drop** | Replacement for a remote caller: `task.create` (MCP `foreman_task_create` / `POST /api/commands`) which already accepts `prompt`, repo targeting and `auto_approve`. |
| `bead_id` on spec (gap-bead comments via `Review.BeadSink`) | **Drop** | Runs reach beads through their task. Closes the class of kata `801q`. |

## 3. Admission: how runs will admit fix runs

Today jobsites bypass `RunAdmission` and the global `RunSlots`: they take only `project.reserve_thread`
(daily cap, paused/archived refusal) plus a controller-level `max_concurrent_jobsites` (HTTP 429 only).
Consequences already filed: archive not refused while a jobsite runs (`30b2`), no re-check while iterating (`f793`).

Plan: `RunAdmission.start/2` stays the **only** run-start entry (`admission_facade_enforcement_test` untouched; its
allowlist is `workflow/dispatcher.ex` and `run_lifecycle_reconciler.ex`, neither changes).

1. New **system-only** command `run.followup.request` -> event `RunFollowUpRequested` on the *new run's* stream
   (`kind: "pr_fix"`, `parent_run_id`, `pr_url`, `fix_kind`, `attach_branch`, `push: true`, `resume_session_id`,
   `note`). `PrWatcher` dispatches it where it now calls `Jobsite.run_async/1`. It is **not** added to any operator
   allowlist (`operator_only_pr_commands_test`, `command_allowlist_parity_test` stay as they are).
2. `Workflow.Dispatcher` consumes it and calls `RunAdmission.start/2`, so it passes the slot gate (queued
   durably as `:slot_queued`), project limits (`ProjectLimits`, which already caps by global slots), paused/archived
   refusal, `project.reserve_thread` and the daily cap, with the same-implementation single-flight not applying (no TRD key).
3. A fix run needs no task and mints no Bead (`task.create` would mint one: wrong). `Aggregates.Run` already allows
   `task_id: nil`; the executor must tolerate it (verify in PR 3; if any phase code assumes a task, thread it through
   the `parent_run_id`'s task instead of creating one).
4. Behavior change to accept explicitly: **a fix can now wait behind full run slots** (previously it started
   immediately). `PrWatch` already allows one fix in flight per PR; a queued fix counts as in flight, loop guards
   (5 attempts/kind, `no_progress`) are unchanged. `PrFixStarted` gains an optional `run_id` (keeps `jobsite_id`
   for replay of old streams).
5. Side effect: the daily thread cap and project archive/pause checks now cover fixes, fixing `30b2`/`f793` by construction.

## 4. PrFix must keep working (acceptance gates)

PrFix is the only production user of the door. Its contract (`pr_fix.ex` moduledoc) is preserved field by field:
head-branch attach at the `origin` tip, `push: true` ff-only to that branch only, run's provider/model/approval mode,
`resume_session` only when the fix runs at the same worktree path and the PR is the primary repo's, redaction of
prompt with `Coordinator.Redact`, untrusted PR text fenced. Gates for PR 4: `pr_fix_test`, `pr_watcher_*` tests,
`scripts/e2e/claude_projects/pr_fix_evidence.exs`, and the live scenario in `docs/acceptance/live-claude-prfix-resume.md`
re-run (Claude, haiku) since the resume path moves.

## 5. Phase 2 PR sequence (each small, each green on its own, door stays functional until PR 6)

0. **Characterization**: tests pinning current PrFix->jobsite option mapping so PR 4 can assert equivalence. No behavior change.
1. **Run sandbox + network policy**: `sandbox:` field (Interpreter, PhaseSpec, strict approval render, Lowering steps).
2. **Session resume with prompt on run resume** + `executor_lost` parity in `BootReconciliation`.
3. **Follow-up run kind**: `run.followup.request`, attach-branch worktree mode, `push: true`, Dispatcher admission. Behind
   `config :foreman_server, :followup_runs` (default **off**): first PR that writes new event keys, so rollback stays safe until enabled.
4. **PrFix/PrWatcher on follow-up runs**; flag on in dev; live acceptance re-run.
5. **Threads/Overview/Notifier/nav/usage**: fix threads are runs; `jobsite` becomes a read-only legacy door; Notifier rows for `Jobsite*` stay (history replays) but the Notifier skip for "PR fix thread's jobsite" becomes a run rule.
6. **Cutover**: `Aggregates.Jobsite.handle_command` rejects everything with `:jobsite_retired`; one-time boot closer fails stranded non-terminal jobsites (§6).
7. **Delete the door**: facade, Executor, Supervisor/Registry/Control, BootRecovery, Spec, Template/*, controller + routes, audit writer, CLI verb + templates, `foreman_client`, skill, env/config, e2e rewrites. Go `usage_drift_test` and `tool_inventory_test` updated.
8. **Docs**: CLAUDE.md §12 (Project environment names `Jobsite.Executor`), §13.1 (Jobsite nav panel), §20.1, §21, §24, §26; `docs/user-guide.md`, `docs/cli-reference.md`. **`AGENTS.md` is read-only for me (CLAUDE.md says so) and has jobsite sections; you will need to update it or lift that rule.**
9. **Rename substrate** `ForemanServer.Jobsite.*` -> `ForemanServer.Exec.*` (mechanical; last, to avoid conflicting with in-flight work). Telemetry event names and any persisted strings (`agent.provider` payloads) are not renamed.

Each PR: kata issue (search, create, claim, close with `--test`), `mix test` for touched areas plus the three admission/allowlist tests named above.

## 6. Migrating existing jobsite event streams

Streams `jobsite:<id>` (16 event types: Started, Iteration*, SessionBound, Commits/Output captured, Worktree/Sandbox
provisioned/released, Paused, Cancelled, Completed, Failed) and `jobsite_audit:global` already exist in operator stores.
The event store is append-only; **we do not rewrite or upcast them into run events.**

- **Keep forever, read-only:** the `Events.Jobsite*` structs, `Aggregates.Jobsite.apply_event/2` fold, the
  `ProjectionStore` folds and `CommandRouter.aggregate_module_for("jobsite:" <> _)`. Removing any of them makes replay of
  existing stores fail (`EventCodec` has no fallback for an unknown type). Threads, Overview history, usage rollups,
  review archives and `fork_source` keep working on them.
- **Stranded at cutover:** at PR 6 a one-time boot closer fails every non-terminal jobsite with code `jobsite_retired`
  (status becomes `failed`, so Threads/Overview stop showing it as live). Worktrees stay on disk; nothing is force-deleted
  (CLAUDE.md §12 clean-vs-dirty rule).
- `jobsite_audit:global`: stop writing, keep the fold.
- Compaction/archival of legacy streams is out of scope; revisit only if replay time becomes a problem.

## 7. Rollback caveat (`EventCodec` rejects unknown keys)

`EventCodec` rejects keys not declared on the event struct, and a build without a declared field raises when it
replays an event carrying it (same shape as the E12 multi-repo caveat, CLAUDE.md §20.2).

- New fields (`RunFollowUpRequested` and its payload keys, `PrFixStarted.run_id`, any `sandbox`/`attach_branch`/`push`
  on run events) must be declared struct fields **in the same commit as their writer** and never in `@enforce_keys`.
- **Safe window:** while `:followup_runs` is off (PRs 0-3) no new keys are written; rolling back is safe.
- **After the first follow-up run is recorded, rolling back to a pre-PR-3 build is NOT safe**: it raises on that
  run's events. State this in the PR 3/4 release note. Turning the flag off stops new fix runs but cannot remove events.
- Rolling back across PR 6/7 keeps the jobsite streams readable, because their events are never deleted. The
  boot closer's `JobsiteFailed` carries a new `code` *value* (`jobsite_retired`), not a new key, so an older build decodes it.
- Never reintroduce a deleted event struct under a different shape.

## 8. Decisions (all resolved 2026-11-19, as recommended)

1. Confirm dropping `merge_into` (§2) and the iteration loop (`max_iterations`/`completion_signal`) from the public surface.
2. Confirm fixes queue behind global run slots (§3.4), or ask for a reserved fix slot.
3. Confirm the `jobsite` thread door stays as read-only history (vs. hiding legacy jobsites entirely).
4. AGENTS.md: may I edit it in Phase 2 PR 8?
5. Confirm you are overriding the 2026-10-23 KEEP decision (`9mds`) for the remote API.

Resolved: (1) drop `merge_into` and the iteration loop; (2) fixes queue behind global run slots; (3) `jobsite` thread door stays read-only history; (4) AGENTS.md may be edited in PR 8; (5) the 2026-10-23 KEEP decision (`9mds`) is overridden and the remote API is removed.

## 9. Findings during Phase 2 (corrections to the plan)

- **PR1 split**: 1a = `Lowering` sandbox/release steps + `Runners.Overwatch` passes the sandbox shim as harness `cli_path`; 1b = workflow-level `sandbox: docker` manifest key (Interpreter, Catalog + digest only when declared, approval snapshot, `RunExecutor`), network policy, cleanup of the container and policy network on every program exit.
- **`cli_path` is shared** with Claude's in-flight approval wrapper (`Approvals.Inflight`). Sandboxed runs skip in-flight approvals and keep the pause-and-re-run path.
- **Sandboxed runs are single-repo**: `{:sandbox_unsupported, :multi_repo}`.
- **Known limit**: `FOREMAN_*` path env vars (`FOREMAN_WORKTREE_PATH` etc.) are host paths and are not translated inside the container; a sandboxed phase must not depend on them. PrFix prompts do not.
- **Crashed server leaves the container**: same as jobsites today (kata `ptpn`); the boot sweep of `NetworkPolicy.sweep_orphans/1` is the existing mitigation and still needs wiring beyond `Jobsite.BootRecovery` before PR 7 deletes it.
- Pre-existing test failures on the base branch (not caused by this work): 3 tests on the bundled `fix.yaml` (`prompt_inbox_progress_test`, `catalog_test` fix workflow, `full_workflow_lifecycle_test`), from commit `dd0c239b`.
