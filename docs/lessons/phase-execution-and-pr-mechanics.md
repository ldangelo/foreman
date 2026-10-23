# Phase execution, AutoPR, timeouts, artifact/env contract, merge gate

> Archived verbatim from the former monolithic `AGENTS.md` (2026-10-18) to keep the always-loaded agent context small. RunExecutor/Jobsite engine, `commit:`/`stack_pr:`/`timeout_minutes:`, AutoPR base-branch resolution, `FOREMAN_*` env contract, operator-only merge gate, remote Jobsite API.
> Section-number references inside (e.g. "section 4", "§5.4") point at the pre-split `AGENTS.md`; the §5 rules are summarised in `AGENTS.md` and full text is in `typed-boundaries-full.md`.

RunExecutor phase completion rules (these now live in `ForemanServer.Jobsite.Runners.Overwatch.wait_for_worker_result/4`, the wait every manifest phase goes through; `RunExecutor` itself holds no phase loop — see "Phase execution runs on the Jobsite engine" below): (1) A phase deadline bounds how long the executor waits for `{:worker_result, _}`; it does not invalidate a non-empty `{:ok, output}` success already in the mailbox — that success stays authoritative even if final lifecycle dispatch crosses the wall-clock deadline, while a queued error may still be rejected as `:worker_timeout`. (2) Every timeout return path MUST drain any `{:worker_result, _}` left in the mailbox before returning: `handle_info/2` has no such clause (no permissive catch-all, §5.2), so an undispatched result would be matched by the NEXT phase and committed as its artifact. (3) A worker that died without producing a result is always `:worker_died_no_result`, even past the deadline; `:worker_timeout` means "deadline elapsed, result unknown", never "crash" (§5.3).

**Phase execution runs on the Jobsite engine (cutover, 2026-10).** `RunExecutor` no longer walks phases itself. `handle_kickoff_ready/1` calls `run_phases/1`, which compiles the manifest's phases with `Workflow.Lowering.lower/2` into one `Jobsite.Program` and runs it on `Jobsite.Engine.run_program/3` with `Workflow.JobsiteObserver`; the executor's own state map is the observer's state and comes back in the engine's outcome. What was the per-phase loop is now: the engine's `:intent` check before each phase's FIRST step (`RunControl.intent/1`, pause/cancel between phases); `RunExecutor.phase_begin/3` (`phase.start` + the run's worktree, reused with `base_ref` refreshed on every phase after the first); `phase_launch/4` + the Overwatch runner (agent dispatch, `HeartbeatLease`, the wait); `ArtifactTemplate.write/4`; `enforce_required_file/4` (the `:gate` step); the engine's `:commit` step (`Jobsite.Git.commit_all/3`); `phase_finish/5` (`phase.complete`); and `step_failed/4` → `handle_phase_body_error/6` (pause commits partial work, cancel stops clean, otherwise `phase.fail`). `finish_phases/1` is the one place that still checks intent before `finalize_run/1`. A `bash:` phase, or a `command:` phase with no command, is now refused when the program is built — before any worktree exists — instead of mid-run. Deleted with the loop: `run_single_phase/3`, `handle_cast({:advance_to, _})` and the public `RunExecutor.advance_to/2`, `start_phase_at_index/2`, `execute_agent/4`, `dispatch_agent/5` (its pre-launch half is `prepare_agent_launch/5`), `wait_for_worker_result/4` (moved to the runner), `emit_phase_blocked/3`, and `Workflow.StepSequencer` (its halt-on-`:blocked`/`:failed` branch could never be reached: `phase_statuses` only ever holds `:completed`). Do not reintroduce a second phase loop: two live phase implementations is the duplication this cutover removed.

**Remote Jobsite API (`/api/jobsites`, 2026-10).** A second front-end onto `Jobsite.run_async/1`: scripts run on the CLIENT and call JSON routes on a running server (`JobsiteController`; `POST /api/jobsites`, `GET /api/jobsites[/:id]`, `POST /api/jobsites/:id/{pause,cancel,resume,merge}`). The body is validated by `Jobsite.Spec.from_json/2` — a string-keyed whitelist that rejects `on_event`/`reply_to`/`prompt_file`/`repo_path`/unknown keys and never mints atoms — so the server never evaluates caller code. Rules that must not be relaxed: (1) the routes sit behind `RequireAuthenticated`, which FAILS CLOSED (401 when no `:api_bearer_token` is configured) and, unlike `BearerAuth` on `/api` (also fail-closed since 2026-10-19, but with an `:api, allow_insecure_local` dev opt-in), has NO opt-in; (2) starting AND resuming (`POST /:id/resume` starts an executor too) also need `config :foreman_server, :jobsites, allow_remote_start: true` (exactly `true`, default off) (or `FOREMAN_JOBSITES_ALLOW_REMOTE_START=true`; `FOREMAN_JOBSITES_ALLOW_HOST_SANDBOX`, `FOREMAN_JOBSITES_AGENT_ENV_ALLOWLIST` (comma-separated) and `FOREMAN_API_TOKEN` likewise — all read by `config/runtime.exs`, never in the test env, only when the variable is present) and is capped by `max_concurrent_jobsites` (default 3, counted from `Jobsite.Registry`; enforced atomically by `Jobsite.Supervisor`, which counts live executors and starts the child under one lock, so simultaneous requests cannot exceed it; start and resume both go through it); (3) `hooks.host.*` is FORBIDDEN (`:spec_hooks_forbidden`) because `Hooks.run_host/3` runs `sh -c` on the server — only `hooks.sandbox.*` is accepted; (4) the Docker sandbox bind-mounts the worktree and, for a linked worktree, the repo's whole git dir read-write at the SAME host path (the worktree's `.git` file points there; without it git fails in the container and agents `git init` an unrelated history) with `safe.directory` set only for those two paths (the sandbox path and the git dir; an unresolvable git dir fails sandbox creation as `:sandbox_create_failed` instead of mounting nothing) — so the agent can rewrite any ref in that repo; the sandbox defaults to `docker`, `host` only when `:jobsites, allow_host_sandbox: true`; `agent.env` is refused unless every key is in `:jobsites, agent_env_allowlist`; `agent.env` values are NEVER written to `JobsiteStarted` (they would sit in the event store in clear text), so a resumed jobsite runs without them — `approval_mode` IS persisted; (5) the repo is a registered `project_id`, never a client path; (6) every start/pause/cancel/resume/merge request, accepted or rejected, is recorded on the single stream `jobsite_audit:global` (`Aggregates.JobsiteAudit`, system-only command `jobsite.audit.record`, event `JobsiteRequestAudited`) with the TCP peer address — behind a proxy that is the proxy's address, the shared token has no per-user identity, and requests rejected by the auth plug (401) are not audited. `push: true` publishes the branch to the fixed remote `origin` after the commit and requires a `{"branch": name}` strategy (`:spec_push_requires_branch`); a failed push fails the jobsite with `:push_failed` and keeps the commits on the local branch. `push` is persisted on `JobsiteStarted` and the aggregate (`push?`) because resume rebuilds from events and is given no options — without that a resumed run silently skips its push. `Control.request/2` only writes an ETS intent and checks nothing, so the controller verifies a live executor before pause/cancel and `Jobsite.resume_async/1` verifies aggregate state before resuming (the Executor reports a rejected resume only to `reply_to`, which a background resume lacks). `Jobsite.merge_into/2` merges a COMPLETED jobsite's branch only into the branch currently checked out in the repo (caller names it; mismatch is 409) and reads `repo_path` from the event stream because the projection has none. Templates `basic`/`iterate`/`parallel` drive this API through the `foreman_client` package (`packages/foreman_client`, loaded with `Mix.install`; `:httpc` + OTP `:json`, needs OTP 27+; it is NOT copied into projects, so `foreman init` cannot leave a stale copy behind); `review`/`triage` still call `ForemanServer.Jobsite` directly under `mix run` because they drive a live sandbox the API does not expose.

