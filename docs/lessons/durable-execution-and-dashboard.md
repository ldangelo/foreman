# Task providers, run dashboard, durable execution (§13)

> Moved verbatim from `CLAUDE.md`. Section numbers are unchanged; `CLAUDE.md` names the file holding each `§N`, so a reference to a section that is not in this file resolves there.

## 13. Task-provider boundary reminder (Go/Elixir CQRS slice)

RunExecutor drives claim/complete/fail, each as a keyed `task_provider`
effect (§13.2). Workflow.BootReconciliation
drives orphan-reopen. `set_priority` and `add_dependency` stay at the
adapter boundary until a separate operator surface TRD introduces them.

## 13.1 Operator run dashboard boundary

The run-management dashboard is `GET /dashboard/runs`, guarded by the
existing browser `:require_authenticated` token plug. Keep `/dashboard`
as the separate Jido live dashboard. The run dashboard reads only
`ProjectionStore` projections (runs, phases, tasks, logs, worktrees,
PR associations) through `ForemanServerWeb.OperatorDashboard`; durable
logs come from `ProjectionStore.run_logs/1`, not server `Logger` output.
Run-control buttons dispatch public operator envelopes through
`CommandGateway.dispatch_operator/1`; Stop is `run.pause` with default
reason `operator_pause`, Abandon is `run.remove`, Resume is
`run.resume`, and Reset/Restart is `run.reset`. Code evidence stays
read-only and may use projected worktree/branch/base data only.