**Jobsite and workflow share one engine, not one state model (post-cutover cleanup, 2026-10).** A workflow run is NOT a jobsite aggregate: it emits `run:`/`phase:` events and never `Jobsite*` events, so `/api/jobsites` cannot see workflow runs. What is shared is `Jobsite.Engine`, and the raw git primitives: `RunExecutor`'s pause-path commit is `Jobsite.Git.commit_all/3` (trailing `opts` defaults to `[]`; message `Foreman run <run_id> phase <index>`), its checkout-branch probe is `Jobsite.Git.current_branch/1`, and `VcsAdapter.Default`/`Workflow.Worktree` build `git worktree add` args via `Jobsite.Git.worktree_add_args/4` and delete branches via `Jobsite.Git.delete_branch/2`. Do not reintroduce a private commit/branch helper in `RunExecutor`. Deliberately NOT shared, because the behaviour differs: `VcsAdapter.Default` remove+prune (ignores prune failure, needs the raw exit code), its `create_worktree` rollback (prunes even when remove fails), its `.beads` `--no-cone` sparse exclude, `AutoPR`/`PhasePR` `git push` (their own failure handling; `Jobsite.Git.push` uses an explicit refspec and kills the push process tree), and `RunControl` vs `Jobsite.Control` (roughly 12 to 15 duplicated lines, counted by reading both modules: only `start_link`, the `:ets.new` in `init`, and `clear` match; the stored shapes differ, `RunControl` also tracks `harness_run_id`, and a shared owner module would cost as much as it removed, so do not re-attempt it). `Jobsite.BootRecovery` (started after `CommandRouter`, gated by `:start_jobsite_boot_recovery?`) pauses every non-terminal jobsite (candidates come from the event store's `jobsite:` streams, never the projection, whose failed boot replay falls back to an empty state) that has no live executor with reason `server_restart` (a jobsite that never provisioned a worktree is failed `executor_lost`); it NEVER resumes, because `agent.env` is not persisted and remote start is gated by `allow_remote_start`. Resume refuses such a jobsite up front: `Executor.check_resumable/1` (the one precondition shared by `Jobsite.resume/1`, `Jobsite.resume_async/2` and `Executor.resume/2`) returns `:not_resumable` (`409` over the API) for a jobsite with no `worktree_path`, before any executor starts, so `Executor.resume/2` never passes a nil `worktree_path` to `File.dir?/1`.

**Crash recovery after `kill -9` (2026-10).** Boot replay (`Dispatcher`, `ProjectionStore.subscribe(replay_existing: true)`) re-delivers `TaskDispatched` for a run the previous server left in flight. It used to start that run as a brand-new one, so `create_run_worktree` hit `git worktree add` on a path that already existed (`{:git_worktree_create_failed, 128, ... already exists}`). `Dispatcher.crash_resume_opts/2` now starts a non-terminal existing run with `resume_from:` (first unfinished phase), which reuses the persisted worktree via `rehydrate_resume_context/1`; an operator-paused run is not started at all. Replayed `RunPaused` events act only while the run projection is still `paused` (otherwise a finished steered run was re-paused, its slot/lease re-released and `had no active agent to cancel` logged on every boot). Agents run under erlexec (`{:group, 0}`, `:kill_group`): when only the BEAM dies, `exec-port` kills them (probed live). When `exec-port` dies too (`pkill -9 -f` on the repo path, OOM) the agent (`pi`, its `bash` tool in a separate process group, `sleep`) is re-parented to pid 1 and keeps editing the worktree. No pid is persisted, so `Workflow.OrphanReaper.reap/1` finds processes by cwd inside the worktree with ppid 1, then kills them and all descendants (TERM then KILL) before a resumed run (`RunExecutor`) or resumed jobsite (`Jobsite.Executor.resume/2`, `:orphan_agent_survived`) reuses the worktree. It needs `lsof`/`ps`; a failed scan is logged and the resume continues, a process surviving SIGKILL fails the resume. Recognised orphans are pid-1 children only (no subreaper support).

**Session archive + automated review (`ForemanServer.Review.*`, 2026-10).** Two decoupled stages joined by an on-disk archive (`<repo>/.foreman/sessions/<run|jobsite>/<id>/`, layout in `docs/user-guide.md`). *Capture* writes plain files, no events: the jobsite door appends `RunResult.events` from `Jobsite.AgentRunner` (via `archive_dir` in the engine's `runner_opts`, set only for steps carrying `archive_spec`, so the workflow door never writes to `jobsite/`), `request.md` is written by `Engine` right after `Prompt.resolve` (byte-identical to what the agent saw), and `diff.patch` by `Executor.Observer` at the `:commit` step (the last point the worktree is guaranteed alive). The workflow door captures only the diff + manifest, as the FIRST statement of `RunExecutor.cleanup_run_worktree/2` (the one funnel for both terminal paths; by `RunCompleted` the worktree is already gone) and rebuilds the transcript at analysis time from `ProjectionStore.run_logs/1` — do NOT change `Overwatch`/`JidoHarnessWorker` result tuples for this (`Runners.Overwatch` and sibling clauses match `{:ok, binary}`). *Cancelled* work is archived and reviewed too (manifest `status: "cancelled"`), and it is never committed, so its diff is the WORKING-TREE diff against the base (`Jobsite.Git.diff/3`/`changed_files/3` with head `:worktree` run `git diff <base> --` and are pure reads; `Capture.do_put_diff/4` first calls `Git.mark_intent_to_add/1`, which marks the checkout's new files intent-to-add): uncommitted changes to tracked files and new untracked files are included (gitignored files are not). A failed mark (a held `index.lock`, a refused path) must never pass for a complete diff: `Capture` records it as a `capture_errors` entry for stage `intent_to_add` and still captures the tracked-file diff, which then omits the new files, so do NOT fold the marking back into `Git.diff/3`, where its failure could only be logged. A cancelled jobsite captures it in `Executor.handle_interrupt(:cancel)` just before `cleanup/3` discards the worktree. A cancelled workflow run never reaches `cleanup_run_worktree/2` (the worktree is retained), and `run.cancel` is recorded BEFORE its executor has actually stopped, so on `RunCancelled` the Analyzer first waits up to 30 s (polling `RunExecutorRegistry`) for the executor to exit and then calls `Capture.close_cancelled_run/1`, which builds the archive from the projections (`worktrees_for_run/1`); capturing earlier races the executor's own writes. `RunFailed` is the same race from the other side: `RunExecutor.emit_phase_failure/4` dispatches `run.fail` BEFORE `finalize_terminal_and_stop/2` reaches `cleanup_run_worktree/2`, so a failed run's archive does not exist yet when the event is projected and reviewing it at once records a permanent `undetermined`/`archive_missing`; the Analyzer therefore waits for the executor to exit (same 30 s bound) and adds no capture of its own, because the executor writes that archive. `RunCompleted` is deliberately never waited for: `finalize_run/1` captures before `run.complete` and the executor then stays alive, so the wait would always run to its timeout (`analyzer_test.exs` pins both). The Analyzer also runs at most one analysis per subject (`in_flight`, released on the task's `:DOWN`): the recorded review is the durable guard but is written after the bead comment and the gap beads, so a duplicate terminal event arriving mid-analysis would otherwise repeat both. It reads events at one boundary, `event_type/1` + `unwrap_data/1`, which normalise the type and the payload to atom-keyed `run_id`/`jobsite_id` from an explicit whitelist (both key conventions are read there and nowhere else, and no atom is minted from event data), so `handle_event/2` and `subject_from_event/2` take atom-keyed payloads and projections are read with plain atom keys. *Analysis* is `Review.Analyzer` (subscribes with `replay_existing: false`; reacts to exactly the six terminal events `RunCompleted`/`RunFailed`/`RunCancelled`/`JobsiteCompleted`/`JobsiteFailed`/`JobsiteCancelled`) → `Review.Evaluator` (swappable behaviour; production = `Evaluator.Agent` over `DetachedRun`, `sandbox_mode: :read_only`, strict JSON parsing, a reviewer may never return `undetermined`; the prompt (`priv/review/analysis_prompt.md`) scopes the grade to the diff's content, so push/merge/PR/main-branch outcome is never a gap and other branches/remotes are not inspected) → `analysis.{json,md}` → `Review.BeadSink` → `review.record`/`ReviewRecorded` (stream `review:<kind>:<id>`, idempotent by `command_id`; a failed evaluation is still recorded as `undetermined` + `error_code`). Bead step: comment on the source bead, then one `foreman-exec` + `foreman-gap` bead per gap (cap `:max_gap_beads`). Loop guard: the review event log — a bead is a gap bead if an earlier recorded review filed it (`ProjectionStore.gap_bead?/1`), so no `br show` is needed — and such a source bead gets no gap beads. That guard is the ONLY thing stopping gap-of-gap-of-gap: `BeadsWatcher.foreman_tag?/1` tests `is_map(agent_context)` but `br` round-trips `agent_context` as a JSON *string*, so it does not skip Foreman-created beads — which is what makes gap beads dispatchable at all; `beads_watcher_gap_bead_test.exs` pins this, so "fixing" `foreman_tag?/1` fails loudly rather than silently disabling gap dispatch. Run bead ids come only from task ids of the form `beads:<project>:<bead>` (`Capture.bead_id_for_task/1`); the bead step needs `bead_id` AND `project_id`; a jobsite without `project_id` is still reviewed (`ReviewRecorded.project_id` is nullable, `BeadSink.publish/2` returns a `BeadSink.Result` whose note is `no project_id: bead step skipped`). Transcript lines are `{type, timestamp, text, stream}` and are redacted via `Jido.Harness.Redaction` in `Archive.encode_line/5` (shared by the evaluator transcript and run logs). Known limits: a review is write-once per subject (a recorded `undetermined` is never retried), the Analyzer does not replay history on boot, `:pi` surfaced zero text events in a smoke test, and operators should gitignore `.foreman/sessions/`; a workflow transcript is the bounded, redacted run log (truncation is recorded in the manifest); a hanging or cancelled iteration produces no `RunResult`, so its in-flight output is missing from the transcript (the run itself is still archived and reviewed).

Workflow note — PR behavior (corrected 2026-08-26): this file previously said
PR/merge is controlled by phase-level `checkpointPr: true` plus explicit
`create-pr`, `pr-wait`, and `merge` phases. **This codebase implements none of
that.** No module reads `checkpointPr`, and nothing dispatches a `builtin: true`
phase — zero matches across `packages/foreman_server` and `packages/foreman_cli`.

That syntax *does* appear in stale workflows sitting in the installed runtime
catalog (`~/.foreman/workflows/`: `default.yaml`, `feature.yaml`, `task.yaml`,
`epic.yaml`, `bug.yaml`), left over from an earlier implementation. They are not
executable here: `Workflow.Validator.validate_phase/2` requires every phase to
declare `command`, `prompt`, or `bash`, and those `builtin: true` phases declare
none, so loading one fails with `{:missing_phase_action, index}`. Presence in
that directory is not evidence a mechanism works — the supported set is
`packages/foreman_server/priv/defaults/workflows/`. Do not author `builtin`,
`checkpointPr`, `create-pr`, `pr-wait`, or `merge` phases, and do not dispatch
those stale workflows.

**`commit:`, `stack_pr:`, and `timeout_minutes:` are phase-level fields; top-level PR/merge tags
remain unsupported.** `commit: true` (the default when the key is absent)
commits the phase's work when the phase completes; `commit: false` DEFERS it,
leaving the changes in the worktree for a later phase's commit to absorb, which
is how several phases are batched into one commit. `stack_pr: true` requests a
phase PR record after that phase's commit decision, targeting the recorded run
base branch from the same Foreman run branch. Absent or false preserves default
final-AutoPR behavior. `PhaseSpec.@fields` plus `commit`/`stack_pr`, plus the
workflow-level `worktree:` block (`enabled`/`base`/`branch`/`path`/`cleanup`),
is the complete declarable vocabulary. `approval_mode:` is a phase field
(`default | prompt | auto_edit | auto_approve`, validated by
`Interpreter.validate_phase_approval_modes!/2`) that `RunExecutor` appends to the
agent's `driver_opts`. Left unset, Claude runs in its interactive permission mode
and cannot write headlessly; such a phase now FAILS with
`{:permission_denied, [tool_names]}` (from the structured `permission_denials` in
the harness result, `JidoHarness.RunResult.normalize/1`) instead of completing
with no changes. `{task.projectReportsDir}` resolves against the run worktree,
then the task's working directory, then the registered project path — never the
server's cwd. `timeout_minutes:` (alias `timeoutMinutes:`) is a
non-negative integer phase execution timeout in minutes. When the key is
present — `0` included — it is authoritative and nothing below overrides it:
`RunExecutor` passes `timeout_ms: :infinity` for `0` and
`timeout_ms: minutes * 60_000` for a positive value (`phase_timeout_opts/1`).
An ABSENT key passes no override at all, so the deadline resolves through
`FailurePolicy.resolve/2` precedence, high → low:

1. Per-call `opts` — only present keys override; this is where a phase's
   `timeout_minutes:` lands.
2. Per-task-type app config: `:foreman_server, :agent_runtime,
   :failure_policies[task_type][:timeout_ms]`.
3. App-config default: `:foreman_server, :agent_runtime, :default_timeout_ms`.
4. Built-in `@default_timeout_ms`, which is `:infinity`
   (unattended-run-control, 2026-09) — not a 60-second/30-minute ceiling.

`failure_policy.ex:67-83` is the source of truth for that order; the bundled
workflows no longer declare `timeout_minutes:` at all, so an absent-timeout
phase has no wall-clock deadline in normal operation. Declare a positive
`timeout_minutes:` to opt a specific phase back into a deadline; app-config
`failure_policies` can still pin one per task type.

**A live 30-minute ceiling on a phase that declares no `timeout_minutes:` has
no identified cause (foreman-4uj5, 2026-09-18); do not assert one here.** The
stale-pre-#510-server story was the initial hypothesis, and the obvious form of
it is FALSIFIED: the pre-#510 built-in default a stale BEAM would have retained
was `60_000` ms, not `1_800_000`, and the run in question dispatched ~12 h after
#510 merged from a checkout — and an installed runtime workflow
(`~/.foreman/workflows/prd.yaml`) — whose `coderabbit-review` phase declares no
`timeout_minutes:`. The pre-#510 `packages/foreman_server/config/{dev,prod}.exs` block
that did set `default_timeout_ms: 1_800_000` is still a plausible path for a
long-lived BEAM started before #510 — but prove it against the live process
first: read its `:foreman_server, :agent_runtime` app env and the
`timeout_minutes:` in the workflow copy it actually loaded. The only other
`1_800_000` in `lib/` is `StallPolicy`'s opt-in messaging-stall threshold, which
emits `RunFlaggedStuck`, not `:worker_timeout`.
`Interpreter` and `PhaseSpec` still contain zero top-level `pr`, `merge`, or
`checkpoint` keys.