The project workspace is `GET /dashboard/projects/:id` (+ `/threads/:thread_id`, `/settings`,
`ForemanServerWeb.ProjectWorkspaceLive` / `ProjectSettingsLive`), same guard;
`foreman project open <id>` opens it in a browser (the token rides in the URL and every link and
patch of the page keeps it, the settings page's way back too). Layout: a leftmost
workspace-nav sidebar (`Components.workspace_nav/1`, six read-only panels over data the server
already exposes, no new server command or event; the Jobsite (legacy history) and Workflows panels are read from existing
projections on mount and refresh: a client-side Search filter over thread titles, memory
topics and library files; a Projects list of every project (`ProjectStore.list/0`) linking to
each workspace; a Jobsite list of the OPEN project's LEGACY jobsite history (read-only; new work, PR fixes included, is a run and appears in Workflows) and a Workflows list of the
open project's workflow runs, both built by `Workspace.NavRuns.read/1` in five bulk projection
reads per refresh (`ProjectionStore.list_jobsites/0`, `list_tasks/0`, `worktrees_for_runs/1`,
`pr_states_for_project/1`, and `OperatorDashboard.list_runs/1` filtered by `project_id` with
`detail: :summary`, which skips the per-run phase reads), each capped at 100 rows (Jobsite
newest-started-first, Workflows most-recently-active first; the Jobsite badge counts the
project's real total, the Workflows badge reads `100+` when
that read came back at its limit; a Workflows row is titled by its task (`Thread.title/2`: the
run id when it has no task) and links to that run's dashboard (`/dashboard/runs?run_id=…`, the
page's token carried); muted beneath it are the workflow (`RunDTO.workflow`: the run
projection's `workflow_name` or, when that is nil as it is on every dispatched run, its frozen
`workflow_snapshot.workflow_name`), the status and the age. Its `Details` disclosure (closed on
load, each row opening and closing on its own via `nav_run_toggle`, server-held in `nav_open` so a refresh never
collapses it) shows the branch and base, the worktree path as text with the state the projection
recorded for it (`kept`/`active`/`removed`; the nav never touches the disk or git), the PR link
(`http(s)` only, new tab, never the token), the task's TRD path as text, a `Documents` area filled
only when the row is opened (the PRD/TRD files the run's branch changed, found by one bounded
`OperatorDashboard.planning_documents_bounded/3` per open, never on refresh, each a link to that
file's diff on the run dashboard, `?tab=changes&file=…`; the task's TRD path is linked when it is
among them; an unreadable branch says why instead), and a `Conversation`
link (`patch`, token carried) to the run's thread (a run that is not its task's newest, and a jobsite whose bead's task has a run, open that task's thread: `Threads.resolve/1`); a Jobsite row is titled by the task of its own project that owns
its bead (the bead or jobsite id when none does) with the same Details (branch, worktree path,
Conversation link)); an Artifacts list of the project's
library files, the closest the server exposes; and a Schedules list (`Schedule.DTO.list/1`) with
cadence and next run); then a
sidebar of threads ("Project chat", then Waiting on you / Working / Landing / Ready for review,
Idle and Resolved folded under "Earlier"); the main column is the coordinator chat, or, at
`/threads/:thread_id` (id percent-encoded, e.g. `run%3A<run_id>`), that one thread's conversation
(`Threads.Transcript.full/2` with `chunks: true` and `log_limit: ProjectionStore.run_logs_max_limit()`, one turn per stored output chunk and everything the store keeps of the run's output, with a note when it dropped some; `Workspace.ThreadView` assembles them, so a streamed message and the final chunk that repeats it show once) with the thread's controls (Pause/Resume/Stop/Resolve/Reopen,
PR fix/create buttons, tool-call Approve/Deny, steer box); the right column keeps the questions
pane, knowledge panels and the Library/Pull requests/Scheduled tabs.
It adds no mutation path: actions go through `ForemanServerWeb.Workspace.Actions`
(Threads.Actions, CoordinatorAPI, Library add files/folder, replace, remove and read/download,
ProjectSecrets, operator-allowlisted commands) and updates
come from one coalesced `ProjectionStore` subscription (`Workspace.Refresh`; Worker* output of
the open thread arms a second coalesced `:thread_refresh`, `Transcript.relevant?/2`),
never a polling timer. It has no merge/approve-PR control. Socket uploads hold the HTTP
route's whole-add cap `upload_max_bytes` themselves (`Workspace.LibraryUpload`), and a
secret's value is write-only there: handed to `ProjectSecrets.set/4`, never assigned,
rendered, logged or put in an event.

Workspace and settings accessibility baseline (E16): `<main id="main">` plus a
skip link, labelled controls, visible `:focus-visible` rings, `aria-live`
status regions (`#notice`, the instructions counter) and `role="alert"` field
errors. Secrets are never rendered, only reference names. The baseline is
enforced by `scripts/e2e/ui-a11y/ui_a11y.mjs` (axe-core: zero serious/critical;
keyboard focus order; zero idle LiveView frames), a LOCAL acceptance command, not
a CI job; see `docs/spikes/E16-SP1.md`. A new workspace/settings control must
keep that script green.

## 13.2 Durable execution: recovery, effect keys, preflight (Phase 0)

Source of truth: `docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md`.

- **Keyed effects.** `Idempotency.Effect.run/4` records an intent key
  `effect:<class>:<run_id>:<identity>` (`started`) before the external effect and
  `completed`/`failed` after it; if the intent cannot be written the effect does
  not run. `Effect.run/4` does not check durability: keys are durable only when
  `KeyStore.durable?/0` is true (`config :foreman_server, :jido_ecto, enabled: true`,
  read by `maybe_jido_checkpoint_repo_child/0`, plus `JIDO_CHECKPOINT_DATABASE_URL`
  for the Repo url; the `FOREMAN_JIDO_ECTO_ENABLED` env var named in older docs and
  a `prod.exs` comment is not wired). On the ETS fallback the effect still runs and
  its key does not survive a restart; boot and `foreman doctor` report it. Classes: `branch_push`, `pr_create` (AutoPR,
  PhasePR), `task_provider` (`Idempotency.Reconcilers.TaskProvider`; ops `claim`,
  `complete`, `fail`, `reopen`; key `effect:task_provider:<run_id>:<op>:<issue_id>`) and
  `pr_comment` (the PR report comment, Phase 1 PR 7; key `effect:pr_comment:<run_id>:<head>:<digest>`;
  repeatable and never blocks a run, see "Phase 1 PR 7" below).
  A crash mid-effect leaves the key `started`; a scan marks it `ambiguous` when its
  writer is dead: `Effect.run` stamps a `started` key with `writer_incarnation` and
  `writer_pid`, and the sweep orphans a stamped key only when `Effect.writer_state/1`
  is `:dead` (another incarnation, or no such live local process), whatever executor
  its run has now, and never while it is `:alive`; a key with no stamp keeps the rule
  "its run has no live executor".
- **Reconcilers.** `config :foreman_server, ForemanServer.Idempotency.Reconciler,
  classes:` maps an `effect_class` to the module that asks the outside world
  whether the effect happened (`:done | :not_done | :unknown`). A class with no
  entry fails closed. A new effect class needs its entry there.
- **Boot sweep.** `BootReconciliation.do_reconcile_ambiguous_keys/2` partitions
  ambiguous keys: agent-phase keys go to `CrashRecovery.reconcile/2`; `effect:`
  keys (`KeyStore.effect_key?/1`) go to the class reconciler and NEVER to
  `CrashRecovery` (whose side-effects-present branch marks the key completed and
  retries, the opposite of what a push needs). Verdict `:not_done` records
  `RunRecoveryAttempted{outcome: "effect_retried"}` and the key stays ambiguous with
  `decision: "not_done"` written FIRST, so the next `Effect.run` consumes it
  (`KeyStore.consume_decision/3`) and re-marks the key; an `Effect.run` or
  `Effect.preflight` that meets a `started` or `ambiguous` key with no decision is
  refused `{:error, {:effect_undecided, key}}`; that refusal asks the sweep to scan again
  (an on-demand scan, `reconcile_ambiguous_keys/2` with origin `:on_demand`; the deferred
  boot sweep has origin `:boot`). `:done`, `:unknown` and an unregistered class
  record `effect_blocked` and then dispatch `run.block` with reason
  `effect_already_done`, `effect_outcome_ambiguous` or `effect_class_unregistered`,
  cancelling the live executor and agent. A terminal or absent run cannot be
  blocked: the verdict is logged and counted (`[:foreman_server, :workflow,
  :boot_reconciliation, :effect_on_terminal_run]`) and the key stays ambiguous. An
  `:unknown` verdict blocks only in the boot sweep: in an on-demand scan the key stays
  undecided (still refused), is not marked unresolved, the run is not blocked and the
  count is `deferred_unknown`; the next scan asks again. The
  sweep reports `[…, :effect_reconciled]` (`blocked`, `retried`, `on_terminal_run`,
  `unresolved`, `skipped`, `deferred_unknown`; `audit_failed` when the `effect_retried`
  audit write failed). All four key writers are compare-and-set (Phase 1 PR 4):
  `KeyStore.mark_completed/2`, `mark_failed/3`, `mark_ambiguous/2` and `mark_unresolved/3`
  write only a `started` or `ambiguous` key (the first three also an absent one;
  `mark_unresolved` does not). A key that already settled (`completed`, `failed`) answers
  `:status_changed` and is left as it is (counted `skipped` when the marker was being
  written); a status the store never writes answers `{:error, {:unexpected_status, status}}`,
  never a settle. Overwatch logs a `:status_changed` and keeps the settled outcome,
  `CrashRecovery` decides again from the key's current state on it and
  `Reconcilers.PrCreate` leaves the key alone. A key holding an unexpected status BLOCKS its
  run in the boot sweep (no unresolved marker, a warning logged, the reason of the verdict);
  `Effect.preflight/3` and `Effect.run/4` refuse it
  `{:error, {:effect_check_failed, {:unexpected_status, status}}}` and leave the key as it
  is. `mark_ambiguous` stores its reason under the string key `"reason"`.
  A key the sweep could not decide is marked
  unresolved (`unresolved_at_run_version`, `unresolved_reason`) and
  `Effect.preflight/3` refuses it (`{:effect_unresolved, key}`,
  `{:effect_check_failed, _}`, `{:effect_marker_malformed, key}`) until `run.reset`
  lifts it (`KeyStore.lift_unresolved/3`). A key with no decision yet (`started`, or
  `ambiguous` without `decision`) is refused `{:effect_undecided, key}` (Phase 1 PR 2).
  No sweep verdict marks an ambiguous effect key
  completed; only the PR adoption path does (`PrCreate.settle_adopted/3`, when GitHub
  holds an open PR at the local tip). `foreman_doctor` / `GET /api/doctor` list `started` and ambiguous keys in the
  `effect_keys` check (store durability line, a `Phase 1 gating` line, then class, run id,
  status, `key_status`, `decision` and `writer` (`alive|dead|none`, `Effect.writer_state/1`)
  per key); `foreman doctor` prints its id, title and detail. `GET /api/doctor` also has a
  `pr_observation` check: `ok` titled `PR observation: watcher on, monitor on|off, webhook
  secret set|not set`, `warn` titled `PR watcher is off: fix pushes and PR events are not
  observed` when `PrWatcher.enabled?/0` is false; its detail names
  `FOREMAN_PR_WATCHER_ENABLED`, `FOREMAN_PR_MONITOR_ENABLED`, whether
  `FOREMAN_GITHUB_WEBHOOK_SECRET` is set (never its value) and says the merge gate does not
  depend on them (approval re-reads GitHub). Since Phase 1 PR 4 the detail also lists every
  non-archived project with `required_checks` set (`gated project <name>: ...`, with a line
  when the idempotency store is not durable and one about the 100-check read limit), and the
  title changes for a gated project: `warn` `Gated project(s) <names>: neither the monitor nor
  the webhook is on, so a head or check change is not observed` when both are off (this wins
  over the watcher states), and `warn` `Gated projects could not be read: <reason>` when the
  project projection does not answer (this wins over everything, so an unreadable projection
  never reads as "no gated project"). The `effect_keys` check is
  `ok` whatever the key count, so listed keys never affect `--strict`; it is `warn`
  only when the store does not answer ("Unresolved effect keys could not be read"),
  and `doctorExit` fails any warn under `--strict`. Phase 0 has no verb that clears a key for a completed, cancelled
  or deleted run.
- **Restart budget.** A restarted run does not reset its recovery budget:
  `RunExecutor` records `phase.retry` with reason `resumed` (`PhaseRetried`; the
  phase stays `in_progress`, `attempt` advances, `input_artifacts` and
  `prior_worktree_discarded` ride on it) and `run.recovery_attempt` (`outcome:
  "resumed"`, `elapsed_since_boot_ms`; non-terminal runs only). The boot cleanup
  budget of an orphaned slot holder or waiter is durable on the entry's own `run_slots:<project_id>`
  stream (`run_slots.recovery_attempt` → `RunSlotRecoveryAttempted`); the sixth
  consecutive failure records the entry `exhausted` and later boots skip it. It
  shows as `orphan_recovery` in `ProjectionStore.queue_status/1` and `GET /api/queue?project_id=<id>`
  (`foreman_queue_status`). The old ETS table `:boot_recon_dispatch_attempts` is
  gone. An exhausted entry clears only when its holder or waiter leaves the stream.
  A worktree that no longer exists at resume is recorded as
  `prior_worktree_discarded` (`Workflow.WorktreeDiscard`); a failing
  `git worktree prune` there fails the run `{:resume_worktree_prune_failed, …}`.
- **Kickoff preflight order** (`RunExecutor.kickoff_preflight/1`, fresh and resumed
  runs): network isolation (`NetworkPolicy.check_backend/2`; refuses
  `{:isolation_unsupported, :network, :host_workflow}` because the host cannot
  enforce a non-default `environment.network`) → provider/model
  (`:provider_model_preflight_failed`) → skill (`SkillResolver.resolve/4`, a
  `command:` phase naming a skill pi cannot find fails
  `{:capability_preflight_failed, [%PreflightFailure{class: :skill_not_found}]}`)
  → task claim. A skill is `:missing` only when absence is proven everywhere pi
  looks and no extension could add one; anything unresolvable is `:unverifiable`
  (the run proceeds with a warning), so on a typical dev host the refusal rarely
  fires. `config :foreman_server, :skill_home` overrides the home read.
- **Execution profile.** `Exec.ExecutionProfile` names what a backend enforces
  (`filesystem`, `network`, `credentials`, `cleanup`, each `enforced` or
  `unenforced` with a reason; `skill` records the skill verdict). It is recorded on
  `PhaseStarted` and the phase entry as `execution_profile`; the host door is
  never `enforced` for filesystem or network (`VfsIsolation.allowed?/2` has no
  caller; the enforced boundary is the docker sandbox mount).
- **Cancellation.** `Jido.Harness.Run.cancel/1` finalizes a run once it has sent
  SIGINT to the agent; the harness escalates SIGTERM then SIGKILL itself, so a
  cancelled run can read as over while the agent is still exiting. Tool processes
  outlive the agent. `Workflow.OrphanReaper.reap/1` finds those left under a
  worktree (cwd inside it, parent pid 1) and sends SIGTERM, then SIGKILL; it is
  called by `RunExecutor`.
- **Test hermeticity.** `test/test_helper.exs` stubs the pi `cli_path` and points
  `:skill_home` at a private skill home, so a developer's real `~/.pi` or `pi` on
  `PATH` must not decide a test; a test that needs a skill absent overrides
  `:skill_home` itself.

## 13.3 Kata task provider (`ForemanServer.TaskProviders.KataAdapter`)

- **Binding is provider-conditional, keyed on the capability `storage_scheme`.**
  `:sqlite` (Beads) binds by `task_provider.config.database_path`; `:cli_process`
  (Kata, provider id `kata`, contract `kata.capabilities.v1`) binds by an absolute
  `config.cwd`. `ForemanServer.TaskProvider.StorageBinding` is the one place that
  maps scheme to key; the Registry, the projector preflight and `RunExecutor` read it through there.
  `project.update` keeps a stored `config` when the provider is unchanged and no
  `config` is sent; a provider switch without the new scheme's key returns
  `{:missing_or_invalid, :cwd | :database_path}`.
- **CLI.** `foreman project create --task-provider kata --path <absolute dir>`
  sends `config.cwd = --path` (payload: `provider: "kata"` and `config.cwd` only: no `KATA_HOME`,
  `kata_home` or `database_path`); `--task-provider-database-path` is rejected for Kata.
  `project update --task-provider kata` reads the project's registered path
  and sends it as `config.cwd`.
- **Kata is authoritative for claims.** Foreman never scans Kata for orphans
  (no watcher or janitor starts for Kata projects); an operator frees a stranded claim with
  `kata unassign <ref>`. `fail/3` reopens, comments and releases only Foreman's
  own claim (writes nothing if another actor owns the task). `complete/3` needs
  typed evidence (commit SHA / `evidence`, else the run's artifact file as
  `reviewed-paths:`) or fails with `VALIDATION_FAILED`; the close message is
  at least 40 characters. Every `kata` call holds a `ConcurrencyLimiter` slot
  (max 4 per project directory, 30 s queue timeout, `BR_TIMEOUT_QUEUE`).
- **Doctor** (`accepted_kata_versions`, `Version.match?/2` requirements under
  `:task_provider`): report keys `kata_version`, `warnings`, `sample_list`; warning codes
  `KATA_VERSION_OUT_OF_RANGE`, `KATA_VERSION_UNPARSEABLE`,
  `KATA_VERSION_REQUIREMENT_INVALID` never make the project unhealthy;
  `CWD_MISSING` and `PROVIDER_MISSING` do. The adapter itself has no version gate.
  Telemetry: `[:foreman_server, :task_provider, :kata, :subprocess, :spawned]`,
  `[:foreman_server, :task_provider, :registry, :invalid_capabilities]` and
  `[:foreman_server, :task_provider, :claim, :lost]` (a claim the provider refused
  twice, which fails the run before any agent is dispatched; every provider).