**Deferral is rejected at LOAD time in exactly ONE case — the one the manifest
alone makes unsatisfiable — and warned about at run terminal in the case whose
consequence is merely invisible.** `Interpreter.validate_commit_cleanup!/3`
refuses a manifest whose work no phase will ever commit when
`worktree.cleanup` is `always` or `on_success`: both modes delete the run's
worktree, so the deferred changes are destroyed with no branch and nothing for
`AutoPR` to propose. Absent `cleanup:` is `never`, matching
`RunExecutor.worktree_cleanup/1` — reading it as `always` would refuse nearly
every deferring manifest, since most declare no `worktree:` block at all.

Under `cleanup: never` the same manifest LOADS, and `RunExecutor`'s
`warn_uncommitted_work/1` logs at run terminal instead, naming the deferring
phase. It reads the phases that actually EXECUTED, not the manifest, so a run
that fails before the absorbing phase still warns — an end-of-manifest check
would see a committing phase that never ran and report no problem.

**This passage previously described TWO load-time refusals; both claims are
now wrong, and the way they were wrong is the point.**

1. **A `requiredFile:` phase reached with work pending** was refused because
   `PlanContext.discover_document/3` unions "committed since `base_ref`" with
   "uncommitted in the working tree", so a non-committing predecessor's files
   read as the successor's own new document — the gate passes while attributing
   one phase's document to another. That hazard is REAL and still exists. The
   refusal was the wrong response to it: it made deferral and discovery mutually
   exclusive, so the phase immediately before a gated phase could never defer —
   exactly the batching the tag exists to provide, and the shape `plan` and
   `prd` want. Mis-attribution is a property of what discovery SCOPES; a
   load-time veto on manifest shape cannot fix it, and the PRD excludes the
   mechanism by Non-Goal.
2. **Work still pending after the last phase** was refused unconditionally.
   `AutoPR` genuinely counts commits only, so such a run produces no PR — but
   that is a reason to make the absence attributable, not to forbid the
   manifest. The unconditional raise could not distinguish an operator mistake
   from a workflow that deliberately stages changes in a retained worktree for
   human review, and so made the latter inexpressible.

The general rule both corrections express is the PRD's design principle:
**refuse what cannot be honoured, warn where the consequence would merely be
invisible.** Do not re-add a load-time veto on a manifest that a retained
worktree makes perfectly satisfiable.

`CommitDeferral.pending_phase/1` (manifest string keys) and
`pending_phase_spec/1` (normalized `PhaseSpec` atom keys) are two entry points
over one shared fold. That is deliberate, not duplication: the loader and the
executor genuinely hold different shapes, and a
`Map.get(m, :commit) || Map.get(m, "commit")` hedge would leave neither
boundary owning the convention (§5.4). The shared fold is what guarantees the
refusal and the warning cannot disagree about what "pending" means. The pending
flag CLEARS on a committing phase rather than latching, so
`false → true → requiredFile` is valid; among consecutive deferrals it reports
the EARLIEST index, because the operator needs where the uncommitted run begins.

`RunExecutor.phase_commits?/1` matches `true | false | nil` totally rather than
testing truthiness, so a value that somehow bypassed
`validate_commit_value!/3` raises instead of being coerced — the string
`"false"` is truthy and would otherwise commit while the manifest said not to.

Ensemble-skill stacked branches remain separate from Foreman's one-run-branch
model. `stack_pr: true` does **not** create per-phase head branches or a true PR
stack: every tagged phase uses the same run head/base pair, so GitHub usually
has one open PR that later tagged phases reuse and whose diff is cumulative from
the run base. Closed matching PRs are typed failures. No-op phase PR records
(`head` not ahead of `base`) do not suppress final AutoPR; created/reused phase
PR records do. `TRD-2026-3d41f677` is still explicit: "Do not add top-level
workflow `merge:` or `pr:` fields."

`auto_pr/1` is still final-run behavior from `finalize_run/1`; it is skipped
when durable phase PR records already represent the run. `AutoPR.maybe_create_pr/1`
takes a fixed context (`run_id`, `base_branch`, `head_branch`, `artifact_path`,
`cwd`, and optional task metadata) and derives title and body itself; there is
no declarable title, body, draft, reviewer, or label. For task-backed final
AutoPRs, `RunExecutor` passes the task title and description, and AutoPR uses
those exact strings as the GitHub PR title and body. A task title/description
that is present but blank or non-string is a typed metadata error before the
branch is published; a field the task never set is omitted from the context, so
a title-only task (no description) falls back to the generated title/body
rather than failing. For no-task runs AutoPR preserves the legacy generated
title/body;
only that generated-body path appends `ForemanServer.Workflow.ReviewFindings`
content under `## Unresolved review findings` when the artifact contains the
bundled review markers. Phase PRs keep their separate title/body behavior.
Foreman commits with a fixed message, its own author
identity, and `--no-verify`; only WHETHER a phase commits and whether it asks
for a phase PR record are declarable.

The real mechanism is `ForemanServer.Workflow.AutoPR.maybe_create_pr/1`, called
from `RunExecutor.finalize_run/1` after the task provider confirms completion.
It derives the PR from run state rather than from agent output: the head branch
comes from `state.last_worktree.branch` (retained by
`RunExecutor.remember_worktree/2`), which since the move to one worktree per run
is the run's single branch `foreman/<run_id>` rather than the last of N
per-phase branches. The decision is gated on
`git rev-list --count base..head > 0`, the branch is published with
`git push -u origin <head>`, and only then does it shell out to `gh pr create`.
A `FOREMAN_BRANCH=<branch>` marker in the final artifact is still honoured as
an override. Failures log at `error`.

This replaced a design that **could never land a PR**: it required a
`FOREMAN_COMPLETE=true` handoff marker that nothing in the repository emitted,
so `maybe_create_pr` always returned `:noop` at `info` level while the run
reported success, with zero test coverage. Deriving the handoff from run state
is strictly more robust than depending on an agent to print exact lines.

**The PR base is the branch the run's work was cut from, and there is no
default.** `RunExecutor.remember_run_base_branch/1` records it once, when the
run's FIRST phase starts, as `git symbolic-ref --quiet --short HEAD` of
`vcs_working_directory/1` — the same checkout AutoPR later runs `git rev-list`,
`git push`, and `gh pr create` in, read at the same moment
`resolve_run_base/2` reads that same checkout's `HEAD` to give the run worktree
its `base_ref` (the worktree is PINNED to that commit; it does not supply it),
so branch name and base commit describe one repository state. It
is latched on key presence, so an operator switching branches mid-run cannot
retarget the PR, and it does not hang off `remember_worktree/2` — a workflow
declaring `worktree: enabled: false` provisions no worktree yet can still land
a PR through the `FOREMAN_BRANCH` override. `symbolic-ref` is deliberate:
`rev-parse --abbrev-ref HEAD` prints the literal `HEAD` on a detached checkout,
which `gh pr create --base` would accept as a ref name.

`plan_base_branch/1` used to answer this by reading
`plan_context["base_branch"]` and falling back to `"main"`. **Nothing writes
that key** — `PlanContext.build/1` does not produce it, and the `base_branch`
`work.submit` accepts is captured at the protocol level only — so every run
targeted `main`. The first `plan` run to complete end-to-end,
run-776527010ea5d3568b742adbd25ab872, was cut from `feat/mcp-run-details` and
opened PR #420 against `main`: the diff carried an entire unrelated session of
commits instead of the two documents the run produced. An undeterminable base is
now `{:auto_pr_base_branch_unresolved, reason}` and no PR, never a guess —
`{:run_base_branch_unrecorded, run_id}` for absent (no phase started) and
`{:checkout_branch_unresolvable, path, :detached_head | detail}` for malformed
(AGENTS.md 5.3). The `rev-list` gate reads that same base, so it now counts only
the commits the run added on top of its own starting point; against the default
branch it also counted everything the run's base branch already carried, which
is how a run that produced nothing could still look like it had work to propose.

This is the "registered checkout HEAD" tier of
`docs/TRD/TRD-2026-80ba0665-branch-parent-resolution.md`, reached without its
`PlanContext`/`Dispatcher` plumbing: resolving in `PlanContext.build/1` as that
TRD proposes would leave `work.submit` runs — whose `build/1` returns
`:not_applicable`, so they carry no plan context at all — with no base. An
explicit `--base-branch` override is still NOT consumed server-side. (The
`work.*` command ingress described in this passage was retired in favor of
the unified task path — see "Unify Foreman work dispatch onto the task
path" — but the `--base-branch` non-consumption caveat carries over
unchanged to `task.create`. The residual work-request code — the `WorkRequest`
aggregate, the `Work*` events and their projection, `GET /api/work/:id`, the
`foreman_work_get` MCP tool and the executor's `:work_request` source — was
deleted; a persisted `WorkSubmitted` event now falls through
`ProjectionStore`'s unknown-event clause and is ignored.)

**Artifact path is a two-repo contract.** `ArtifactTemplate` expects the phase
artifact at `<artifact_base>/<run_id>/phase-<index>.md` when the phase declares
no `artifact:`. `RunExecutor.foreman_env/3` exports that computed path as
`FOREMAN_ARTIFACT_PATH` on both its non-worktree and worktree clauses
(`run_executor.ex:1647` and `:1653`). The consumer is the `--foreman` path of
the ensemble command YAMLs (`Sunstone/ensemble`,
`packages/development/commands/*.yaml`), which write the phase report to that
exact path in addition to any repo-local report. Absent the variable, ensemble
behavior is unchanged, so the two repos deploy in either order.

**That export was dead from the day it was written until c739e8c9, and this
file claimed it worked the entire time.** `Overwatch.start_phase/2` forwarded
the computed env map to the adapter as `:env_map`, but
`Overwatch.Adapters.JidoHarnessWorker.init/1` read only
`:provider`/`:prompt`/`:driver_opts`/`:result_recipient`, never `:env_map`, and
`run_agent/3` called `Driver.run(provider, prompt, driver_opts)`. Nothing past
Overwatch read the map, so NO variable Foreman exported ever reached a
dispatched agent: `FOREMAN_ARTIFACT_PATH`, `FOREMAN_RUN_ID`, `BEADS_DB`,
`TRD_SCOPE`, `FOREMAN_WORKTREE*`, and every project-configured
`WorkerEnvironment` variable were all unset at the agent. c739e8c9 added the
missing hop: `init/1` folds `:env_map` into `driver_opts` as `env:` (overlay),
and a non-map raises rather than degrading to no env
(`jido_harness_worker.ex:90-105`).

**Project `config.env` was a second dead export on the workflow door, until E0-S3.**
`prepare_agent_launch/5` passed `env_map:` as the `FOREMAN_*` map only, so
`Overwatch.build_launch_env/2` (which reads `WorkerEnvironment.build_env_map/1`
only when `:env_map` is nil) never ran for workflow runs; only the redaction
list used the project env. Now `prepare_agent_launch/5` computes the project env
once and sends `Map.merge(project_env, foreman_env)` (FOREMAN_* wins on
collision, so project config cannot spoof `FOREMAN_RUN_ID`/`FOREMAN_ARTIFACT_PATH`)
and derives `secrets:` from the same snapshot. Reserved-variable policy belongs
to the E4 environment record. Jobsite `agent.env` is a separate, allowlisted
mechanism and is unchanged.

**There is no `default_branch` project setting.** It was stored on
`Aggregates.Project` and projected (defaulting to a fabricated `"main"`) but
nothing read it; the base branch is the registered checkout's HEAD latched per
run (above). It is removed: `project.register`/`project.update` carrying it fail
with `{:setting_removed, :default_branch}`, and historical `ProjectRegistered`/
`ProjectUpdated` events that still carry the key replay unchanged because the
aggregate and projection handlers read keys with `get/2` and never decode these
events through `EventCodec` (which would reject unknown keys).

**`JidoHarnessWorker.init/1` is the single hop every phase env var depends on.**
When a variable "is exported but has no effect", read that function FIRST. An
export in `foreman_env/3` proves only that Foreman computed the value; it is not
evidence that any agent received it.

**Jido Harness provider/model selection is explicit.**
`ForemanServer.AgentRuntime.JidoHarness` is the source of truth for supported
providers (`@supported_providers == [:pi, :claude]`) and normalizes string
provider keys from workflow context. A LiteLLM proxy is NOT a harness
provider — it is a model dispatcher reached *through* the `:pi` provider (or
`:claude`) by pointing the harness at a proxy-served model name; there is no
`:litellm` atom. `RunExecutor` maps phase `models.default` to
`context.model` / `FOREMAN_MODEL`, and `JidoHarnessAdapter` forwards that model
to the selected provider. Never infer provider from model name.

The corrected consequence: no dispatched run had ever recorded an artifact, and
the cause was this dropped env map — not agents ignoring the contract. The
previous version of this passage instead blamed an inferred agent convention
(`docs/reports/<project>-<task-id>/IMPLEMENT_REPORT.md`) for the missing
artifacts. That was wrong, and because the claim lived here it was re-derived as
established fact and drove repeated misdiagnosis of agent behavior across a
whole session. The decisive evidence is the agent's own probe from inside the
dispatched process: run-d6cdefe69706087e6bce5b1a10b95384's pi transcript runs
`test -n "$FOREMAN_PRD_PATH" && … || echo 'FOREMAN_PRD_PATH unset/empty'` at msg
#45 and gets `unset/empty` back at msg #47.

**A `command:` phase has no in-prompt channel at all.** `prepare_agent_launch/5`
(formerly `dispatch_agent/5`) substitutes the rendered command string for the rendered prompt
(`prepare_agent_launch/5`); `request.prompt` survives only as the fallback for
a command that renders to nil, so for any real command phase it is discarded.
Built-in `prd`/`fix` command phases keep those command prompt bytes unchanged;
Foreman-owned inbox progress guidance rides separately through worker
`system_prompt`.
Anything such a phase must know — the artifact path, and the task subject
itself — therefore travels by env or does not travel. With neither, the agent
reconstructs a subject from repository reconnaissance: three live runs
dispatched with three different descriptions all produced a PRD about the same
unrelated "curated ensemble workflows" topic, because that is what greps of this
repo return. This is why `assert_plan_subject/3` refuses to dispatch any
discovery-gated phase whose env carries no `FOREMAN_TASK_TITLE`.

**Planning documents are DISCOVERED, not mandated.** Foreman does not tell a
plan agent what to name its PRD or TRD and does not gate on a name it computed.
`RunExecutor.enforce_required_file/4` routes `requiredFile: planning.prd_path` /
`planning.trd_path` to `PlanContext.discover_document/3`, which takes the
documents NEW IN THE PHASE as the union of two scans in the phase's working
directory, deduplicated:

1. `git diff --name-only -z --diff-filter=A --find-renames <base_ref> HEAD --
   docs/PRD` — what the agent COMMITTED. `--find-renames` is explicit so an
   operator's `diff.renames=false` cannot turn a committed rename into an
   apparent addition.
2. `git status --porcelain -z --untracked-files=all -- docs/PRD` — what the
   agent left untracked or added in the working tree.

`base_ref` is the commit the phase's checkout stood at when the phase started.
On the run's FIRST phase that is where `Worktree.create/1` pinned the worktree,
carried back on the record by `create_run_worktree/2`; on every later phase it is
the shared checkout's current `HEAD`, refreshed by `reuse_run_worktree/2` (it
used to come from the deleted `create_phase_worktree/4` /
`create_default_worktree/3` pair, one worktree per phase). Either way
`capture_planning_document/4` reads it from run state with no new event.
The invariant that makes this deterministic is one the pipeline
already enforces — the tree is clean when a phase starts, a dirty worktree
HALTs — so it is not a heuristic: no newest-mtime, no name matching. Renames
and edits of documents that already existed at `base_ref` are not candidates;
the gate proves a NEW document exists. Each outcome is its own error (AGENTS.md
5.3): one candidate captures, `:planning_document_absent` means the agent
produced nothing, `:planning_document_ambiguous` names every candidate rather
than picking one, `:planning_document_scan_failed` means git could not read the
directory or the base at all, and `:planning_document_base_unknown` means
Foreman has no base for the phase (a phase configured with
`worktree: enabled: false`) — never a silent fall back to the working-tree scan.

The committed half is not an edge case: it is what the ensemble skills do. The
working-tree-only gate failed run-9ff0f0ffc7e5845265d0cdcf8eb0ac2d with
`{:planning_document_absent, "docs/PRD", …}` 30 seconds after polling had seen
`?? docs/PRD/PRD-2026-96266fc0-durable-run-log-store.md` — the agent had
committed it, so the scan saw a clean tree and reported "produced nothing".

`PlanContext.capture_document/3` writes the captured relative path into the
run's plan context under the same key, so `create-trd` reads the PRD the
`create-prd` agent actually wrote. `RunExecutor` joins it onto the phase cwd in
one place, `resolve_phase_path/3` — do not reintroduce a second computation;
rooting planning paths at the project root at build time was half of an earlier
failure, because the agent's cwd is the worktree. Capturing the PRD also
re-keys `planning.correlation_id` off the captured filename: PRD<->TRD pairing
rides on that id, and the run-derived one belongs to a document that was never
written. A filename carrying no id drops the key rather than keeping a
plausible-looking wrong answer.

Why the mandate was abandoned: `foreman_env/3` used to export
`FOREMAN_PRD_PATH`/`FOREMAN_TRD_PATH` and the gate required that exact file.
It failed in three consecutive live runs
(run-d6cdefe69706087e6bce5b1a10b95384, run-dda353905d237cfd2557a706dd930bdd,
run-3da49f9ed1ae01f932092b31335b5623), each with a different task description
and each producing a PRD about the same unrelated subject. Two independent
causes, and neither was "the agent disobeyed":

1. **The variable was never delivered.** The dropped `:env_map` documented
   above: until c739e8c9 no `FOREMAN_*` export reached any agent, so the gate
   required a path the agent could not read.
2. **The subject was never delivered either.** With no title or description in
   env and none in the prompt (a `command:` phase's prompt is literally the
   command string, see above), the agent reconstructed a topic from repository
   reconnaissance — the same transcript greps the repo for
   `curated|ensemble|workflow dispatch` by msg #8. The filename gate was
   catching that by accident. Discovery would not, so `foreman_env/3` now
   exports `FOREMAN_TASK_TITLE`/`FOREMAN_TASK_DESCRIPTION` and
   `assert_plan_subject/3` refuses to dispatch any discovery-gated phase whose
   env carries no `FOREMAN_TASK_TITLE`, failing `{:plan_subject_missing, …}`
   before a worker starts. Accepting whatever an uninformed agent wrote is the
   plausible-looking success this file exists to forbid.

`FOREMAN_SOURCE_PRD_PATH` carries the captured PRD forward as an INPUT: absent
on the phase that produces it, present for every phase after, so `create-trd`
consumes a named document instead of globbing `docs/PRD`. It is deliberately
not the old name — `FOREMAN_PRD_PATH` meant "write here", it is deleted, and
recycling the name for "read here" would leave two contradictory meanings in
circulation. Its consumers are `create-trd.yaml` and `create-trd-foreman.yaml`,
which STOP when it is set and missing rather than falling back.

**A run has exactly ONE worktree, the whole workflow executes in it, and the
`worktree:` block is declared at the WORKFLOW level.** The block sits at the top
of the manifest beside `name:` and `phases:`, never on a phase — a run has one
worktree, so a phase has nothing to decide about it. `WorktreeSpec.normalize/1`
is the only normalizer; `RunExecutor.extract_worktree_spec/1` reads the block off
the frozen `workflow_snapshot` into `state.worktree_spec`.

Fields, all optional: `enabled` (default true; `false` opts the whole workflow
out), `base`, `branch` (default `foreman/{task_id}/{run_id}`), `path` (leaf directory,
default `workspace`), `cleanup` (default `never`). `{task_id}` and `{run_id}`
are template placeholders. `{phase}` was dropped with the move: it named a
per-phase branch and directory that no longer exist.

`create_run_worktree/2` is the single provisioning path. Absent a `worktree:`
block it provisions one directory
(`~/.foreman/worktrees/<project_id>/<task_id>/<run_id>/workspace`) on one branch
(`foreman/<task-id>/<run-id>`) — both DEFAULTS, overridable by the workflow's `path:` and
`branch:` — and every later phase reuses that record via
`ensure_run_worktree/2` -> `reuse_run_worktree/2`, reading its predecessors'
output as ordinary files. `remember_run_worktree/2` latches the record on key
presence, so the first phase provisions and the rest reuse.

Whether the base is pinned is a property of the RUN, not of the declaration.
`resolve_run_base/2` detects an ImplementationContext by the presence of the
values it freezes: with one, `project_root`/`source_revision` come from plan
context, a declared `base` must resolve to that same revision
(`assert_base_matches/3`, TRD Decisions 3/5), and
`implementation_key`/`trd_scope` ride on the record; without one, the root is the
project's registered path and the base is that checkout's `HEAD`. A
partially-populated plan context is a hard error, never a silent fall back to
`HEAD`.

A reused worktree carries exactly one per-phase value: `base_ref`, refreshed to
the shared checkout's current `HEAD`. That is what keeps the discovery gate
scoped per phase — `capture_planning_document/4` diffs `<base_ref>..HEAD` for
documents NEW IN THE PHASE, and `commit_phase_worktree/4` commits at each phase
boundary, so `HEAD` at phase N's start is exactly what phases 1..N-1 produced.
Phase 1's PRD therefore correctly does not read as new in phase 2. A worktree
that has vanished mid-run is `{:run_worktree_vanished, path}` and an
unresolvable `HEAD` is `{:run_worktree_head_unresolvable, path, reason}` — never
a silent re-provision, which would run the phase against the wrong tree.

This replaced a per-phase design on both axes, and the second axis is the
subtler one. Each phase used to create its own worktree and branch, cut from the
predecessor's branch tip by `phase_lineage_base_ref/2`, destroyed at the phase
boundary by `cleanup_phase_worktree/4`; both functions are **deleted**. And each
phase used to carry its own `worktree:` block, which for a run-scoped resource
meant N declarations could contradict each other while only the first could
possibly be honored.

Worse, the phase-level block selected between two non-interchangeable
provisioning functions — declaring it routed the run through
`create_phase_worktree/4`, which required an ImplementationContext. So
`worktree: {enabled: true}` on `prd.yaml` or `fix.yaml` did not restate the
default; it changed the code path and failed provisioning on the first phase.
An earlier version of this section documented that as a rule to work around
("only `implement-trd*.yaml` may declare the block") instead of a defect to fix.
Documenting a trap is not the same as removing it: there is now one provisioning
path and the block is legal on every workflow. Do not reintroduce
`phase_lineage_base_ref/2`, `cleanup_phase_worktree/4`, `create_phase_worktree/4`,
`create_default_worktree/3`, or a phase-level `worktree:` key.

Three normalizers for this one block existed at once: `PhaseSpec`,
`Catalog.normalize_worktree/1`, and the executor's own reads — and the catalog's
injected defaults DISAGREED with the executor's (`branch:
"foreman/{run_id}/{phase}"`, `cleanup: "always"`). `Catalog` now carries the
block verbatim and injects nothing, precisely so "declared nothing" stays
distinguishable from "declared the default"; that difference is load-bearing for
`enabled`. Normalize once, at the executor boundary (AGENTS.md §5.4).

The `Interpreter` validates the block once at workflow level, so its error
messages no longer carry a phase index. Supporting a top-level `worktree:` also
required teaching `parse_root_entries/3` that a top-level key with no inline
value introduces a nested mapping — only `phases:` had been allowed to nest, so
`worktree:` parsed as the empty string and left its own indented lines
unconsumed. That surfaced as `no case clause matching` with the whole token list
inspected into the message, because `parse_root!/2`'s leftover clause matched
only a SINGLE unparsed line; it now matches with a tail and names the offending
line.

**Worktree cleanup is run-level, declared as `cleanup: always | never |
on_success`, default `never`.** `never` never reclaims here; `always` reclaims on
success and on failure; `on_success` reclaims only on success, so a failed run's
checkout survives for forensics. `cleanup_run_worktree/2` takes the outcome —
`finalize_run/1` passes `:success` after AutoPR (the worktree is the checkout
AutoPR pushes from, so anything earlier deletes the work before it can be
proposed) and `finalize_terminal_and_stop/2` passes `:failure`. `RunDeleted` still
fans out to `Worktree.clean_for_run/1` for runs that end another way.
`worktree_cleanup/1` returns `{:error, {:worktree_cleanup_invalid, other}}` for
any other value rather than defaulting, so a misspelled `cleanup: allways` cannot
read as a working declaration.

`on_success` is the sharpest instance of this file's core failure mode. The
`Interpreter` validated it as legal from the day the block was introduced, and
`ManifestWriter` round-tripped it with test coverage, while `worktree_cleanup/1`
matched `"never"` and sent everything else — `on_success` included — to
`:always`. A manifest asking to KEEP the checkout on failure had it deleted, on
exactly the path where the evidence mattered. Nothing failed, because the schema
and the writer agreed with each other and only the consumer disagreed. When a
validator accepts an enum value, grep for a reader of every variant before
trusting that the value does anything.

An in-flight attempt at the cleanup fix introduced a second key,
`clean_worktree`, and stopped reading `:cleanup` entirely. It silently orphaned
the `cleanup: never` already declared by both `implement-trd*.yaml`, and escaped
notice only because the new default happened to agree with the orphaned
declaration. `clean_worktree` is NOT and never was a manifest key — it is the
`VcsAdapter` operation name for removing a worktree
(`VcsAdapter.Default.clean_worktree/2`). It was also added to
`PhaseSpec.@worktree_fields`, where it normalized a key no module read. Both are
removed.

**Foreman owns the commit.** `commit_phase_worktree/4` stages and commits
whatever the phase produced, so an agent that writes files without committing
still leaves the run a proposable branch. Emptiness is decided by
`git status --porcelain --untracked-files=all`, never by `git commit`'s exit
code: after `git add -A` a clean tree and a genuine failure both exit 1, and git
prints "nothing to commit" to stdout rather than staying silent, so the first
implementation's "exit 1 with empty output means clean" test matched the failure
case and reported real errors as a clean tree. A clean tree is
`{:ok, :nothing_to_commit}` and creates no commit, preserving the invariant that
AutoPR proposes only real work. Every git failure is `{:error, …}`; the first
implementation returned `{:ok, :skipped_no_worktree}` for a failed `git add`, a
missing `project_root`, a non-zero `git commit`, and an unrecognized exit code
alike, so a phase whose work was never committed completed as a success (AGENTS.md
5.2). The commit uses `-c user.name` / `-c user.email` overrides so it cannot
fail on a checkout with no identity configured, and `--no-verify` so a repository
pre-commit hook cannot fail the phase or rewrite the agent's output.

Keep three tiers of proof distinct here, because collapsing them in either
direction is how this section's worst errors were made. **Proven by code:** the
base selection above. **Proven by test against real git, no filesystem or git
mocks:** every phase runs in one checkout, and each phase's discovery gate
scopes to its own document. `run_executor_test.exs` drives the real
`RunExecutor` through a two-phase default-worktree run: phase 1's scripted agent
writes a PRD and does NOT commit it, phase 2's agent calls `File.regular?` on it
from the shared worktree and the test asserts it true, asserts both phases were
handed the same `FOREMAN_WORKTREE_PATH` and the same
`FOREMAN_EXPECTED_BRANCH`, asserts phase 2's `FOREMAN_SOURCE_REVISION` advanced
to the commit Foreman made on phase 1's behalf while refuting it is the run
base, and asserts the worktree survives run completion with the run branch
carrying the PRD.
`run_executor_run_worktree_test.exs` pins the subtlest part, which is exactly
where a silent regression would hide: against the refreshed base,
`discover_document(wt, "docs/TRD", phase2.base_ref)` returns the TRD while
`discover_document(wt, "docs/PRD", phase2.base_ref)` returns
`{:planning_document_absent, …}` — the inherited PRD correctly does NOT read as
new in phase 2 — yet against the RUN's base the same PRD call returns
`{:ok, prd}`. That contrast is the proof that `base_ref` must advance with the
shared checkout or the gate mis-reports. The same file pins the commit path
against real git: a checkout with `user.email`/`user.name` unset still commits,
an untracked-only file counts as work, a clean tree creates no commit, and a
directory git cannot read is an `{:error, …}` rather than a skip.
**Not proven:** a live end-to-end plan run. No dispatch has executed since the
fix.

Do not collapse those tiers. Reading "proven by code" as "works in production"
is the `FOREMAN_ARTIFACT_PATH` error one paragraph above — computation proven,
delivery assumed. Reading "proven by test against real git" as "unproven" is the
same loss of information in the opposite direction. The STOP-on-missing rule
above is what keeps a failure here loud, naming the absent path instead of
producing a silently mis-sourced TRD.

`cleanup_phase_worktree/4` is **deleted** — worktree reclamation is now
run-level (`cleanup_run_worktree/2` from `finalize_run/1`). The paragraphs
below described its behavior and are kept because the reasoning error they
record is the transferable part.

An earlier version claimed `cleanup_phase_worktree/4` "force-deletes its
branch". **That was wrong when it was written, not merely stale.** It reclaimed
disk only, via `Worktree.clean/1` -> `VcsAdapter.Default.clean_worktree/2`,
whose entire git surface is `git worktree remove` (`default.ex:193`) followed by
`git worktree prune` (`:199`) — no ref is written or deleted anywhere in it.
`delete_branch/1` is private to `worktree.ex` (`:269`, `:281`) and its
only caller is `Worktree.clean_for_run/1` (`:228`), which `Dispatcher` invokes
solely on `RunDeleted` (`dispatcher.ex:163`) — after the run is already
terminated. That is still true of `clean_worktree/2` today, and it is why
run-level cleanup reclaims the directory without touching the run branch AutoPR
has already pushed.

Empirically, too: phase 1's branch from the failed
run-d75304aca144c15409087ed744e2a7dc is still at `b9c93aa7` and still carries
`docs/PRD/PRD-2026-6a25501b-durable-run-log-store.md` long after that run's
cleanup ran.

How that error was made is worth more than the correction: the claim came from
the function's NAME and its presence in the cleanup path, never from its call
graph. It then travelled into a design question posed to the user as though it
were established. Before asserting that a function does something destructive,
read its callers — same class as concluding from a stale binary's surface
instead of the source (see Documentation Discipline).

When changing that contract, change both sides. A Foreman-side export with no
consumer is dead plumbing — an earlier attempt at exactly this was reverted for
that reason. Note also that only a command YAML's `mission.summary` is emitted
by *every* ensemble generator: `constraints` and `parameters[].description` are
dropped by the codex generator, so a rule authored only there is invisible to a
codex-backed agent.

Prompt rendering itself is NOT the problem, despite what
`docs/reports/foreman-foreman-dispatch-fix-verify-rdrq/IMPLEMENT_REPORT.md`
claims. `prompt_renderer_test.exs` renders the bundled `implement.md` with
`artifact_path` in the assigns and passes. That report's agent was on a
`command:` phase, so it never received a Foreman prompt at all; it read the
checked-in template at `priv/defaults/workflows/prompts/implement.md`, which
legitimately contains an unrendered `{{artifact_path}}` because it is the
source template. Do not re-chase it as a rendering defect.

**The merge gate is reachable by an operator only — never add an agent path (2026-10).**
`run.pr.ready` had a complete aggregate handler and no producer, and `merge_approve` /
`run.pr.merge` were in neither operator allowlist, so no run could ever merge. Now:
`RunExecutor.signal_pr_ready/2` dispatches `run.pr.ready` after AutoPR creates the final PR
(a run whose PRs are all `stack_pr` phase PRs reaches `maybe_auto_pr` as `:noop`, so its
gate never engages); `merge_approve` and `run.pr.merge` are operator commands on
`POST /api/commands` and `foreman run approve-merge|merge`. The real GitHub merge runs in
`ForemanServer.RunPrMerge`, called from `CommandGateway.dispatch_operator/2` BEFORE the
command is dispatched and never inside the aggregate — the actor re-runs `handle_command/2`
on a version conflict, which would repeat a real merge. `RunPrMerge` reads the gate from the
event-sourced aggregate (not the ETS `MergeGate`), pins `gh pr merge --squash
--match-head-commit` to the head SHA the operator approved (`MergeGateApproved.head_sha`, held in the
aggregate's `merge_pins`; the head stored in `PrReady` is only the fallback when no pin is recorded),
skips `gh` for a PR that is already merged at that same head (merged at any other head is
`head_moved_since_approval`), and REPLACES the caller's payload wholesale. `approver_identity` is a
client-supplied string checked against `ApproverAuthorizer`'s hardcoded
`["github:ldangelo"]`; the API bearer token is the real trust boundary. So do NOT add an MCP
tool for either command: an agent with write MCP could approve and merge its own PR
(`MergeToolRefuser` exists for the same reason).

**An approval names the head it is for, and a push voids it (foreman-ehxy6).** `merge_approve`
requires `head_sha`. `CommandGateway` reads the live PR head (`GitHub.PrStatus.fetch`, i.e.
`gh pr view`) before dispatching, never inside the aggregate, and refuses a different head
(`{:head_sha_mismatch, supplied, live}`) or none (`{:missing_or_invalid, :head_sha}`). GitHub is
the authority, not the recorded `pr_watch` head: that lags a push, and polling is opt-in. The
approval pins exactly that commit. Before this, the pin was inferred from the event stream (the
head the PR watch had last recorded), so an approval could pin a head the operator never saw,
and a push after approval stranded the PR: `merge_approve` was refused
(`merge_gate_already_approved`) while `run.pr.merge` was refused (`head_moved_since_approval`).
Now a head that differs from the pin of an approved gate returns the gate to `:pending` with
the pin cleared: `run.pr.rehold` (system-only; emits `MergeGatePending` with `reason`,
`approved_head_sha`, `head_sha`). It is dispatched from two places: `CommandGateway.dispatch_system/2`
after every `run.pr.update|checks|review` observation, including a deduplicated one (a head that
returns to an earlier recorded head appends no `PrUpdated`, yet it must still be compared), and
the `run.pr.merge` side effect when `RunPrMerge` answers `head_moved_since_approval` (a push
nothing observed, e.g. polling off). The moved head is never adopted as the pin: re-pinning
would carry an approval over to code the operator never reviewed. A fresh operator
`merge_approve` naming the new head is required, and the old approval is not honoured again,
even if the head later returns to it. The decision is made in the aggregate from its own state,
so it is idempotent; the command id carries the approval's `approved_at` so each approval cycle
can be voided exactly once (a head-derived id would repeat across cycles and the router would
hand back the first cycle's event). An approval recorded before heads were pinned (no
`head_sha` on its event) is pinned at fold time to the head the PR watch had recorded then.

`PrMonitor` (opt-in, `FOREMAN_PR_MONITOR_ENABLED=true`) and `POST /webhooks/github` both
build `run.pr.update` through the one `ForemanServer.PrUpdate` builder, so the same
observation dedupes by `command_id`. Both only append `PrUpdated`; `ProjectionStore` folds
neither `PrUpdated` nor `PrMerged`, so neither changes task or run read-model state. The
webhook fails closed on `X-Hub-Signature-256` (`503` with no `FOREMAN_GITHUB_WEBHOOK_SECRET`,
`401` for a missing/malformed/wrong signature) and attributes events by PR URL, never by a
payload field. `/webhooks/external_trigger` and `/webhooks/operator/ingest` still have no
authentication.

**The workflow door persists the provider session id (2026-10).** `WorkerStarted.session_id`
is a Foreman-generated handle (`"session-" <> uuid`, `jobsite/runners/overwatch.ex` `generate_session_id/0`),
NOT the provider's. The real id is `Jido.Harness.RunResult.provider_session_id`, and it used
to die inside `JidoHarnessWorker.normalize_result/1`, which keeps only the text. The worker
now builds a `ForemanServer.Overwatch.RunMeta` from the `RunResult` BEFORE normalising (so a
failed run still yields its id — it is the one a fix thread resumes) and sends it as the 4th
element of `{:agent_done, result, log_events, meta}`. It then emits `WorkerSessionBound`
(typed event, decoded by `Aggregates.Worker`) strictly BEFORE `WorkerExited`, and only when
the id is a non-empty binary. `ProjectionStore` folds it onto the run as `provider_session_id`
(latest) and `provider_sessions` (ordered, idempotent per `{worker, provider, model, id}`),
and `Review.Capture.close_run/2` copies the de-duplicated ids into the archive manifest.
Historical runs project `nil` / `[]`. The worker result message shape
`{:worker_result, {:ok, text} | {:error, code}}` is unchanged.
