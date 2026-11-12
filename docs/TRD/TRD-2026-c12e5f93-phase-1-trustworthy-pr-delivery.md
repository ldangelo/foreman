---
document_id: TRD-2026-c12e5f93
label: trd-phase-1-trustworthy-pr-delivery
version: 1.0.0
status: Draft
date: 2026-11-12
source_prd: PRD-2026-c12e5f93
prd_reference: docs/PRD/PRD-2026-c12e5f93-phase-1-trustworthy-pr-delivery.md
prd_version_locked: 1.1.0
kind: trd
design_readiness_score: 4.0
---

# TRD: Phase 1 — Trustworthy PR Delivery

## TRD Health Summary

| Metric | Value |
|---|---|
| Source PRD | docs/PRD/PRD-2026-c12e5f93-phase-1-trustworthy-pr-delivery.md (PRD-2026-c12e5f93 v1.1.0: 5 requirements, 18 acceptance criteria) |
| Implementation tasks | 27 |
| Test tasks | 27 |
| Total estimate | 266h (27 implementation tasks and 27 test tasks; no task over 8h) |
| PR boundaries | 9 |
| Open technical decisions | 8 (see §11) |
| Design Readiness Score | 4.0 (PASS with concerns, §15) |

## 1. Context

Phase 1 of the SunStone software factory (umbrella `PRD-2026-b7c2e941`) makes a PR's quality evidence machine-verifiable and bound to the exact head SHA, publishes a risk record, and keeps every merge operator-approved. The operator accepted the Phase 0 engine decision on 2026-11-12 (extend the current event-sourced engine; no Temporal, Conductor or Pi Durable) with four preconditions on Phase 1 code (PRD §5): P-1 `foreman-by6nl`, P-2 `foreman-tnlqt`, P-3 the durable idempotency store, P-4 every Phase 1 effect keyed by head SHA. This TRD plans those preconditions first (PR 2), then the evidence core, the required-checks policy, structured findings, the risk record, the publish effect, the gate and the visibility, and last the adversarial suite.

Every design claim in §5 carries a `path:line` read on disk in the worktree at `0699076a` on 2026-11-12. The scout reports that preceded this TRD were treated as leads: several of their claims were re-read and some corrected (see §14). Where the repository has no evidence, the TRD says so and puts the choice to the operator (§11). Nothing in this TRD was run against a GitHub PR for writing: the `gh` read probes in §5 are the only network checks, and the comment-write calls of TRD-019 are `[UNVERIFIED]` until that task probes them against a scratch PR.

## 2. Scope and Non-Goals

In scope: the four preconditions (REQ-001 by way of PRD §5), per-head check evidence from GitHub and its invalidation (REQ-001, REQ-005), the `required_checks` setting, the typed evaluator and the operator waiver (REQ-001), structured review findings (REQ-002), the versioned risk record (REQ-003), the keyed, redacted PR comment (REQ-003), the approval gate and the visibility of evidence, reasons and next actions (REQ-001, REQ-004, REQ-005), the two folded follow-up beads `foreman-rsbx1` and `foreman-87h5g`, and the adversarial suite and exit record (REQ-004, all).

Non-goals: auto-merge (Phase 2); idea-to-spec (Phase 3); server-run command checks (deferred, §6); a new workflow-manifest key (`PhaseSpec.@fields` is closed); any change to `Review.Verdict` and `Review.Analyzer` (a bead-bound concept, kept separate); an authenticated approver login (the approver identity stays a claim checked against `ApproverAuthorizer`'s list, as for `merge_approve`); trusting a webhook payload as evidence (a webhook only asks for a re-read).

## 3. Reused Capabilities

The foundational-capability registry (`trd-graph-cli capabilities docs/TRD`) is not consulted for reuse; reuse is of Foreman modules, called out per task: `GitHub.PrStatus`, `PrObservation`, `PrWatcher` and its `Observer`, `PrWatchFold`, `Aggregates.Run` with `Aggregates.Run.PrWatch`, `PrGate`, `RunPrMerge`, `CommandGateway`, `Idempotency.Effect`, `KeyStore`, `Reconciler` and `Reconcilers.PrCreate`, `BootReconciliation`, `Coordinator.Redact`, `Aggregates.Project.Settings` and the `pr_auto_fix` precedent, `PrWatch.DTO`, and the Phase 0 pattern of a typed event validated strictly in its aggregate (`PhaseContextRecorded`).

## 4. Binding Design Constraints

From `AGENTS.md` and `docs/standards/constitution.md`; they apply to every task.

- Only `CommandRouter` appends to the EventStore; aggregate handlers return event specs. Every domain event is a module in `lib/foreman_server/events/` with `@enforce_keys` and `@type t`; adding the module is its registration; new fields on an existing event are optional so old streams decode, and a stream written with a new field cannot be decoded by an older build (rollback, §13).
- Aggregate handlers stay deterministic and network-free: the actor re-runs `handle_command/2` on a version conflict (`run_pr_merge.ex:7-12`). Every GitHub read happens in `CommandGateway` or an observer before dispatch.
- Typed boundaries (AGENTS.md §5): result payloads are structs with `@enforce_keys`; no catch-all that turns an unknown value into success; absent is not malformed; one key convention per boundary, normalised once; never insert `nil` for an absent key.
- The merge gate and everything that loosens it are operator-only: `merge_approve`, `run.pr.merge` and the new waiver are never MCP tools or agent paths (`mcp/no_merge_tool_test.exs` forbids the words merge and approve in tool names and descriptions; `operator_only_pr_commands_test.exs` pins the command lists).
- The workflow vocabulary is closed; the PR base is the branch the run was cut from, with no default.
- Documentation Gate: a task that adds, removes or renames an externally visible identifier is listed in TRD-027's list, which updates `CLAUDE.md`, `README.md`, `docs/user-guide.md` and `docs/cli-reference.md`.
- Tests: a failing test is a failed build. Run one file with `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test <path>'`; recovery and effect tests are `async: false`.

## 5. Evidence Baseline (what the source actually does)

Each row is a fact the design depends on. Paths are relative to `packages/foreman_server/` unless they start with `docs/`, `config/`, `.beads/` or `packages/`. Every row rests on a read of the file in the worktree on 2026-11-12 at `0699076a`, or on a command run that day (stated). An implementer should re-validate a row before building on it, since line numbers drift.

| Fact | Source |
|---|---|
| `PrStatus` reads a PR with one `gh pr view --json` call and names the head by `headRefOid`. | `lib/foreman_server/github/pr_status.ex:131,275,321` |
| A normalised check has name, kind, state, conclusion and url; `@fail_conclusions` includes `STALE`; `checks_state` is a rollup; lists are bounded (`@max_list 100`) and comment bodies are cut at 2000 characters. | `github/pr_status.ex:64-71,133-134,143,388-418,438-448,535,539-541` |
| Probe (gh 2.103.3, 2026-11-12, read only): a check-run rollup item carries `__typename, completedAt, conclusion, detailsUrl, name, startedAt, status, workflowName`; a status context carries `__typename, context, startedAt, state, targetUrl` (no `completedAt`, creator or app). | command run: `gh pr view <n> --json statusCheckRollup` on PR #861 of this repository, rails/rails #59767, nodejs/node #67415 |
| Probe: `gh pr view --json files` lists 100 of 223 changed files for DefinitelyTyped/DefinitelyTyped #75892 while `changedFiles` says 223; items are `{additions, changeType, deletions, path}`. | command run, 2026-11-12 |
| Probe: `gh pr view --json comments` returns `id, url, body, author, viewerDidAuthor` per comment and pages through all 908 comments of kubernetes/kubernetes #18085 (26 s); `gh pr comment --help` documents `--body-file -`. No comment write was run. | command run, 2026-11-12 |
| The checks digest hashes only the failing checks (so a changed passing set does not move it); a first sighting with nothing to report emits nothing. | `pr_observation.ex:43-51,194-197` |
| `PrObservation` is pure (its one outside read is `ProjectionStore.run/1`); `commands/5` builds the update, checks and review commands; `comment_ids/1` skips bot-authored comments. | `pr_observation.ex:1-5,75-79,96-106,134-160` |
| `PrChecksChanged` carries the rollup state, the failing names and a digest, and no list of checks. | `events/pr_checks_changed.ex:13-46` |
| All four head-carrying PR events put `head_sha`; none clears the half of the evidence it does not carry. The projection record has `failing` and `comment_ids`; the aggregate record does not. | `pr_watch_fold.ex:111-150`; `aggregates/run/pr_watch.ex:522-552,629-640` |
| `PrWatch` holds the PR commands: the command list, the command-to-event map, `@operator_types`, the `run.pr.checks` and `run.pr.review` handlers and the allowed-field list of `event/6`. | `aggregates/run/pr_watch.ex:37-60,82-83,165-193,460-490` |
| `Run` holds the gate: `MergePin`, `State.pr_watch`, `merge_pin/2`, `validate_approval/1` (public), `ensure_merge_gate_pending/2` (private), `merge_approve`, the PR-event routing and the no-op for unknown events; `RunReset` returns `initial_state()`. | `aggregates/run.ex:31-82,119,148-163,306-307,428-445,936-967,1275-1282` |
| `Run.repo_pr_operator_types/0` (`run.pr.retry`) feeds the gateway's operator allowlist. | `aggregates/run.ex:1291-1299`; `command_gateway.ex:65-79,703-704` |
| The gateway verifies the approved head against GitHub (`RunPrMerge.verify_head/3`, one `PrStatus.fetch/2` without review threads) and re-holds an approval when an observation shows another head. | `command_gateway.ex:86-87,177-189,244-259`; `run_pr_merge.ex:74-98` |
| The merge is pinned to the approved head. | `github/pr_merge.ex:40` |
| `signal_pr_ready/2` takes the head from the local `resolve_revision`, a failure is only logged, `finalize_run` discards the PR finalisation result, and a phase PR is returned as the run's PR. | `workflow/run_executor.ex:2491,2570-2594,2630-2657,2659-2683` |
| `PrCreate.signal_ready/6` uses a local `rev-parse`; `PrCreate.open/4` calls `AutoPR` and then string-matches "already exists". | `pr_create.ex:104-125,129-143,206-229` |
| `AutoPR` runs the push and `gh pr create` as keyed effects; `PhasePR` looks up an open PR after its push. | `workflow/auto_pr.ex:237-266,299-353`; `workflow/phase_pr.ex:183-199,334-371` |
| `ReviewFindings.extract/1` answers `:none` for an absent or blank block and for an unreadable file; two callers. | `workflow/review_findings.ex:13-27,38-74`; `workflow/auto_pr.ex:519-525`; `workflow/phase_pr.ex:453-459` |
| `Effect.run/4` and `preflight/3` treat a `started` key and an unmarked `ambiguous` key as clear; the required metadata per class is a map. | `idempotency/effect.ex:43-55,82-114,159-182` |
| `KeyStore` records merge metadata; `list_by_status/1` falls back to ETS when the repo query raises, `list_records_checked/1` does not; durability is probed. | `idempotency/key_store.ex:186-194,204-240,277-324,444-458` |
| The `Reconciler` behaviour has one callback; the registry is configuration; the task-provider `reopen` is repeatable. | `idempotency/reconciler.ex:41,44-65`; `idempotency/reconcilers/task_provider.ex:97-99`; `config/config.exs:45-50` |
| The boot sweep marks an orphaned `started` key `ambiguous` unless the run's executor is alive; `scan_ambiguous_keys/0` has no runtime caller; an unregistered class blocks the run `effect_class_unregistered`. | `workflow/boot_reconciliation.ex:190-192,751-787,803-842,873,885,901-947,1008-1033` |
| `Effect.run/4` callers are `AutoPR`, `PhasePR`, the task-provider wrapper and the boot reopen; `PrFix` is not one. | `workflow/auto_pr.ex:238,258,300`; `workflow/phase_pr.ex:204,220,249`; `idempotency/reconcilers/task_provider.ex:81`; `workflow/run_executor.ex:142,162,5644`; `workflow/boot_reconciliation.ex:447` |
| `PrFix` pushes through a jobsite spec; when the fix ends the reactor re-reads the PR through `Observer.observe/2`. | `pr_fix.ex:383`; `pr_watcher.ex:416-447`; `pr_watcher/observer.ex:62-80` |
| The PR monitor is opt-in, the watcher is on by default, the webhook endpoint fails closed without its secret, and an `issue_comment` delivery triggers a refresh. | `config/runtime.exs:79-84,227-232`; `config/config.exs:311`; `application.ex:724-735`; `webhooks/github.ex:135-141` |
| The settings vocabulary is closed (`@keys`, `validate/2`, `normalize_cleared/1`); `pr_auto_fix` is its precedent and is referenced only in the settings module, the event, the typed read, the MCP tool and the auto-fix policy. | `aggregates/project/settings.ex:43-47,144-163,184-204,219-291`; `events/project_updated.ex:12-58`; `project_settings.ex:9-29`; `pr_watcher/auto_fix.ex:42` |
| `foreman_project_settings_update` is an MCP write tool (usable when `allow_workflow_writes` is on, default off), dispatches `project.update` as an operator command, and its `clear` list accepts any setting name. | `mcp/policy.ex:4-32,75-77`; `mcp/tools.ex:508-578,2452-2478,2684-2694` |
| The Go CLI: project flags and usage text; `runApproveMerge`; `runPrs` prints the server's JSON; the drift tests check verbs (usage and cli-reference), not flags. | `packages/foreman_cli/cmd/foreman/project.go:21,194,293-300,455-463`; `run.go:191-236,378-394`; `main.go:97`; `usage_drift_test.go:148-201` |
| The PR DTO is built from the projection with three store calls and has no typed unavailable answer. | `pr_watch/dto.ex:17-51,60-99`; `foreman_server_web/controllers/run_controller.ex:54-64`; `mcp/tools.ex:1482-1490` |
| `ProjectionStore.init/1` starts empty when the event-log read fails; the runtime rebuild replies the error and keeps its state. | `projection_store.ex:1240-1243,1573-1587,2184-2189` |
| Overview classification, its input, the dashboard reset matrix. | `overview/group.ex:130-159`; `overview/input.ex:34-50`; `overview.ex:295-325`; `foreman_server_web/operator_dashboard.ex:158-170` |
| `Coordinator.Redact` exists; no PR comment or review write exists anywhere (grep over workflow, github, pr_watcher, vcs_adapter); the other `gh` calls are `pr_status.ex:275`, `vcs_adapter/default.ex:70`, `github/pr_merge.ex:40`. | `coordinator/redact.ex:1-107` |
| The guard tests pin the operator-only commands and forbid the words merge and approve in MCP tool names. | `test/foreman_server/operator_only_pr_commands_test.exs:17-24`; `test/foreman_server/mcp/no_merge_tool_test.exs:7-23` |
| The constitution: only `CommandRouter` appends, events are typed modules, and breaking changes to CLI commands or domain events need explicit approval. | `docs/standards/constitution.md:88-92,124-128,132-140` |
| The four beads exist and are open; the decision record's limitations (xv), (xviii) and (xxii) describe them. | `.beads/issues.jsonl` (`foreman-by6nl` line 1864); `docs/decisions/phase-0-durable-execution-engine.md:159,165,173` |

## 6. Architecture Decision

Decision: extend the current engine (the operator's Phase 0 decision) with a per-head evidence record folded into the Run aggregate, a deterministic evaluator read by the approval gate, and a keyed, redacted PR comment. Four things were considered.

- **A. Server-observed GitHub evidence, decided in the aggregate (chosen).** Check results come from the GitHub rollup in the same `gh pr view` response that names the head. The aggregate records them, so `merge_approve` decides from folded state and stays deterministic. The cost is more events and a second fold (the projection), kept equal by one shared fold module.
- **B. Server-run command checks (deferred).** They would run project code in a checkout of the head on a host whose filesystem and network the Phase 0 execution profile records as unenforced. Revisit in a later phase with an enforced profile.
- **C. A model-only rubric (rejected).** A model's level cannot be reproduced, so it cannot be tested or audited; the model may only raise the deterministic level (AC-003-5).
- **D. Evidence held outside the aggregate (rejected).** An evaluator that reads the projection or GitHub inside `merge_approve` is not deterministic on replay and is not network-free (`run_pr_merge.ex:7-12`).

**Components.** `PrEvidence` (new): the evidence sub-record, one fold used by both `PrWatch.apply_event/3` and `PrWatchFold.apply_event/3`, `evaluate/2`, `evaluate_checks/2`, `project_policy/1`. `PrRisk` and `PrRisk.Rubric`: the judgement parser and the pure rubric. `PrReport`, `PrReport.Publisher` and `GitHub.PrComment`: the rendered, redacted comment and its write. `GitHub.PrLookup`: the open-PR lookup. `Reconcilers.PrComment`: the reconciler of the new effect class. Changed: `PrStatus`, `PrObservation`, `Observer`, `PrWatch`, `Run`, `CommandGateway`, `RunPrMerge`, `Effect`, `KeyStore`, `BootReconciliation`, the settings vocabulary, the DTO, `ProjectionStore.init/1`, Overview and the dashboard.

**Data flow.** An observation (poll, webhook or the gateway's own read at approval) yields one `PrStatus`; `PrObservation.commands/6` turns it into `run.pr.update`, `run.pr.checks` (every check, the policy) and `run.pr.risk` commands; the aggregate folds them into `evidence`. At finalisation the review artifact is parsed once into `run.pr.findings` (findings and judgement, bound to the reviewed head). `merge_approve` evaluates `PrEvidence.evaluate/2` for `approval.head_sha` from aggregate state. The publisher reacts to `PrRiskRecorded` and writes one comment through the keyed `pr_comment` effect.

**Head invalidation.** When an event brings a head different from the record's, the fold resets the check and review fields and `evidence`. Per surface: the fold (reset, TRD-007); the DTO (evidence of another head is labelled stale, TRD-023); the published comment (it names its head and digest; a new head edits it, TRD-021); the waiver (dropped with the head, TRD-012); the approval (re-held by the existing `run.pr.rehold`, `command_gateway.ex:177-189`); the effect (keyed by head, P-4: a settled key is re-run, `effect.ex:159-182`).

**What must be on.** The gate does not depend on monitoring: at approval the gateway re-reads GitHub and records fresh evidence for the named head (TRD-022). The PR monitor (`FOREMAN_PR_MONITOR_ENABLED=true`) or a verified webhook is needed only for the status to show a head change without anyone approving; the doctor reports it (TRD-009, TRD-010).

## 7. Design Principles for Every Task

- A proof task is a real run: its `-TEST` sibling states the mutation that must make it fail, so a green test cannot pass vacuously.
- No stub reconciler, no fake backend result, no placeholder event.
- New event fields are optional; existing streams must replay. Each event change includes a codec round-trip test.
- Every Phase 1 effect is keyed by head SHA (P-4), registered with a reconciler before it can run, and refuses an undecided key (P-1).
- Evidence is trusted only when Foreman read it from GitHub in the same response as the head it is bound to. Agent-run output, an agent-written file and a prompt claim are never evidence.

## Master Task List

Task ids are hyphenated (`TRD-NNN`, tests `TRD-NNN-TEST`); estimates are `(Nh)` whole hours. Target paths are relative to the repository root. A `Target Files:` line holds only paths; files that do not exist yet are listed once under "Files this TRD creates" below.

### PR 1: The Phase 0 engine decision is accepted and the record states what Phase 1 inherits

**Shippable State:** The decision record reads as accepted by the operator on 2026-11-12 with preconditions P-1 to P-4, and a reader finds what Phase 1 inherits (each carried limitation, its disposition and its bead) without opening the Phase 0 TRD. No code changes.

- [ ] **TRD-001**: Edit `docs/decisions/phase-0-durable-execution-engine.md`: replace the `Status:` line (today "proposed ... not accepted until the operator reviews it") with the acceptance (operator, 2026-11-12) naming P-1 to P-4, keeping the superseded wording as history; add "Accepted, with preconditions for Phase 1 code" (P-1 `foreman-by6nl`, P-2 `foreman-tnlqt`, P-3 the durable store, P-4 head-keyed effects) and "What Phase 1 inherits": a table of the carried limitations with disposition PREREQUISITE, FOLD-IN or INDEPENDENT, each with its bead and the Phase 1 task that closes it (`foreman-by6nl` TRD-002 and TRD-003; `foreman-tnlqt` TRD-004; the durable store TRD-005; `foreman-rsbx1` TRD-024; `foreman-87h5g` TRD-023; limitation (xviii) TRD-008; the other open beads independent). The other beads the record cites (`foreman-6vlx6`, `foreman-t2627`, `foreman-p7asb`, `foreman-f6zmv`, `foreman-l30ao`) are INDEPENDENT; those five and the four above exist and are open in `.beads/issues.jsonl` (read with `jq`, 2026-11-12). Add a forward pointer to this TRD. The history rows of the record are not rewritten. [satisfies REQ-001] (3h)
  - Validates PRD ACs: none (PRD §5 preconditions; a decision-record edit)
  - Target Files: `docs/decisions/phase-0-durable-execution-engine.md`
  - Implementation AC:
    - [ ] Given the record, when its status line is read, then it says accepted by the operator on 2026-11-12, lists P-1 to P-4, and keeps the earlier "proposed" wording as history.
    - [ ] Given the section "What Phase 1 inherits", when it is read, then each limitation Phase 1 meets names its disposition, its bead where one exists, and the Phase 1 task (or "none") that closes it, and `foreman-rsbx1` and `foreman-87h5g` are marked FOLD-IN.
    - [ ] Given the Phase 0 decision text and history rows, when the diff is read, then they are unchanged (AGENTS.md: point-in-time specs get a forward-pointer, not a rewrite).
- [ ] **TRD-001-TEST**: A reviewer checklist in the PR description (not a script): the status line says accepted with P-1 to P-4; every bead id cited exists in `.beads/issues.jsonl`; the history rows are untouched. [verifies TRD-001] [satisfies REQ-001] [depends: TRD-001] (1h)
  - Validates PRD ACs: none (a reviewer checklist for a documentation task)
  - Target Files: `docs/decisions/phase-0-durable-execution-engine.md`
  - Test AC:
    - [ ] Given a bead id in the table that is not in the ledger, when the reviewer applies the checklist, then the item names it and fails, and the record is returned for correction.

### PR 2: An undecided effect key is refused, an existing PR is adopted, and gating needs a durable store

**Shippable State:** An effect whose key is `started`, or `ambiguous` without a recorded `not_done` decision, is refused and the boot sweep is asked to decide it, never repeated; `gh pr create` adopts an open PR GitHub already has before it runs and before its key settles `failed`, and a block, reset and resume sequence is walked by a test; the idempotency store's durability can be required, and the doctor reports it.

- [ ] **TRD-002**: P-1, part 1: make `Effect.run/4` and `Effect.preflight/3` refuse an undecided key. `check_unresolved/2` (`idempotency/effect.ex:159-182`) treats a `started` key and an unmarked `ambiguous` key as clear (`:164-175`), which is `foreman-by6nl`. A key is decided when it is `completed` or `failed` (a settled effect may run again, P-4 keys it by head), not found, marked unresolved (existing refusal), or `ambiguous` with `decision: "not_done"` recorded on it. Any other `started` or `ambiguous` key returns `{:error, {:effect_undecided, key}}` without calling `fun` and without touching the key. A repeatable effect is never undecided: a task-provider `reopen` (`Reconcilers.TaskProvider.repeatable?/1`, `reconcilers/task_provider.ex:97-99`) is exempt, because refusing it would refuse the boot reopen of a terminal run for good (the reasoning at `workflow/boot_reconciliation.ex:1045-1049`). The rule moves from `BootReconciliation.repeatable_effect?/2` (`:1069-1070`, a hard-coded class check) to an optional `repeatable?/1` callback of the `Reconciler` behaviour (`idempotency/reconciler.ex:41`) read through `Reconciler.repeatable?/2`, so `Effect` and the sweep share one definition. `KeyStore` records merge new metadata into the stored (`idempotency/key_store.ex:277-324`), so `record_intent/3` (`:235-255`) writes `"decision" => nil` when it re-marks a key `started`, as the lifted path does for the marker (`:246`), and a second crash is undecided again. `KeyStore.mark_decided/2` writes the decision (a compare-and-set inside the store: only for an `ambiguous` key that carries no unresolved marker). The new refusal is handled where `effect_unresolved` is: `workflow/auto_pr.ex:357-375` (`log_refusal`), `workflow/phase_pr.ex:305-313` (`effect_result`), `workflow/run_executor.ex:5656-5664` (the task-provider refusal kinds, a permanent refusal) and `foreman_server_web/workspace/actions.ex:769-775` (operator wording). [satisfies REQ-001] [depends: TRD-001] (6h)
  - Validates PRD ACs: none (precondition P-1, PRD §5)
  - Target Files: `packages/foreman_server/lib/foreman_server/idempotency/effect.ex`, `packages/foreman_server/lib/foreman_server/idempotency/key_store.ex`, `packages/foreman_server/lib/foreman_server/idempotency/reconciler.ex`, `packages/foreman_server/lib/foreman_server/idempotency/reconcilers/task_provider.ex`, `packages/foreman_server/lib/foreman_server/workflow/boot_reconciliation.ex`, `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex`, `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex`, `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`, `packages/foreman_server/lib/foreman_server_web/workspace/actions.ex`
  - Implementation AC:
    - [ ] Given a key `started` by a process that died, when `Effect.run/4` or `Effect.preflight/3` is called for it, then it returns `{:error, {:effect_undecided, key}}`, `fun` is not called and the key is unchanged.
    - [ ] Given an `ambiguous` key with no unresolved marker and no decision, when `Effect.run/4` is called, then it is refused the same way; given the same key carrying `decision: "not_done"`, then it runs, re-marks the key `started` and clears the decision.
    - [ ] Given a `completed` or `failed` key, when `Effect.run/4` is called, then behaviour is unchanged (it runs again), because P-4 gives each Phase 1 effect a head-keyed identity.
    - [ ] Given a task-provider `reopen` key that is `started`, or `ambiguous` with no decision, when `Effect.run/4` is called, then it runs (a repeatable effect is never undecided), and the sweep's rule that such a key is not marked unresolved is unchanged.
    - [ ] Given an `effect_undecided` refusal in `AutoPR`, `PhasePR`, the task-provider path and the operator Create PR action, then each reports it as a refusal naming the key (not as a provider failure) and none retries the call.
    - [ ] Given the `refusal` type (`effect.ex:43-47`) and the `run/4` documentation (`:64-79`), then both name `{:error, {:effect_undecided, key}}` beside the existing refusals.
- [ ] **TRD-002-TEST**: `Effect` refusal tests for each key status, the decision lifecycle across a re-mark, and the four handlers. [verifies TRD-002] [satisfies REQ-001] [depends: TRD-002] (4h)
  - Validates PRD ACs: none (precondition P-1)
  - Target Files: `packages/foreman_server/test/foreman_server/idempotency/effect_test.exs`, `packages/foreman_server/test/foreman_server/idempotency/effect_undecided_test.exs`, `packages/foreman_server/test/foreman_server/workflow/auto_pr_test.exs`, `packages/foreman_server/test/foreman_server/workflow/phase_pr_test.exs`, `packages/foreman_server/test/foreman_server/workflow/boot_reconciliation_effect_keys_test.exs`
  - Test AC:
    - [ ] Given `check_unresolved/2` still returns clear for a `started` key, when the suite runs, then the `started` refusal test fails.
    - [ ] Given the decision is not cleared when a key is re-marked `started`, when the second-crash test runs, then it fails because the key runs without a decision.
    - [ ] Given a settled (`completed`) key is refused, when the unchanged-behaviour test runs, then it fails.
    - [ ] Given `Effect` treats a task-provider `reopen` key as undecided, when the repeatable-effect test runs, then it fails.
- [ ] **TRD-003**: P-1, part 2: make the sweep decide, be reachable and be visible. `reconcile_effect_key/2` (`workflow/boot_reconciliation.ex:901-947`) reads an `ambiguous` effect key and, for a `not_done` verdict, `handle_effect_verdict/6` (`:1008-1033`) records `effect_retried` and returns; it now also writes `decision: "not_done"` on the key, after `effect_retried` is recorded (a failed dispatch or a failed write leaves the key undecided, so it stays refused, and is counted `unresolved`; a repeat in the same incarnation is deduplicated by the command id, `:1017`). A key that already carries the decision is skipped (`skip_effect_key/2`, `:949-955`). The effect part of `do_reconcile_ambiguous_keys/2` (`:751-787`) reads with `KeyStore.list_records_checked/1` (`idempotency/key_store.ex:189-194`) instead of `list_by_status/1`, which falls back to the ETS table when the repo query raises (`:444-458`; the doc comment says so at `:186-187`); a failed read is logged, counted `unresolved` and leaves every key undecided (still refused, because refusal does not depend on the sweep having listed the key). `Effect` casts `BootReconciliation.scan_ambiguous_keys/0` (`:190-192`; its only callers are tests, `test/foreman_server/workflow/boot_reconciliation_ambiguous_keys_test.exs:211`) once per refusal, best effort, so a decision can arrive without a restart. The scan first marks orphaned `started` keys `ambiguous` (`mark_orphaned_started_keys/0`, `:803-834`), but a run with a live executor is never orphaned (`run_executor_alive?/2`, `:836-842`), so a `started` key of a run whose executor is alive stays refused until that executor ends and a later scan or a restart decides it (§14). `ForemanServerWeb.MCP.Tools.Doctor.unresolved_effect_keys/0` (`foreman_server_web/mcp/tools/doctor.ex:71-96`) lists `started` effect keys as well as `ambiguous` ones and shows each key's status and decision, so a refusal can be traced to its key. The bead's third item, ordering the sweep before executors resume, is not built: with TRD-002 an executor that reaches an undecided key is refused, so ordering is a liveness matter (§14). [satisfies REQ-001] [depends: TRD-002] (6h)
  - Validates PRD ACs: none (precondition P-1, PRD §5)
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/boot_reconciliation.ex`, `packages/foreman_server/lib/foreman_server/idempotency/effect.ex`, `packages/foreman_server/lib/foreman_server/idempotency/key_store.ex`, `packages/foreman_server/lib/foreman_server_web/mcp/tools/doctor.ex`
  - Implementation AC:
    - [ ] Given an ambiguous effect key whose reconciler says `:not_done`, when the sweep runs, then the key carries `decision: "not_done"` and the next `Effect.run/4` for it runs; given the decision cannot be written, then the key stays refused and the sweep counts it `unresolved`.
    - [ ] Given the repo read of the effect keys fails, when the sweep runs, then it does not treat the failure as "no ambiguous keys": it logs, counts `unresolved` and decides nothing, and every undecided key stays refused.
    - [ ] Given `Effect.run/4` refuses an undecided key, when the refusal is returned, then `BootReconciliation.scan_ambiguous_keys/0` has been cast (a dead `BootReconciliation` does not change the refusal).
    - [ ] Given the `effect_retried` command cannot be recorded, when the sweep runs, then no decision is written, the key stays refused and the sweep counts it `unresolved`.
    - [ ] Given an effect key that is `started` (a process killed mid-effect) or `ambiguous` with no decision, when `foreman_doctor` runs, then the key is listed with its status and its decision.
- [ ] **TRD-003-TEST**: Sweep tests with the injectable command runner: decision written on `not_done`, a failing repo read, the on-demand scan. [verifies TRD-003] [satisfies REQ-001] [depends: TRD-003] (4h)
  - Validates PRD ACs: none (precondition P-1)
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/boot_reconciliation_effect_keys_test.exs`, `packages/foreman_server/test/foreman_server/idempotency/key_store_durability_test.exs`, `packages/foreman_server/test/foreman_server/idempotency/effect_undecided_test.exs`, `packages/foreman_server/test/foreman_server_web/mcp/tools/doctor_test.exs`
  - Test AC:
    - [ ] Given the sweep does not write the decision, when the `not_done` test runs, then the next `Effect.run/4` is refused and the test fails.
    - [ ] Given the sweep still reads through `list_by_status/1`, when the failing-read test runs (the repo read raises), then the sweep reports no unresolved key and the test fails.
    - [ ] Given the doctor lists only `ambiguous` keys, when the started-key listing test runs, then it fails.
- [ ] **TRD-004**: P-2: consult GitHub before `gh pr create` and before its key settles `failed` (`foreman-tnlqt`, limitation (xxii)). New `GitHub.PrLookup.find_open/3` runs `gh pr list --state open --head <head> --base <base> --json url,number,state --limit 1` in the checkout through the injectable runner and returns `{:ok, %{url, number}}`, `:none` or `{:error, reason}`; one module replaces the inline `matching_pr/2` of `workflow/phase_pr.ex:334-371` and serves `AutoPR`. In `AutoPR.gh_pr_create/7` (`workflow/auto_pr.ex:309-353`) an open PR found before the call is the effect's outcome (`{:ok, url}`, the key settles `completed`, no `gh pr create` runs), and a non-zero exit is followed by a second lookup, so a PR GitHub created despite the exit code is adopted and the key does not settle `failed`; a lookup that fails is never success. The string match `adopt_existing/2` in `pr_create.ex:215,220-229` is removed (`PrCreate.open/4` calls `AutoPR.maybe_create_pr/1`, `:206-218`, so the operator path gets the adoption from `AutoPR`). A closed or merged PR does not suppress creation (unchanged). The decision record's inferred wedge is walked: a key blocked `done`, `run.reset`, resume, `AutoPR` adopts the PR and the key settles `completed`. [satisfies REQ-001] [depends: TRD-002] (7h)
  - Validates PRD ACs: none (precondition P-2, PRD §5)
  - Target Files: `packages/foreman_server/lib/foreman_server/github/pr_lookup.ex`, `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex`, `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex`, `packages/foreman_server/lib/foreman_server/pr_create.ex`
  - Implementation AC:
    - [ ] Given an open PR exists for the head and base, when `AutoPR.maybe_create_pr/1` runs, then it returns `{:ok, url}` for that PR, `gh pr create` is not called and the key is `completed`.
    - [ ] Given `gh pr create` exits non-zero and an open PR exists afterwards, when the effect settles, then the result is `{:ok, url}` and the key is not `failed`; given none exists, then the original `{:error, {:gh_pr_create_failed, code, output}}` is returned.
    - [ ] Given the lookup itself fails, when `AutoPR` runs, then it proceeds to `gh pr create` and reports that call's own result (a failed lookup is never a success).
    - [ ] Given a run blocked on a `done` verdict and then reset, when it resumes, then the sequence block, `run.reset`, resume ends with the PR adopted and the key `completed`, and the test says it walked each step.
    - [ ] Given `PrCreate.open/4` after this change, then it carries no string match on `gh` output.
- [ ] **TRD-004-TEST**: `PrLookup` unit tests, the `AutoPR` and `PhasePR` adoption tests, and the block, reset, resume walk with an injected `gh` runner. [verifies TRD-004] [satisfies REQ-001] [depends: TRD-004] (5h)
  - Validates PRD ACs: none (precondition P-2)
  - Target Files: `packages/foreman_server/test/foreman_server/github/pr_lookup_test.exs`, `packages/foreman_server/test/foreman_server/workflow/auto_pr_test.exs`, `packages/foreman_server/test/foreman_server/workflow/phase_pr_test.exs`, `packages/foreman_server/test/foreman_server/pr_create_test.exs`, `packages/foreman_server/test/foreman_server/workflow/auto_pr_block_reset_resume_test.exs`
  - Test AC:
    - [ ] Given `AutoPR` skips the lookup before `gh pr create`, when the adoption test runs, then `gh pr create` is called and the test fails.
    - [ ] Given the second lookup after a non-zero exit is removed, when the exit-code test runs, then the key settles `failed` and the test fails.
    - [ ] Given the reset run still fails with "already exists", when the block, reset, resume walk runs, then it fails on the final assertion.
- [ ] **TRD-005**: P-3: the smallest verifiable guard. `KeyStore.require_durable/0` returns `:ok` when `durable?/0` is true (`idempotency/key_store.ex:204-212`) and `{:error, {:store_not_durable, note}}` with `durability_note/0` (`:225-240`) otherwise; it is a no-op when `config :foreman_server, :require_durable_store_for_gating` is false (true in `config/config.exs`, false in `config/test.exs` and `config/dev.exs`, where `:jido_ecto` is off, `config/dev.exs:39`, `config/test.exs:103`). `foreman_doctor` gains a line "Phase 1 gating: durable store required / met / not met" next to its existing idempotency-store line (`foreman_server_web/mcp/tools/doctor.ex:98-105` `store_line/0`, printed by `effect_keys_section/0` at `:130-143` and by the HTTP check `foreman_server_web/controllers/doctor_controller.ex:69-91`). TRD-010 calls the guard where gating is enabled; the production default stays off (`config/prod.exs:78`) and switching the store on stays a deployment step. [satisfies REQ-001] [depends: TRD-001] (4h)
  - Validates PRD ACs: AC-001-6
  - Target Files: `packages/foreman_server/lib/foreman_server/idempotency/key_store.ex`, `packages/foreman_server/lib/foreman_server_web/mcp/tools/doctor.ex`, `packages/foreman_server/lib/foreman_server_web/controllers/doctor_controller.ex`, `packages/foreman_server/config/config.exs`, `packages/foreman_server/config/test.exs`
  - Implementation AC:
    - [ ] Given the guard is required and the store is ETS-only, when `require_durable/0` is called, then it returns `{:error, {:store_not_durable, note}}` and the note names `config :foreman_server, :jido_ecto, enabled: true` and `JIDO_CHECKPOINT_DATABASE_URL`.
    - [ ] Given the guard is required and the store is durable, then it returns `:ok`; given the config switch is false, then it returns `:ok` whatever the store.
    - [ ] Given the doctor runs, then it prints whether the durable store is required and met for gating, and the line is `:ok` when gating is not enabled anywhere.
- [ ] **TRD-005-TEST**: Guard tests for the three states and the doctor line. [verifies TRD-005] [satisfies REQ-001] [depends: TRD-005] (3h)
  - Validates PRD ACs: AC-001-6
  - Target Files: `packages/foreman_server/test/foreman_server/idempotency/key_store_durability_test.exs`, `packages/foreman_server/test/foreman_server_web/mcp/tools/doctor_test.exs`, `packages/foreman_server/test/foreman_server_web/controllers/doctor_controller_test.exs`
  - Test AC:
    - [ ] Given `require_durable/0` returns `:ok` for an ETS-only store, when the guard test runs with the switch on, then it fails.
    - [ ] Given the doctor line is dropped, when the doctor test runs, then it fails.

### PR 3: Check evidence is recorded per head from GitHub and a head change invalidates it

**Shippable State:** For a watched PR the run stream records every check of the head (name, kind, workflow, state, conclusion, start and completion time) from the same GitHub response that names the head; the aggregate and the projection reset check and review evidence when the head moves; the PR's head of record comes from GitHub; a failed ready signal is a recorded, visible condition; and what must be on for a head change to be seen (monitor or webhook) is reported by the doctor.

- [ ] **TRD-006**: Per-check evidence from `PrStatus`. The rollup already carries `startedAt` and `completedAt` for a check run and `startedAt` for a status context (probe, §5), so `@json_fields` (`github/pr_status.ex:131`) is unchanged. `check/1` (`:388-418`) adds `started_at` and `completed_at` to the normalised check (`@type check`, `:64-71`): a `COMPLETED` check run without a non-empty `completedAt` is a typed `{:gh_unexpected_payload, item}` (never defaulted), a status context has `completed_at: nil`. `PrObservation.checks_digest/1` (`pr_observation.ex:43-51`) hashes every check as `{name, kind, workflow, state, conclusion, completed_at}` in sorted order, not only the failing names, so a changed passing set or a re-run moves the digest; `checks_commands/5` (`:134-160`) puts the full list (`checks`, bounded by the existing `@max_list`, with `checks_truncated`) on the `run.pr.checks` payload next to the existing `failing` list. [satisfies REQ-001] (6h)
  - Validates PRD ACs: AC-001-1, AC-001-4
  - Target Files: `packages/foreman_server/lib/foreman_server/github/pr_status.ex`, `packages/foreman_server/lib/foreman_server/pr_observation.ex`
  - Implementation AC:
    - [ ] Given a rollup with a completed check run, when `PrStatus.fetch/2` parses it, then the check carries `started_at` and `completed_at` exactly as GitHub reported them; given a `COMPLETED` check run with no `completedAt`, then it returns `{:error, {:gh_unexpected_payload, item}}`.
    - [ ] Given a status context, then the check carries `started_at` and `completed_at: nil`, and its `kind` is `:status_context`.
    - [ ] Given two observations whose failing checks are equal but whose passing checks differ (a check added, removed, or re-run with a new `completedAt`), when `checks_digest/1` runs, then the digests differ; given identical checks, then they are equal.
    - [ ] Given a `run.pr.checks` command, then its payload carries every check of the head (up to the bound) and `checks_truncated`, all read from the one `PrStatus` that also names `head_sha`.
- [ ] **TRD-006-TEST**: `PrStatus` and `PrObservation` tests with real rollup fixtures captured from `gh` 2.103.3 (check run and status context). [verifies TRD-006] [satisfies REQ-001] [depends: TRD-006] (4h)
  - Validates PRD ACs: AC-001-1, AC-001-4
  - Target Files: `packages/foreman_server/test/foreman_server/github/pr_status_checks_test.exs`, `packages/foreman_server/test/foreman_server/github/pr_status_test.exs`, `packages/foreman_server/test/foreman_server/pr_observation_test.exs`
  - Test AC:
    - [ ] Given `check/1` drops `completedAt`, when the timing test runs, then it fails.
    - [ ] Given the digest still hashes only failing checks, when the passing-set test runs, then the digests are equal and the test fails.
    - [ ] Given a completed check run with no `completedAt` is defaulted to `nil`, when the malformed-payload test runs, then it fails.
- [ ] **TRD-007**: The evidence record, folded once, reset on a head change. New `PrEvidence` (`pr_evidence.ex`) owns the evidence sub-record of a watched PR and one fold, `apply_event/3`, called by both `Aggregates.Run.PrWatch.apply_event/3` (`aggregates/run/pr_watch.ex:514-552`) and `PrWatchFold.apply_event/3` (`pr_watch_fold.ex:111-150`), so the aggregate and the projection cannot disagree (AGENTS.md 5.7); both records gain an `evidence` field in their constructors (`pr_watch.ex:629-640`, `pr_watch_fold.ex:36-61`). `PrChecksChanged` (`events/pr_checks_changed.ex:13-46`) gains optional `checks`, `checks_truncated`, `required` and `policy_version` (defaults `[]`, `false`, `nil`, `nil`; a codec round trip), and the allowed-field list of the aggregate's `event/6` (`pr_watch.ex:460-490`) gains the same. The `run.pr.checks` handler (`pr_watch.ex:165-178`) validates `checks` strictly (a list of at most 100 items with name, kind, state, conclusion, timestamps and workflow, closed sets for kind and state) so a malformed payload never reaches the stream. The fold stores `evidence.checks = %{head_sha, items, truncated, observed_at, digest}`. Head reset: all four head-carrying events (`PrUpdated`, `PrReady`, `PrChecksChanged`, `PrReviewChanged`) put the new `head_sha` today and none clears the half of the evidence the event does not carry (a `PrChecksChanged` for a new head leaves `review_decision` of the old one; a `PrReviewChanged` leaves `checks_state`). When an event brings a `head_sha` different from the record's non-nil one, the fold first resets the record's check and review fields (`checks_state`, `checks_digest`, `review_decision`, `review_digest`, and `failing` in the projection record: the two records carry different field sets) and its `evidence`, then applies the event; `comment_ids`, `thread_ids` and the sequence counters are kept. Evidence keeps the head it was recorded for, so a reader can compare. [satisfies REQ-001] [satisfies REQ-005] [depends: TRD-006] (7h)
  - Validates PRD ACs: AC-001-1, AC-005-2, AC-004-2
  - Target Files: `packages/foreman_server/lib/foreman_server/pr_evidence.ex`, `packages/foreman_server/lib/foreman_server/events/pr_checks_changed.ex`, `packages/foreman_server/lib/foreman_server/aggregates/run/pr_watch.ex`, `packages/foreman_server/lib/foreman_server/pr_watch_fold.ex`
  - Implementation AC:
    - [ ] Given a `PrChecksChanged` with `checks` for head H, when the aggregate and the projection fold it, then both hold the same `evidence.checks` bound to H, and an old event with no `checks` folds as before.
    - [ ] Given a head-carrying event (`PrUpdated`, `PrReady`, `PrChecksChanged` or `PrReviewChanged`) that moves the head from H1 to H2, when it is folded, then the check and review fields and the `evidence` of H1 are reset in both folds before the event's own fields apply (a `PrChecksChanged` for H2 leaves no `review_decision` of H1, a `PrReviewChanged` for H2 leaves no `checks_state` of H1), and `comment_ids`, `thread_ids` and the sequence counters are kept.
    - [ ] Given a `run.pr.checks` command whose `checks` contain an unknown `kind` or `state`, or more than 100 items, then the aggregate rejects it with `{:missing_or_invalid, :checks}` and nothing is appended.
    - [ ] Given the aggregate state is rebuilt by replay, then `evidence` equals the live fold (`Aggregate.load/2`).
- [ ] **TRD-007-TEST**: Fold parity (aggregate against projection), head-reset, strict validation and replay tests. [verifies TRD-007] [satisfies REQ-001] [satisfies REQ-005] [depends: TRD-007] (5h)
  - Validates PRD ACs: AC-001-1, AC-005-2, AC-004-2
  - Target Files: `packages/foreman_server/test/foreman_server/pr_evidence_test.exs`, `packages/foreman_server/test/foreman_server/aggregates/run_pr_watch_test.exs`, `packages/foreman_server/test/foreman_server/projection_store_pr_watch_test.exs`, `packages/foreman_server/test/foreman_server/event_codec_test.exs`
  - Test AC:
    - [ ] Given the fold still leaves `checks_state` in place when `PrUpdated` moves the head, when the head-reset test runs, then it fails.
    - [ ] Given a `PrChecksChanged` for a new head leaves the `review_decision` of the old head, when the cross-half reset test runs, then it fails.
    - [ ] Given only one of the two folds applies the reset, when the parity test runs, then the aggregate and the projection records differ and it fails.
    - [ ] Given the handler accepts an unknown `kind`, when the validation test runs, then it fails.
- [ ] **TRD-008**: The PR's head of record comes from GitHub, and a failed ready signal is recorded. `signal_pr_ready/2` (`workflow/run_executor.ex:2630-2657`) takes `head_sha` from the local `resolve_revision` today; it reads `PrStatus.fetch(pr_url)` instead (its `head_sha`, the head GitHub names), as does `PrCreate.signal_ready/6` (`pr_create.ex:104-125`, local `rev-parse` in `head_sha/2`, `:129-143`). When the read or the dispatch fails, a new system command `run.pr.ready_failed` records `PrReadyFailed` (`run_id`, `pr_url`, `stage`, `reason`, `failed_at`), folded into `evidence.delivery_issue` by `PrEvidence` and cleared by the next `PrReady`; today the failure is a log line only (`run_executor.ex:2651-2655`) and `finalize_run` discards the result (`:2491`). The run still completes (a PR outlives its run, `aggregates/run.ex:1305-1321`), but the operator can see the condition. This closes limitation (xviii) of the decision record for the ready signal; a refused PR creation is recorded as the same condition with `stage: "pr_create"`. [satisfies REQ-001] [satisfies REQ-005] [depends: TRD-007] (6h)
  - Validates PRD ACs: AC-001-1, AC-005-1
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`, `packages/foreman_server/lib/foreman_server/pr_create.ex`, `packages/foreman_server/lib/foreman_server/events/pr_ready_failed.ex`, `packages/foreman_server/lib/foreman_server/aggregates/run/pr_watch.ex`, `packages/foreman_server/lib/foreman_server/pr_watch_fold.ex`
  - Implementation AC:
    - [ ] Given GitHub names head H2 while the local branch tip is H1, when `signal_pr_ready/2` dispatches `run.pr.ready`, then `PrReady.head_sha` is H2.
    - [ ] Given the GitHub read fails, when `signal_pr_ready/2` runs, then no `PrReady` is appended, a `PrReadyFailed` with `stage: "head_read"` and the reason is appended, the run still completes, and the record shows `delivery_issue`.
    - [ ] Given a later successful `PrReady` for the same PR, then `delivery_issue` is cleared.
    - [ ] Given the operator Create PR action, then it signals ready with the GitHub head and a failed signal remains the typed `{:pr_ready_signal_failed, reason}` error and also records `PrReadyFailed`.
- [ ] **TRD-008-TEST**: Ready-signal tests: GitHub head against local head, the failure record, clearing on a later ready. [verifies TRD-008] [satisfies REQ-001] [satisfies REQ-005] [depends: TRD-008] (4h)
  - Validates PRD ACs: AC-001-1, AC-005-1
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/run_executor_pr_ready_test.exs`, `packages/foreman_server/test/foreman_server/pr_create_test.exs`, `packages/foreman_server/test/foreman_server/aggregates/run_pr_watch_test.exs`
  - Test AC:
    - [ ] Given `signal_pr_ready/2` still uses the local `rev-parse`, when the head-of-record test runs, then `PrReady.head_sha` is H1 and the test fails.
    - [ ] Given a failed read is only logged, when the failure-record test runs, then no `PrReadyFailed` exists and it fails.
- [ ] **TRD-009**: Cover the head-moving pushes that are not keyed effects, and say what must be on. `PrFix` pushes through a jobsite spec (`"push" => true`, `pr_fix.ex:383`), not through `Effect`: the only callers of `Effect.run/4` and `Effect.preflight/3` are `AutoPR` (`workflow/auto_pr.ex:238,258,300`), `PhasePR` (`workflow/phase_pr.ex:204,220,249`) and the task-provider wrapper (`idempotency/reconcilers/task_provider.ex:81`, called from `workflow/run_executor.ex:142,162,5644` and from the boot reopen, `workflow/boot_reconciliation.ex:447`). A fix push is therefore covered by observation: when the fix jobsite ends the reactor re-reads the PR through `Observer.observe/2` (`pr_watcher.ex:416-447`, `pr_watcher/observer.ex:62-80`), which dispatches the check and review observations with the head GitHub names now, so TRD-007's fold resets the old head's evidence; the watcher otherwise observes on `PrAssociated`, `PrReady` and `PrWatchStarted` (`pr_watcher.ex:66`). A head that moves for any other reason (a person pushes, a force push) is seen only by the poll loop (`FOREMAN_PR_MONITOR_ENABLED=true`, `config/runtime.exs:79-82`, child started at `application.ex:724-726`) or a verified webhook (`FOREMAN_GITHUB_WEBHOOK_SECRET`, `config/runtime.exs:227-232`; without the secret the endpoint answers 503). `foreman_doctor` (`DoctorController`, a new check `pr_observation`) reports the watcher (`PrWatcher.enabled?/0`, on by default, `config/config.exs:311`), the monitor (`PrMonitor.enabled?/0`) and whether the webhook secret is set, and is `warn` when the watcher is off; TRD-010 adds the warning for a project with gating on and neither monitor nor webhook. The gate itself does not depend on either (TRD-022 re-reads GitHub at approval). `PrWatcher` itself needs no change. [satisfies REQ-005] [depends: TRD-007] (4h)
  - Validates PRD ACs: AC-005-2
  - Target Files: `packages/foreman_server/lib/foreman_server_web/controllers/doctor_controller.ex`
  - Implementation AC:
    - [ ] Given a fix finishes with a new head, when the watcher re-reads the PR, then the evidence is reset to the new head (no result of the old head remains as the current head's evidence).
    - [ ] Given the doctor runs, then a `pr_observation` check reports the watcher, the monitor and whether the webhook secret is set, and is `warn` when the watcher is off.
- [ ] **TRD-009-TEST**: A fix push moves the head and the evidence resets; the doctor lines. [verifies TRD-009] [satisfies REQ-005] [depends: TRD-009] (3h)
  - Validates PRD ACs: AC-005-2
  - Target Files: `packages/foreman_server/test/foreman_server/pr_watcher_fix_test.exs`, `packages/foreman_server/test/foreman_server_web/controllers/doctor_controller_test.exs`
  - Test AC:
    - [ ] Given the re-read after a fix does not happen, when the fix-push test runs, then the old evidence remains and it fails.
    - [ ] Given the doctor reports the watcher as on when it is off, when the observation-check test runs, then it fails.

### PR 4: Required checks decide eligibility: a project setting, a typed evaluator and an operator waiver pinned to the head

**Shippable State:** A project can list required checks; for each PR head the evaluator answers eligible or names typed reasons (missing, failing, pending, stale, other_sha, no_checks_configured); an operator can waive evidence for one head; enabling the setting is refused where the store is not durable. Nothing blocks approval yet (the gate is PR 8).

- [ ] **TRD-010**: The `required_checks` project setting, through the closed settings vocabulary (the `pr_auto_fix` precedent; `settings.ex`, `project_updated.ex`, `project_settings.ex`, `mcp/tools.ex` and `pr_watcher/auto_fix.ex` are its only references in `lib`). `Settings` (`aggregates/project/settings.ex:43-47`, `@type key` `:54-71`, `@type error` `:73-98`, `validate/2` `:219-291`) gains `required_checks`: `nil` clears it (gate off; `normalize/1` reads `nil` as clear, `:144-163`), a list is gate on, and `[]` is "no checks configured" (the `repo_allowlist` clause keeps a list, `:249-264`); each entry is string-keyed `%{"name", "kind", "workflow"}` with `kind` `check_run` or `status_context`, `workflow` only for `check_run`, normalised once (sorted, duplicates dropped, at most 20 entries, name at most 200 characters without control characters) with distinct typed errors. `ProjectUpdated` (`events/project_updated.ex:12-58`) gains the optional typed field and `ProjectSettings` (`project_settings.ex:9-29`) the typed read; both derive from `Settings.keys/0`, so a cleared `required_checks` travels in `cleared_settings`. The Go CLI (`foreman_cli/cmd/foreman/project.go`: the flag next to `--pr-auto-fix` at `:194`, the payload mapping next to `:293-300`, `projectSettingNames` at `:455-463`, `projectUsageText` at `:21`) gets `--required-checks <json>`, and `docs/cli-reference.md` documents it (`:24`, `:1251`). Enabling is guarded: `CommandGateway.perform_operator_side_effects/1` for `project.update` (`command_gateway.ex:319-333`) calls `KeyStore.require_durable/0` (TRD-005) when the update sets a non-nil `required_checks`. Loosening the gate is operator-only: `foreman_project_settings_update` is an MCP write tool (`mcp/policy.ex:4-32`; any MCP client can call it when `allow_workflow_writes` is on, default off, `:75-77`) that dispatches `project.update` as an operator command (`mcp/tools.ex:2684-2694`) and whose `clear` list accepts any setting name (`:568-572`, `Settings.normalize_cleared/1`, `settings.ex:184-204`), so the tool (`:2452-2478`) refuses `required_checks` as an argument and in `clear` with `{:operator_only_setting, :required_checks}`, and its schema does not list the key (`:508-578`). The `pr_observation` doctor check of TRD-009 becomes `warn` when any project has `required_checks` set (read through `ProjectionStore.list_projects/0` and `ProjectSettings.from_config/1`) and neither the monitor nor the webhook is on. [satisfies REQ-001] [depends: TRD-005] [depends: TRD-009] (7h)
  - Validates PRD ACs: AC-001-6, AC-001-4
  - Target Files: `packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex`, `packages/foreman_server/lib/foreman_server/events/project_updated.ex`, `packages/foreman_server/lib/foreman_server/project_settings.ex`, `packages/foreman_server/lib/foreman_server/mcp/tools.ex`, `packages/foreman_server/lib/foreman_server/command_gateway.ex`, `packages/foreman_server/lib/foreman_server_web/controllers/doctor_controller.ex`, `packages/foreman_cli/cmd/foreman/project.go`, `docs/cli-reference.md`
  - Implementation AC:
    - [ ] Given a valid list, when `Settings.normalize/1` runs, then it returns the sorted, de-duplicated, string-keyed list; given `nil`, then the setting is cleared (gate off); given `[]`, then it is kept as "gate on, no checks".
    - [ ] Given an entry with an unknown `kind`, a `workflow` on a `status_context`, a blank name, or more than 20 entries, then it returns a distinct typed error and nothing is stored.
    - [ ] Given a `project.update` that sets a non-nil `required_checks` on a node whose store is not durable (with the guard on), then the gateway refuses with `{:store_not_durable, note}` before dispatch; with a durable store it is accepted.
    - [ ] Given `foreman_project_settings_update` is sent `required_checks`, or `clear: ["required_checks"]`, then it refuses with `{:operator_only_setting, :required_checks}` and dispatches nothing; given the Go CLI `foreman project update --required-checks '<json>'`, then the payload carries the parsed list, and `--clear required_checks` clears it.
    - [ ] Given a project with `required_checks` set and neither the monitor nor the webhook on, when the doctor runs, then `pr_observation` is `warn` and names the project.
- [ ] **TRD-010-TEST**: Settings, event replay, gateway guard, MCP refusal and Go CLI tests. [verifies TRD-010] [satisfies REQ-001] [depends: TRD-010] (4h)
  - Validates PRD ACs: AC-001-6, AC-001-4
  - Target Files: `packages/foreman_server/test/foreman_server/aggregates/project_settings_test.exs`, `packages/foreman_server/test/foreman_server/project_settings_replay_test.exs`, `packages/foreman_server/test/foreman_server/mcp/tools_project_settings_test.exs`, `packages/foreman_server/test/foreman_server/command_gateway_test.exs`, `packages/foreman_server/test/foreman_server_web/controllers/doctor_controller_test.exs`, `packages/foreman_cli/cmd/foreman/project_settings_test.go`
  - Test AC:
    - [ ] Given `[]` is normalised to `nil`, when the settings test runs, then gate-on-with-no-checks is indistinguishable from gate-off and it fails.
    - [ ] Given the gateway guard is removed, when the non-durable test runs, then the update is accepted and it fails.
    - [ ] Given the MCP tool accepts `required_checks`, when the refusal test runs, then it fails.
    - [ ] Given the MCP tool accepts `clear: ["required_checks"]`, when the refusal test runs, then it fails.
    - [ ] Given the doctor ignores projects with the gate on, when the observation-warning test runs, then it fails.
- [ ] **TRD-011**: The typed evaluator and the policy snapshot. `PrEvidence.evaluate/2` is a pure function of the PR's evidence record and a clock: it returns `%Eligibility{head_sha, status (:off | :eligible | :ineligible | :waived | :unknown), reasons, waived, policy_version}` with `%Reason{code, subject, detail}` over the closed codes `no_checks_configured`, `missing`, `failing`, `pending`, `stale`, `other_sha` for checks (the findings and risk codes arrive in TRD-015 and TRD-018) and `evidence_unreadable` for a record whose evidence fields cannot be read, which gives `:unknown`, never `:eligible`; `evaluate_checks/2` is the check part on its own (the rubric's input, TRD-016). A required entry matches a check by name and kind, and by workflow when the entry names one; all matches must pass, none is `missing`; a check whose GitHub conclusion is `STALE` is `stale`, as is evidence observed longer ago than the freshness window (§11); evidence bound to a head other than the one being decided gives one `other_sha`; an empty policy list gives `no_checks_configured`. A waiver (TRD-012) covers a reason when its code is in the waiver's `reasons` and its head is the head being decided: the status is `:waived` only when every reason is covered, otherwise `:ineligible` with the uncovered reasons. `policy_version` is the first 16 hex characters of the SHA-256 of the sorted entries (`nil` when the gate is off). The policy reaches each `run.pr.checks` command from the caller, because `PrObservation` is pure (`pr_observation.ex:1-5`): `PrEvidence.project_policy/1` reads the project's `required_checks` (`ProjectionStore.project_projection/1`, then `ProjectSettings.from_config/1`, as `PrWatcher.AutoFix` does for `pr_auto_fix`, `pr_watcher/auto_fix.ex:42`), `Observer` (`pr_watcher/observer.ex:114-136`) passes it to `PrObservation.commands/6`, which puts `required` and `policy_version` on the payload and the policy into the checks digest, so an observation is emitted when the policy changes even with no checks (`empty_checks_digest/1`, `pr_observation.ex:194-195`, suppresses it today); `required: nil` records that the gate is off. [satisfies REQ-001] [depends: TRD-007] [depends: TRD-010] (7h)
  - Validates PRD ACs: AC-001-2, AC-001-3
  - Target Files: `packages/foreman_server/lib/foreman_server/pr_evidence.ex`, `packages/foreman_server/lib/foreman_server/pr_observation.ex`, `packages/foreman_server/lib/foreman_server/pr_watcher/observer.ex`, `packages/foreman_server/lib/foreman_server/aggregates/run/pr_watch.ex`
  - Implementation AC:
    - [ ] Given the policy requires checks A and B and the evidence for the current head has A passing and no B, then `evaluate/2` returns `:ineligible` with `missing` (subject B); given A failing, then `failing`; given A pending, then `pending`; given all passing, then `:eligible`.
    - [ ] Given evidence bound to head H1 and a decision for head H2, then the single reason is `other_sha`; given a check whose conclusion is `STALE`, or evidence older than the window, then `stale`.
    - [ ] Given an empty policy list and no waiver, then `no_checks_configured`; given a waiver covering it at the same head, then `:waived`; given no policy (`required: nil`), then `:off`.
    - [ ] Given a waiver for the head that covers `missing` while a `failing` reason is also present, then the status is `:ineligible` and the reasons are the uncovered ones; given a waiver for another head, then it covers nothing.
    - [ ] Given the project's `required_checks` changes with no new checks, when the next observation runs, then a `run.pr.checks` is emitted carrying the new `required` and `policy_version`.
- [ ] **TRD-011-TEST**: Evaluator table tests (every code, every combination of head, waiver and policy), the aggregate recording the policy, and the observer emitting on a policy change. [verifies TRD-011] [satisfies REQ-001] [depends: TRD-011] (5h)
  - Validates PRD ACs: AC-001-2, AC-001-3
  - Target Files: `packages/foreman_server/test/foreman_server/pr_evidence_test.exs`, `packages/foreman_server/test/foreman_server/pr_observation_test.exs`, `packages/foreman_server/test/foreman_server/pr_watcher_test.exs`, `packages/foreman_server/test/foreman_server/aggregates/run_pr_watch_test.exs`
  - Test AC:
    - [ ] Given a passing check of another workflow satisfies a required entry that names a workflow, when the matching test runs, then it fails.
    - [ ] Given a status context satisfies a required `check_run` entry, when the kind test runs, then it fails.
    - [ ] Given the digest ignores the policy, when the policy-change test runs, then no event is emitted and it fails.
    - [ ] Given the evaluator returns `:waived` when only some reasons are covered, when the partial-waiver test runs, then it fails.
- [ ] **TRD-012**: The operator waiver, pinned to the head, modelled on `merge_approve`. New operator-only command `run.pr.waive_evidence` and event `PrEvidenceWaived` (`run_id`, `pr_url`, `head_sha`, `approver`, `approver_identity`, `reasons`, `reason`, `waived_at`, `repo_id`). The aggregate handler is a clause of `Run.handle_command/2` beside `merge_approve` (`aggregates/run.ex:936-967`), not of `PrWatch`, because the gate check `ensure_merge_gate_pending/2` (`:1275-1282`) is private to `Run`: it requires the gate `:pending` for the repository, reuses `Run.validate_approval/1` (`:148-163`, public; the `ApproverAuthorizer` allowlist) and accepts only reason codes from the waivable set `no_checks_configured`, `missing`, `findings_absent`, `findings_other_sha` (§11; `failing`, `pending`, `stale`, `other_sha` and `findings_malformed` are never waivable). The type is added to `Run.repo_pr_operator_types/0` (`run.ex:1291-1299`; `CommandGateway` builds `@pr_operator_types` from it, `command_gateway.ex:71-72`, and `validate_aggregate_id/1` addresses `run:<id>` for it, `:703-704`); `PrEvidenceWaived` is added to the command-to-event map of `PrWatch` (`pr_watch.ex:48-60`, whose values are `event_types/0`) and to `PrWatchFold`'s `@events` (`pr_watch_fold.ex:24-25`), so `Run.apply_event/2` folds it through `PrEvidence` (`run.ex:428-430`). The gateway reads the live head first in `perform_operator_side_effects/1`, as `merge_approve` does (`command_gateway.ex:244-259`, `RunPrMerge.verify_head/3`), and refuses a named head that is not GitHub's. The fold stores `evidence.waiver` for one head; a head change drops it. The command is in the operator allowlist and in none of the MCP, coordinator or approvals surfaces. The Go CLI gets `foreman run waive-evidence --id --approver --identity --head-sha --waive <codes> --reason [--repo-id]`, modelled on `runApproveMerge` (`foreman_cli/cmd/foreman/run.go:191-236`): a dispatch case (`run.go:30-66`), the `usage` string and the subcommand list of `runRun` (`:23-27`), the Commands block of `usage` in `main.go` (the `run approve-merge` line is `:97`) and `docs/cli-reference.md`, which `usage_drift_test.go` requires for every dispatched verb (`:148-201`). [satisfies REQ-001] [depends: TRD-011] (7h)
  - Validates PRD ACs: AC-001-3, AC-001-5
  - Target Files: `packages/foreman_server/lib/foreman_server/events/pr_evidence_waived.ex`, `packages/foreman_server/lib/foreman_server/aggregates/run.ex`, `packages/foreman_server/lib/foreman_server/aggregates/run/pr_watch.ex`, `packages/foreman_server/lib/foreman_server/pr_watch_fold.ex`, `packages/foreman_server/lib/foreman_server/command_gateway.ex`, `packages/foreman_server/lib/foreman_server/pr_evidence.ex`, `packages/foreman_cli/cmd/foreman/run.go`, `packages/foreman_cli/cmd/foreman/main.go`, `docs/cli-reference.md`
  - Implementation AC:
    - [ ] Given a pending gate, an authorized approver and the live head, when `run.pr.waive_evidence` names `no_checks_configured`, then `PrEvidenceWaived` is appended with the head, the approver, the codes and the reason, and `evaluate/2` returns `:waived` for that head.
    - [ ] Given a code outside the waivable set (`failing`), an unauthorized identity, a head that is not GitHub's, or a gate that is not pending, then the command is refused with a typed error and nothing is appended.
    - [ ] Given the head then moves, when the fold applies the next head-bearing event, then the waiver is gone and the evaluator reports the reasons again.
    - [ ] Given the command type, then it is accepted by `dispatch_operator/2` and by no MCP tool, coordinator or approvals dispatch.
    - [ ] Given the Go CLI `foreman run waive-evidence` with every flag, then it posts `run.pr.waive_evidence` with the head, the codes and the reason, rejects a missing flag without calling the server, and the usage line and the cli-reference entry exist (the existing drift tests pass).
- [ ] **TRD-012-TEST**: Waiver aggregate, gateway and operator-only tests, and the Go CLI tests. [verifies TRD-012] [satisfies REQ-001] [depends: TRD-012] (5h)
  - Validates PRD ACs: AC-001-3, AC-001-5
  - Target Files: `packages/foreman_server/test/foreman_server/aggregates/run_pr_watch_test.exs`, `packages/foreman_server/test/foreman_server/aggregates/run_multi_gate_test.exs`, `packages/foreman_server/test/foreman_server/operator_only_pr_commands_test.exs`, `packages/foreman_server/test/foreman_server/command_allowlist_parity_test.exs`, `packages/foreman_server/test/foreman_server/command_gateway_test.exs`, `packages/foreman_cli/cmd/foreman/run_merge_test.go`, `packages/foreman_cli/cmd/foreman/usage_drift_test.go`
  - Test AC:
    - [ ] Given a waiver for H1 still covers H2, when the head-change test runs, then it fails.
    - [ ] Given the waivable set includes `failing`, when the non-waivable test runs, then the command is accepted and it fails.
    - [ ] Given the command is reachable as an MCP tool, when the operator-only test runs, then it fails.
    - [ ] Given the verb is dispatched without its usage line or its cli-reference entry, when `usage_drift_test.go` runs, then it fails.

### PR 5: Review findings are typed records bound to a head, and absent is not clean

**Shippable State:** A review phase's findings are one typed JSON block with severity, location, description, disposition and source; the parser distinguishes recorded, absent and malformed; a `ReviewFindingsRecorded` event binds them to the reviewed head; absent or malformed evidence leaves the PR ineligible with an operator-visible defect; the free-text extraction is gone and `Review.Verdict` is untouched.

- [ ] **TRD-013**: The typed findings schema and parser. `Workflow.ReviewFindings` (`workflow/review_findings.ex:24-27,38-74`) extracts a Markdown block and answers `:none` for an absent or blank block (its moduledoc says a review that found nothing "has no findings to surface", `:13-22`), which both callers read as "no findings" (`AutoPR.findings_section/1`, `workflow/auto_pr.ex:519-525`; `PhasePR.findings_section/1`, `workflow/phase_pr.ex:453-459`); a missing or unreadable file is `:none` too (`:44`). It is replaced by `parse/1` (artifact contents) and `read/1` (artifact path: `nil` is `:absent`, an unreadable file is `{:malformed, {:unreadable, reason}}`, never clean): the content between the existing markers (`<!-- FOREMAN_REVIEW_FINDINGS_START -->` and `..._END -->`) is one JSON document `{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [...]}` and each finding is `%Finding{severity (critical | major | minor | nitpick), path, line, description, disposition (fixed | declined | open), source}`; the result is `{:recorded, %Record{findings, artifact_sha256}}`, `:absent` (no markers: NOT clean), or `{:malformed, reason}` (unterminated markers, invalid JSON, unknown schema, an unknown severity or disposition, a missing field, a line that is not a positive integer or nil, a block over 32768 bytes or with more than 100 findings). `findings: []` with `reviewed: true` is the only clean outcome. Unresolved means `disposition: "open"`. A finding's description is at most 1000 characters. [satisfies REQ-002] (6h)
  - Validates PRD ACs: AC-002-1, AC-002-2
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/review_findings.ex`
  - Implementation AC:
    - [ ] Given a valid block, when `parse/1` runs, then it returns `{:recorded, record}` with typed findings and the artifact's SHA-256.
    - [ ] Given no markers, then it returns `:absent`; given an unterminated block, invalid JSON, an unknown schema, severity or disposition, or a missing field, then it returns `{:malformed, reason}` naming the defect.
    - [ ] Given `{"reviewed": true, "findings": []}`, then it returns a recorded empty record (the one clean outcome); given `findings: []` without `reviewed: true`, then it is malformed.
    - [ ] Given a `nil` artifact path, then `read/1` returns `:absent`; given a path that cannot be read, then `{:malformed, {:unreadable, reason}}` (never a clean record); given a block over 32768 bytes or with more than 100 findings, then it is malformed.
- [ ] **TRD-013-TEST**: Parser tests for recorded, absent, every malformed shape, and bounds. [verifies TRD-013] [satisfies REQ-002] [depends: TRD-013] (4h)
  - Validates PRD ACs: AC-002-1, AC-002-2
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/review_findings_test.exs`
  - Test AC:
    - [ ] Given `parse/1` returns a recorded empty record for an absent block, when the absent test runs, then it fails.
    - [ ] Given an unknown severity is accepted, when the malformed test runs, then it fails.
    - [ ] Given an unreadable artifact is read as absent-and-clean, when the unreadable test runs, then it fails.
- [ ] **TRD-014**: The review prompts and the PR body. `priv/defaults/workflows/prompts/review-coderabbit.md` (`:76-86`) and `review-repo-rules.md` (`:93-104`, and the carry-forward rule at `:66-74`) tell the agent to write the block; they now specify the JSON schema of TRD-013 (severity set, disposition from the triage choice the prompt already asks for at `review-repo-rules.md:45-52`, `reviewed: true` even when empty). `AutoPR.findings_section/1` (`workflow/auto_pr.ex:519-525`) and `PhasePR.findings_section/1` (`workflow/phase_pr.ex:453-459`) render the PR body from the typed record (a malformed block yields a body section naming the defect, an absent block says the review evidence is missing) through one shared renderer in `Workflow.ReviewFindings`, not two copies; `ReviewFindings.unterminated_section/1` and the two `unterminated_findings_section/1` copies (`auto_pr.ex:527-533`, `phase_pr.ex:461-467`) go with it. After editing the prompts, `foreman init --force` refreshes the installed copies (`AGENTS.md:24`). [satisfies REQ-002] [depends: TRD-013] (5h)
  - Validates PRD ACs: AC-002-1
  - Target Files: `packages/foreman_server/priv/defaults/workflows/prompts/review-coderabbit.md`, `packages/foreman_server/priv/defaults/workflows/prompts/review-repo-rules.md`, `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex`, `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex`, `packages/foreman_server/lib/foreman_server/workflow/review_findings.ex`
  - Implementation AC:
    - [ ] Given the two prompts, when they are read, then each states the JSON schema, the closed severity and disposition sets and that an empty review still emits `reviewed: true`.
    - [ ] Given a recorded block, when the PR body is built by `AutoPR` or `PhasePR`, then both render the same section from the typed record; given an absent or malformed block, then the body names the missing or malformed review evidence and does not say "no findings".
- [ ] **TRD-014-TEST**: Body rendering tests for both paths and a prompt-content test. [verifies TRD-014] [satisfies REQ-002] [depends: TRD-014] (3h)
  - Validates PRD ACs: AC-002-1
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/auto_pr_test.exs`, `packages/foreman_server/test/foreman_server/workflow/phase_pr_body_test.exs`, `packages/foreman_server/test/foreman_server/workflow/review_findings_test.exs`
  - Test AC:
    - [ ] Given the two bodies render different sections, when the shared-renderer test runs, then it fails.
    - [ ] Given an absent block renders as an empty section, when the absent-body test runs, then it fails.
- [ ] **TRD-015**: Record the findings against the reviewed head. New `ReviewFindingsRecorded` event (`run_id`, `pr_url`, `head_sha`, `status` (recorded | absent | malformed), `findings`, `defect`, `artifact_path`, `artifact_sha256`, `recorded_at`) and system command `run.pr.findings` on `PrWatch` (command list and event map, `pr_watch.ex:37-60`), validated strictly in the aggregate (closed sets, bounded lists), folded into `evidence.findings` by `PrEvidence`. `finalize_primary_pr/1` (`workflow/run_executor.ex:2570-2594`) reads the final artifact with TRD-013's `read/1` (`completion_artifact_path/1`, `:5931-5952`, the path `auto_pr_context/2` already passes as `artifact_path`, `:2805-2814`) and takes the run branch's local tip with `resolve_revision/2` (the call `signal_pr_ready/2` makes, `:2633`) before `maybe_auto_pr/1` pushes, so `head_sha` is the commit the review ran against; once the PR is associated and signalled ready it dispatches the command. `PrEvidence.evaluate/2` gains `findings_absent`, `findings_malformed` and `findings_other_sha` (the record's head against the PR's head as GitHub names it); an absent or malformed record is ineligible and carries the defect text for the operator. A run whose review phase produced no block therefore records `absent`, not clean. [satisfies REQ-002] [depends: TRD-013] [depends: TRD-008] [depends: TRD-011] (7h)
  - Validates PRD ACs: AC-002-1, AC-002-2
  - Target Files: `packages/foreman_server/lib/foreman_server/events/review_findings_recorded.ex`, `packages/foreman_server/lib/foreman_server/aggregates/run/pr_watch.ex`, `packages/foreman_server/lib/foreman_server/pr_evidence.ex`, `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`, `packages/foreman_server/lib/foreman_server/pr_watch_fold.ex`
  - Implementation AC:
    - [ ] Given a recorded block, when the run finalises, then `ReviewFindingsRecorded` is appended with the typed findings, `status: "recorded"` and the reviewed head, and the aggregate and projection hold the same `evidence.findings`.
    - [ ] Given an absent block, then a record with `status: "absent"` is appended and `evaluate/2` returns `findings_absent`; given a malformed block, then `status: "malformed"` with the defect and `findings_malformed`.
    - [ ] Given the PR head later differs from the record's head, then `evaluate/2` returns `findings_other_sha`.
    - [ ] Given a malformed payload on `run.pr.findings` (an unknown severity, an unbounded list), then the aggregate rejects it and nothing is appended.
    - [ ] Given a multi-repository run, then findings are recorded for the primary PR only, and a PR of another repository evaluates `findings_absent` until waived (§14).
- [ ] **TRD-015-TEST**: Findings record, fold parity, evaluator and finalize-path tests. [verifies TRD-015] [satisfies REQ-002] [depends: TRD-015] (5h)
  - Validates PRD ACs: AC-002-1, AC-002-2
  - Target Files: `packages/foreman_server/test/foreman_server/aggregates/run_pr_watch_test.exs`, `packages/foreman_server/test/foreman_server/pr_evidence_test.exs`, `packages/foreman_server/test/foreman_server/workflow/run_executor_pr_ready_test.exs`, `packages/foreman_server/test/foreman_server/projection_store_pr_watch_test.exs`
  - Test AC:
    - [ ] Given `absent` is recorded as a clean record, when the absent test runs, then `evaluate/2` is eligible and the test fails.
    - [ ] Given the record is bound to the PR's current head instead of the reviewed head, when the other-head test runs, then it fails.

### PR 6: Risk is a versioned, recorded classification bound to the head

**Shippable State:** For each head the run stream holds a risk record (HIGH, MEDIUM or LOW, `rubric_version`, rationale, evidence, unresolved findings, human-review instructions) computed by a deterministic rubric from machine-derived inputs, with a model judgement that can only raise the level; ambiguous, missing or malformed inputs give HIGH.

- [ ] **TRD-016**: Rubric v1, as a pure, table-driven module. `PrRisk.Rubric` holds the version (`"1"`), the proposed thresholds and the sensitive-path table (§11) as module attributes and `classify/1`, a pure function over `%Inputs{paths, changed_files, additions, deletions, sensitive_hits, checks, findings, base_branch, recorded_base, judgement}`, where `checks` is the check part of the evaluation (`PrEvidence.evaluate_checks/2`: status and reasons, never the findings or risk reasons that depend on the rubric's own output) and `findings` is the status and the unresolved counts by severity; it returns `%Result{level, rubric_version, rationale: [%{rule, level, detail}], instructions}`. The rules are the PRD §6 rules: the rule level is the maximum over all rules, the model level can only raise it (`max`), a missing, malformed, other-head or conflicting judgement is HIGH, and any input marked unavailable (changed paths incomplete, findings absent) is HIGH. A sensitive path matches by prefix, exact name, base name or a path segment from a closed table. Instructions are fixed text per rule (what a reviewer must look at), not model text. [satisfies REQ-003] [depends: TRD-011] [depends: TRD-015] (6h)
  - Validates PRD ACs: AC-003-2, AC-003-5
  - Target Files: `packages/foreman_server/lib/foreman_server/pr_risk/rubric.ex`
  - Implementation AC:
    - [ ] Given inputs with no HIGH or MEDIUM trigger and a LOW judgement for this head, then `classify/1` returns LOW with the rationale rules that held; given any single HIGH trigger of the PRD list, then HIGH naming the trigger.
    - [ ] Given a judgement LOWER than the rule level, then the result is the rule level (a model never lowers); given a judgement HIGHER, then the higher level.
    - [ ] Given a missing, malformed, other-head or conflicting judgement, or incomplete changed-path evidence, or absent findings, then HIGH.
    - [ ] Given the same inputs and the same version, then the result is identical, and `rubric_version` is part of the result.
- [ ] **TRD-016-TEST**: Exhaustive rule tests: one per HIGH trigger, MEDIUM triggers, LOW, raise-only, determinism. [verifies TRD-016] [satisfies REQ-003] [depends: TRD-016] (5h)
  - Validates PRD ACs: AC-003-2, AC-003-5
  - Target Files: `packages/foreman_server/test/foreman_server/pr_risk/rubric_test.exs`
  - Test AC:
    - [ ] Given a model judgement can lower the level, when the raise-only test runs, then it fails.
    - [ ] Given a sensitive path is dropped from the table, when its trigger test runs, then it fails.
    - [ ] Given an absent judgement is treated as neutral, when the missing-judgement test runs, then LOW is returned and it fails.
- [ ] **TRD-017**: The machine-derived inputs: changed paths and size. `@json_fields` (`github/pr_status.ex:131`) gains `files,changedFiles,additions,deletions`, so they come from the same `gh pr view` response as the head SHA and the checks (`:275`, `:321`); `PrStatus` carries `files` (`path`, `additions`, `deletions`), `changed_files`, `additions`, `deletions`, with `files_incomplete?` true when the list is shorter than `changedFiles` (probe: `gh pr view --json files` lists 100 of 223 files, §5). A malformed item is a typed `{:gh_unexpected_payload, item}`. The sensitive-path hits are computed by the rubric from the paths (TRD-016), never read from agent output. [satisfies REQ-003] [depends: TRD-006] (4h)
  - Validates PRD ACs: AC-003-1
  - Target Files: `packages/foreman_server/lib/foreman_server/github/pr_status.ex`
  - Implementation AC:
    - [ ] Given a response with `files`, `changedFiles`, `additions` and `deletions`, when `PrStatus.fetch/2` parses it, then the struct carries them and `files_incomplete?` is false when the counts agree and true when `changedFiles` exceeds the list.
    - [ ] Given a file item missing `path`, then the parse returns `{:error, {:gh_unexpected_payload, item}}`.
- [ ] **TRD-017-TEST**: `PrStatus` parsing tests with a 100-of-223 fixture. [verifies TRD-017] [satisfies REQ-003] [depends: TRD-017] (3h)
  - Validates PRD ACs: AC-003-1
  - Target Files: `packages/foreman_server/test/foreman_server/github/pr_status_test.exs`
  - Test AC:
    - [ ] Given `files_incomplete?` is computed from the list alone, when the truncated-list test runs, then it is false and the test fails.
- [ ] **TRD-018**: The risk record. New `PrRiskRecorded` event (`run_id`, `pr_url`, `head_sha`, `level`, `rubric_version`, `rationale`, `evidence` (check and findings summary, inputs digest), `unresolved_findings`, `instructions`, `judgement`, `digest`, `seq`, `recorded_at`) and system command `run.pr.risk` on `PrWatch`. The handler is deterministic: it takes only GitHub-derived facts from the payload (paths and counts from TRD-017, the PR's base branch) and the rest from aggregate state (the check part of the evaluation, `PrEvidence.evaluate_checks/2`; the findings and the model judgement held in `evidence.findings`; the run's recorded base, `State.base_branch`, set by `RunBaseBranchRecorded`, `aggregates/run.ex:411-421`), runs `PrRisk.Rubric.classify/1`, and appends the record only when its content digest differs from the stored record's (`{:ok, nil}` otherwise); a payload that carries its own `level` is rejected. The model judgement is one more typed marker block in the review artifact (`<!-- FOREMAN_RISK_JUDGEMENT_START -->` JSON `{"schema": "foreman.risk_judgement/1", "level", "rationale"}`, bounded), parsed by `PrRisk.parse_judgement/1` in `finalize_primary_pr/1` beside the findings and carried on `ReviewFindingsRecorded` (a new optional `judgement` field: `status` recorded, absent or malformed, `level`, `rationale`), so it is bound to the reviewed head; a judgement recorded for another head than the one being classified counts as missing. `PrObservation.commands/6` ends a batch with `run.pr.risk` (deterministic id carrying the head, the inputs digest and a sequence, as `checks_commands/5`, `pr_observation.ex:134-160`) whenever the batch carries `run.pr.update` or `run.pr.checks`, or the inputs digest differs from the record's; `finalize_primary_pr/1` dispatches it after `run.pr.findings`. `evaluate/2` gains `risk_missing` and `risk_other_sha`. [satisfies REQ-003] [depends: TRD-016] [depends: TRD-017] [depends: TRD-015] (7h)
  - Validates PRD ACs: AC-003-1, AC-003-2, AC-003-5
  - Target Files: `packages/foreman_server/lib/foreman_server/events/pr_risk_recorded.ex`, `packages/foreman_server/lib/foreman_server/events/review_findings_recorded.ex`, `packages/foreman_server/lib/foreman_server/pr_risk.ex`, `packages/foreman_server/lib/foreman_server/aggregates/run/pr_watch.ex`, `packages/foreman_server/lib/foreman_server/pr_watch_fold.ex`, `packages/foreman_server/lib/foreman_server/pr_observation.ex`, `packages/foreman_server/lib/foreman_server/pr_evidence.ex`, `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`, `packages/foreman_server/priv/defaults/workflows/prompts/review-repo-rules.md`, `packages/foreman_server/priv/defaults/workflows/prompts/review-coderabbit.md`
  - Implementation AC:
    - [ ] Given a head with GitHub-derived inputs, evidence and findings in state, when `run.pr.risk` is handled, then `PrRiskRecorded` carries the level, `rubric_version`, rationale, evidence, unresolved findings, instructions and the head SHA, and the level equals `Rubric.classify/1` over the same inputs.
    - [ ] Given a `run.pr.risk` payload carrying a `level`, or a judgement that is malformed, then the level in the record is HIGH (malformed) or the command is rejected (a supplied level); a judgement for another head is HIGH.
    - [ ] Given an observation that changes no input, then no new record is appended; given a changed input, then one is, with a higher `seq`.
    - [ ] Given a record for head H1 and a decision for H2, then `evaluate/2` returns `risk_other_sha`; given none, `risk_missing`.
    - [ ] Given `finalize_primary_pr/1` reads a review artifact with a valid risk-judgement block, then `ReviewFindingsRecorded.judgement` carries it for the reviewed head; given no block, then `status: "absent"`; given an invalid block, then `status: "malformed"`; given a judgement recorded for H1 and a classification of H2, then the judgement counts as missing and the level is HIGH.
    - [ ] Given an observation batch that carries `run.pr.update` or `run.pr.checks`, then it ends with `run.pr.risk`; given a batch with neither and an unchanged inputs digest, then it carries none.
    - [ ] Given the two review prompts, then each asks for the judgement block and says it can only raise the level.
- [ ] **TRD-018-TEST**: Record, determinism, supplied-level rejection, judgement carry-over, parity tests. [verifies TRD-018] [satisfies REQ-003] [depends: TRD-018] (5h)
  - Validates PRD ACs: AC-003-1, AC-003-2, AC-003-5
  - Target Files: `packages/foreman_server/test/foreman_server/aggregates/run_pr_watch_test.exs`, `packages/foreman_server/test/foreman_server/pr_risk_test.exs`, `packages/foreman_server/test/foreman_server/pr_risk/rubric_test.exs`, `packages/foreman_server/test/foreman_server/pr_observation_test.exs`, `packages/foreman_server/test/foreman_server/pr_evidence_test.exs`, `packages/foreman_server/test/foreman_server/workflow/review_findings_test.exs`
  - Test AC:
    - [ ] Given the handler trusts a payload `level`, when the supplied-level test runs, then a lower level is recorded and it fails.
    - [ ] Given the record is appended on every observation, when the no-change test runs, then it appends a duplicate and fails.
    - [ ] Given the judgement of an older head is reused, when the carry-over test runs, then the level is not HIGH and it fails.
    - [ ] Given the batch omits `run.pr.risk` after a checks change, when the batch test runs, then the record is stale and the test fails.

### PR 7: The report is published to the PR as a keyed, redacted, head-bound comment

**Shippable State:** When a head has a risk record, the PR receives one comment bound to that head and report digest; a new head edits the earlier comment instead of adding another; the comment is redacted and neutralised, a surviving secret blocks publication, posting it starts no further automation, and the publish effect is keyed by head SHA with a registered reconciler.

- [ ] **TRD-019**: The comment write and the report body. New `GitHub.PrComment` (`github/pr_comment.ex`), the first GitHub content write: `create/3` runs `gh pr comment <url> --body-file -` and returns the comment URL, `update/3` edits a comment by node id through `gh api graphql` (the `updateIssueComment` mutation), and `list/2` reads the PR's comments with their node id, URL, full body and `viewerDidAuthor` (`gh pr view --json comments`; probe: it returns those fields and pages through all 908 comments of kubernetes/kubernetes #18085); all through the injectable runner. `[UNVERIFIED]`: the write-side calls were not run for this TRD (`gh pr comment --help` documents `--body-file -`, gh 2.103.3), including that the node id `gh pr view` returns is accepted by the mutation and what `gh pr comment` prints on success; TRD-019's tests use a recorded fake and its PR runs each call once against a scratch PR. New `PrReport` renders the body from the typed risk record, the eligibility and the findings: the first line is a hidden marker `<!-- foreman:pr-report v1 run=<run_id> head=<head_sha> digest=<digest> -->` so it survives the 2000-character cut `PrStatus` applies to comment bodies (`github/pr_status.ex:134,535`), the text is built from closed fields, and every free-text field (finding description, model rationale, defect text) passes `Coordinator.Redact` with the project's secret values, is length-bounded, has HTML and markdown control characters escaped and `@` mentions neutralised (AC-003-4). Redaction is its own control: after rendering, `PrReport` re-scans the body for every project secret value above the minimum length and returns `{:error, :redaction_failed}` if one survives. [satisfies REQ-003] [depends: TRD-018] (6h)
  - Validates PRD ACs: AC-003-4, AC-003-3
  - Target Files: `packages/foreman_server/lib/foreman_server/github/pr_comment.ex`, `packages/foreman_server/lib/foreman_server/pr_report.ex`
  - Implementation AC:
    - [ ] Given a risk record, when `PrReport.render/2` runs, then the body starts with the marker line carrying the run, head and digest, and states the level, `rubric_version`, rationale, the evidence status with its reasons, the unresolved findings and the instructions.
    - [ ] Given a finding description containing a project secret value, an `@user`, HTML or a markdown fence, when the body is rendered, then the secret is redacted, the mention and markup are neutralised, and a secret value that still appears makes `render/2` return `{:error, :redaction_failed}`.
    - [ ] Given the injectable runner, then `create/3`, `update/3` and `list/2` build the documented `gh` arguments and return typed `{:ok, _}` or `{:error, reason}` results (a non-zero exit is an error, never success).
    - [ ] Given a `gh pr view --json comments` answer, when `list/2` parses it, then each comment carries `id`, `url`, `body` and `viewer_did_author`, and an item missing `id` or `body` is a typed `{:error, {:gh_unexpected_payload, item}}`.
- [ ] **TRD-019-TEST**: Renderer, redaction and neutralisation tests, the post-render scan, and `PrComment` argument tests with a fake runner. [verifies TRD-019] [satisfies REQ-003] [depends: TRD-019] (4h)
  - Validates PRD ACs: AC-003-4, AC-003-3
  - Target Files: `packages/foreman_server/test/foreman_server/pr_report_test.exs`, `packages/foreman_server/test/foreman_server/github/pr_comment_test.exs`
  - Test AC:
    - [ ] Given the redaction pass is skipped for finding descriptions, when the secret test runs, then the secret appears in the body and the test fails.
    - [ ] Given the post-render scan is removed, when a secret is injected after redaction, then `render/2` returns `{:ok, body}` and the test fails.
    - [ ] Given a non-zero `gh` exit is treated as success, when the write-error test runs, then it fails.
- [ ] **TRD-020**: The `pr_comment` effect class and its reconciler (P-1, P-4). `Idempotency.Effect` gains the class in `@required` (`idempotency/effect.ex:51-55`: `"pr_comment" => ["pr_url", "head_sha", "digest", "cwd"]`, `run_id` being checked separately) and the key `effect:pr_comment:<run_id>:<head_sha>:<digest>` (`Effect.key/3`, `:62`), so a new head or a new digest is a new effect and a settled key is not reused across heads. New `Reconcilers.PrComment` implements `Reconciler`: `reconcile/1` lists the PR's comments through `PrComment.list/2` and answers `:done` when a comment the token's own user wrote (`viewer_did_author`: a marker typed by anyone else proves nothing) carries the marker for this run, head and digest, `:not_done` when none does, `:unknown` for a failed or unparsable answer; it is registered in the reconciler registry (`config/config.exs:45-50`), because an unregistered class blocks the run `effect_class_unregistered` (`workflow/boot_reconciliation.ex:873,885`). The intent metadata carries the PR URL and the checkout directory. [satisfies REQ-003] [depends: TRD-019] [depends: TRD-002] (6h)
  - Validates PRD ACs: AC-003-3
  - Target Files: `packages/foreman_server/lib/foreman_server/idempotency/effect.ex`, `packages/foreman_server/lib/foreman_server/idempotency/reconcilers/pr_comment.ex`, `packages/foreman_server/config/config.exs`
  - Implementation AC:
    - [ ] Given the key for head H1 settled `completed`, when the same run publishes for head H2, then the key differs and the effect runs; given the same head and digest, then the key is the same.
    - [ ] Given a crash after the comment was posted and before the key settled, when the boot sweep asks the reconciler, then it answers `:done` (marker found) and the run blocks instead of posting again; given no marker, `:not_done` and the effect may run.
    - [ ] Given the class is not registered, then `Effect.run/4` for it is refused as today's unregistered path blocks the run (`effect_class_unregistered`); with the registry entry, it is reconciled.
    - [ ] Given a comment by another user that carries the same marker, when the reconciler runs, then it answers `:not_done` (only the token's own comments count).
- [ ] **TRD-020-TEST**: Key shape, reconciler verdicts (`done`, `not_done`, `unknown`), registry and crash-on-each-side tests. [verifies TRD-020] [satisfies REQ-003] [depends: TRD-020] (4h)
  - Validates PRD ACs: AC-003-3
  - Target Files: `packages/foreman_server/test/foreman_server/idempotency/reconcilers/pr_comment_test.exs`, `packages/foreman_server/test/foreman_server/idempotency/effect_test.exs`, `packages/foreman_server/test/foreman_server/workflow/boot_reconciliation_effect_keys_test.exs`
  - Test AC:
    - [ ] Given the key omits the head SHA, when the cross-head test runs, then the second head finds a settled key and does not publish, and the test fails.
    - [ ] Given the reconciler answers `:not_done` when the marker exists, when the crash-after-post test runs, then a second comment is posted and it fails.
    - [ ] Given the reconciler accepts a marker on another user's comment, when the foreign-marker test runs, then it answers `:done` and the test fails.
- [ ] **TRD-021**: The publisher, the supersede rule and the feedback-loop guard. New `PrReport.Publisher` is a `ProjectionStore` subscriber (like `Review.Analyzer`, `review/analyzer.ex:111`, and `PrWatcher`, `pr_watcher.ex:119`, both `subscribe(replay_existing: false)`) started after `PrWatcher` in the supervision tree (`application.ex:733-735`) and off in the test environment (`config/test.exs:87` is the pattern); it reacts to `PrRiskRecorded` only, for a project whose `required_checks` is set (publication follows the gate switch, §11), never to comment, review or webhook events. The subscription loses events appended while the server is down, so `init/1` subscribes first and then scans the gated projects' PRs for a risk record with no matching report and publishes those (subscribe-then-scan, as `Coordinator.SetupProposer` does, `coordinator/setup_proposer.ex:9-13`). It renders (TRD-019), runs the keyed effect (TRD-020): if a Foreman comment (marker and `viewer_did_author`) for an earlier head exists it edits that comment (`update/3`) so the PR carries one report that names its head, otherwise it creates one; it then dispatches system command `run.pr.comment_published` recording `PrCommentPublished` (`run_id`, `pr_url`, `head_sha`, `digest`, `comment_id`, `comment_url`, `superseded`, `published_at`) folded into `evidence.report`. A refused publish (`redaction_failed`, an unresolved or undecided key, a `gh` failure) is recorded with its reason and leaves the PR ineligible for nothing: the gate does not depend on the comment. Feedback guard: a posted comment reaches `PrWatcher.refresh` through the `issue_comment` webhook (`webhooks/github.ex:135-141`) and would move the review digest, so `PrObservation.comment_ids/1` (`pr_observation.ex:75-79`, which already skips bot-authored comments) also skips a comment whose body starts with the Foreman marker and that the token's own user wrote (`PrStatus` comments gain `viewer_did_author`, from the `viewerDidAuthor` field `gh pr view --json comments` returns; a marker typed by someone else hides nothing); the risk record is appended only on a changed digest (TRD-018) and the effect is keyed by head and digest, so a re-delivered event posts nothing. A changed head invalidates the old report: the displayed `evidence.report` is for another head until the new one is published (TRD-023 shows it as stale). [satisfies REQ-003] [depends: TRD-019] [depends: TRD-020] [depends: TRD-018] (7h)
  - Validates PRD ACs: AC-003-3
  - Target Files: `packages/foreman_server/lib/foreman_server/pr_report/publisher.ex`, `packages/foreman_server/lib/foreman_server/events/pr_comment_published.ex`, `packages/foreman_server/lib/foreman_server/aggregates/run/pr_watch.ex`, `packages/foreman_server/lib/foreman_server/pr_watch_fold.ex`, `packages/foreman_server/lib/foreman_server/pr_evidence.ex`, `packages/foreman_server/lib/foreman_server/pr_observation.ex`, `packages/foreman_server/lib/foreman_server/github/pr_status.ex`, `packages/foreman_server/lib/foreman_server/application.ex`, `packages/foreman_server/config/test.exs`
  - Implementation AC:
    - [ ] Given a `PrRiskRecorded` for head H1 on a gated project, when the publisher handles it, then one comment bound to H1 and its digest is created and `PrCommentPublished` is appended; given the same event delivered again, then no second comment is posted.
    - [ ] Given a new head H2 with a new risk record, when the publisher handles it, then the earlier Foreman comment is edited to the H2 report (no second comment) and `superseded` names the earlier head.
    - [ ] Given a project with `required_checks` unset, then nothing is posted.
    - [ ] Given a comment that starts with the Foreman marker and was written by the token's own user appears on the PR, when the next observation runs, then `comment_ids` does not include it, `review_digest` is unchanged and no `run.pr.review` is emitted for it; given a comment by another user that starts with the marker, then `comment_ids` includes it.
    - [ ] Given the redaction control refuses, then no comment is posted, `PrCommentPublished` is not appended and the refusal is recorded with the reason.
    - [ ] Given the server restarts after a risk record was appended and before its comment was posted, when the publisher starts, then it publishes that report once.
- [ ] **TRD-021-TEST**: Publisher tests (create, supersede, redelivery, ungated project, refusal) and the feedback-loop test with a fake `gh` runner and a webhook delivery. [verifies TRD-021] [satisfies REQ-003] [depends: TRD-021] (5h)
  - Validates PRD ACs: AC-003-3
  - Target Files: `packages/foreman_server/test/foreman_server/pr_report/publisher_test.exs`, `packages/foreman_server/test/foreman_server/pr_observation_test.exs`, `packages/foreman_server/test/foreman_server/github/pr_status_test.exs`, `packages/foreman_server/test/foreman_server/webhooks/github_test.exs`
  - Test AC:
    - [ ] Given the publisher reacts to comment events as well, when the feedback-loop test delivers the webhook for its own comment, then a second publish is attempted and the test fails.
    - [ ] Given a new head creates a second comment, when the supersede test runs, then the PR has two Foreman comments and it fails.
    - [ ] Given `comment_ids` includes the marker comment, when the digest test runs, then `review_digest` changes and it fails.
    - [ ] Given the guard skips every comment that starts with the marker whatever its author, when the foreign-marker test runs, then another user's comment is not counted and the test fails.
    - [ ] Given the start-up scan is removed, when the restart test runs, then no comment is posted and the test fails.

### PR 8: Approval is gated on current-head evidence, and the status is visible everywhere

**Shippable State:** With a project's gate on, `merge_approve` is refused with a typed reason unless the evidence for the current head is eligible or waived, decided in the aggregate from folded state after the gateway recorded a fresh observation of the named head; the status DTO, HTTP, MCP, CLI and dashboard show checks, stale or missing evidence, findings, the risk rationale, the reasons and the next actions with the head and policy version; the dashboard can reset blocked and paused runs; an unreadable projection shows `unknown`.

- [ ] **TRD-022**: The gate. `merge_approve` (`aggregates/run.ex:936-967`) gains one step after `validate_approval/1`: `PrEvidence.evaluate/2` over the record of the PR the gate holds (`Run.merge_pin/2`, `run.ex:119`, names the `pr_url`; the record is `state.pr_watch[pr_url]`) decided for `approval.head_sha`; `:eligible`, `:waived` and `:off` proceed, `:ineligible` and `:unknown` return `{:error, {:evidence_ineligible, head_sha, codes}}` and append nothing. The handler reads only aggregate state, so it stays deterministic and network-free. Freshness is the gateway's job: `perform_operator_side_effects/1` for `merge_approve` (`command_gateway.ex:250-259`) already reads GitHub through `RunPrMerge.verify_head/3` (`run_pr_merge.ex:74-98`: one `PrStatus.fetch/2` without review threads); `verify_head/3` now returns the `PrStatus` it compared, and for a project with the gate on the gateway derives the observation commands from it (`PrObservation.commands/6`) and dispatches the `run.pr.update`, `run.pr.checks` and `run.pr.risk` commands of that batch through `dispatch_system/2` (never `run.pr.review`, which needs the review threads this read does not fetch, `pr_watcher/observer.ex:82-84`) before `merge_approve` is dispatched, so the aggregate decides on evidence recorded from the same response that proves the named head. A failed dispatch refuses the approval (fail closed). The guard of TRD-005 is applied again at approval for a gated project. A project with the gate off is unchanged: approval behaves exactly as today. [satisfies REQ-001] [satisfies REQ-004] [depends: TRD-011] [depends: TRD-012] [depends: TRD-015] [depends: TRD-018] (7h)
  - Validates PRD ACs: AC-001-2, AC-002-2, AC-004-1
  - Target Files: `packages/foreman_server/lib/foreman_server/aggregates/run.ex`, `packages/foreman_server/lib/foreman_server/command_gateway.ex`, `packages/foreman_server/lib/foreman_server/run_pr_merge.ex`
  - Implementation AC:
    - [ ] Given a gated project, a pending gate and ineligible evidence for the named head (a required check failing, missing or pending, findings absent or malformed, no risk record), when `merge_approve` is dispatched, then it is refused with `{:evidence_ineligible, head_sha, codes}` naming every reason and no `MergeGateApproved` is appended.
    - [ ] Given eligible evidence, or a waiver at the same head covering every reason, then the approval is recorded as today with the head pinned.
    - [ ] Given the gate is off (`required_checks` unset), then `merge_approve` behaves exactly as before this change.
    - [ ] Given the PR head moved since the last observation, when the operator approves the new head, then the gateway's fresh observation records evidence for it first and the decision uses that evidence; given the GitHub read fails, then the approval is refused as today.
    - [ ] Given the handler, then it performs no network read and no ETS or GenServer call other than the existing `PrGate` bookkeeping.
    - [ ] Given the fresh observation of a gated approval, then the dispatched batch holds `run.pr.update`, `run.pr.checks` and `run.pr.risk` commands only, never `run.pr.review`.
- [ ] **TRD-022-TEST**: Gate tests in the aggregate (every reason, waived, off), the gateway test with a fake `gh` runner for the fresh-observation path, and a determinism test (replay yields the same refusal). [verifies TRD-022] [satisfies REQ-001] [satisfies REQ-004] [depends: TRD-022] (6h)
  - Validates PRD ACs: AC-001-2, AC-002-2, AC-004-1
  - Target Files: `packages/foreman_server/test/foreman_server/aggregates/run_test.exs`, `packages/foreman_server/test/foreman_server/aggregates/run_multi_gate_test.exs`, `packages/foreman_server/test/foreman_server/command_gateway_test.exs`, `packages/foreman_server/test/foreman_server/run_pr_merge_test.exs`, `packages/foreman_server/test/foreman_server/pr_merge_gate_invariant_test.exs`
  - Test AC:
    - [ ] Given the handler skips the evaluator, when the ineligible-evidence test runs, then `MergeGateApproved` is appended and the test fails.
    - [ ] Given the gateway does not record the fresh observation, when the moved-head test runs, then the decision uses the old head's evidence and the test fails.
    - [ ] Given a gate-off project is refused, when the unchanged-behaviour test runs, then it fails.
- [ ] **TRD-023**: The status read model, with `unknown`. `PrWatch.DTO` (`pr_watch/dto.ex:17-51,81-99`) gains `head_sha` (existing), `eligibility` (`status`, `reasons`, `waived`, `policy_version`, `evaluated_at`), `checks` (the evidence items with `head_sha` and `stale`), `findings`, `risk` (level, `rubric_version`, rationale, instructions), `waiver`, `report` (published head, digest, comment URL, `stale` when it is for another head), `delivery_issue` and `next_actions` (typed, from the reasons: fix CI, re-run review, waive, publish, reset), all computed by `PrEvidence.evaluate/2` over the projection record, the same function the aggregate uses. `foreman_pr_status` (`mcp/tools.ex:1252-1261,1482-1490`) and `GET /api/runs/:id/prs` (`foreman_server_web/controllers/run_controller.ex:54-64`) return the DTO unchanged; the tool text avoids the words merge and approve (`mcp/no_merge_tool_test.exs`). Unreadable means `unknown`, never clean (AC-005-3): `fetch/1` makes three `ProjectionStore` calls (`dto.ex:61-70`) that exit when the store is down, so it catches the exit and returns `{:error, {:projection_unavailable, reason}}`, which the controller answers with 503 and the tool with an `UNAVAILABLE` error, and a record whose evidence cannot be read evaluates to `status: "unknown"` with the reason `evidence_unreadable`. Fold-in of `foreman-87h5g`: `ProjectionStore.init/1` (`projection_store.ex:1240-1243`) calls `rebuild_from_event_log/1` (`:2184-2189`), which returns `initial_state()` when the event-log read fails and so serves an empty read model as if nothing had happened; `init/1` now stops with `{:event_log_read_failed, reason}` (the runtime `{:rebuild, ...}` path already replies the error and keeps its state, `:1573-1587`), and an `init_arg` option `:event_log_reader` beside `:now_ms` (`:5666-5673`) makes the failed read testable. [satisfies REQ-005] [depends: TRD-022] [depends: TRD-021] (7h)
  - Validates PRD ACs: AC-005-1, AC-005-2, AC-005-3
  - Target Files: `packages/foreman_server/lib/foreman_server/pr_watch/dto.ex`, `packages/foreman_server/lib/foreman_server_web/controllers/run_controller.ex`, `packages/foreman_server/lib/foreman_server/projection_store.ex`, `packages/foreman_server/lib/foreman_server/mcp/tools.ex`, `packages/foreman_server/lib/foreman_server/pr_evidence.ex`
  - Implementation AC:
    - [ ] Given a watched PR, when the DTO is built, then it shows the checks of the head with their times, the eligibility with its typed reasons and `policy_version`, the findings, the risk record with `rubric_version`, the waiver, the published report and the next actions, all for the current head; evidence recorded for another head is labelled stale and is never shown as the current head's.
    - [ ] Given the DTO and the aggregate evaluate the same record, then they return the same eligibility (a parity test).
    - [ ] Given the event-log read fails at boot, then the projection does not start empty: it stops with `{:event_log_read_failed, reason}`; given a malformed evidence record, then the DTO reports `unknown` with the cause.
    - [ ] Given `ProjectionStore` does not answer, when `GET /api/runs/:id/prs` or `foreman_pr_status` is called, then the response is a typed `projection_unavailable` error (HTTP 503, a tool error), never an empty PR list.
    - [ ] Given `Tools.list_tools/0`, then no tool name or description contains merge or approve.
- [ ] **TRD-023-TEST**: DTO shape, aggregate-DTO parity, stale labelling, the failed-boot-read test (the path `foreman-87h5g` names) and the MCP/HTTP readers. [verifies TRD-023] [satisfies REQ-005] [depends: TRD-023] (5h)
  - Validates PRD ACs: AC-005-1, AC-005-2, AC-005-3
  - Target Files: `packages/foreman_server/test/foreman_server/pr_watch_dto_test.exs`, `packages/foreman_server/test/foreman_server/projection_store_restart_test.exs`, `packages/foreman_server/test/foreman_server/mcp/pr_tools_test.exs`, `packages/foreman_server/test/foreman_server_web/controllers/run_controller_prs_test.exs`, `packages/foreman_server/test/foreman_server/mcp/no_merge_tool_test.exs`
  - Test AC:
    - [ ] Given the DTO shows the previous head's checks as the current head's, when the head-change test runs, then it fails.
    - [ ] Given the projection still starts empty on a failed read, when the boot-read test runs, then it fails.
    - [ ] Given a malformed record renders as eligible, when the unknown test runs, then it fails.
    - [ ] Given `fetch/1` returns an empty PR list when the store is down, when the unavailable test runs, then it fails.
- [ ] **TRD-024**: Dashboard, Overview and the reset fold-in. `foreman run prs <id>` prints the DTO JSON unchanged (`runPrs`, `foreman_cli/cmd/foreman/run.go:378-394`: one GET of `/api/runs/<id>/prs` through `printJSON`), so the eligibility, reasons, next actions, head and policy version of TRD-023 reach the CLI without a Go change, and TRD-023's HTTP test pins the shape. The thread's PR line (`foreman_server_web/workspace/components.ex:1289`) and the Overview PR row (`overview/tabs/pull_requests.ex:49-65`) show the gate status and the reason codes; the row reads the run's `pr_watch` record (`ProjectionStore.pr_watch/1`) and `PrEvidence.evaluate/2`. `Overview.Group.classify/1` (`overview/group.ex:130-159`) puts a gated PR whose evidence is ineligible or unknown under waiting on you with a new reason `:evidence_blocked`, placed before `:pr_ready` (`:151`); the reason joins `@reasons` and `@type reason` (`:58-115`), the card text (`components.ex:728` is the `:ci_failing` line) and a new `Overview.Input` field (`overview/input.ex:34-50`) that `Overview.input/5` (`overview.ex:295-315`) fills from the head run's watch records (`watch_records/2`, `:321-325`, which already reads `ProjectionStore.pr_watch/1` for live PRs). Fold-in of `foreman-rsbx1`: `OperatorDashboard.actions_for_status/1` (`foreman_server_web/operator_dashboard.ex:158-170`) enables `run.reset` for `blocked` and `paused` runs as the aggregate already accepts them (`aggregates/run.ex:1432-1436`), so a run blocked by effect recovery has a dashboard exit. [satisfies REQ-005] [depends: TRD-023] (6h)
  - Validates PRD ACs: AC-005-1
  - Target Files: `packages/foreman_server/lib/foreman_server_web/workspace/components.ex`, `packages/foreman_server/lib/foreman_server/overview/tabs/pull_requests.ex`, `packages/foreman_server/lib/foreman_server/overview/group.ex`, `packages/foreman_server/lib/foreman_server/overview/input.ex`, `packages/foreman_server/lib/foreman_server/overview.ex`, `packages/foreman_server/lib/foreman_server_web/operator_dashboard.ex`
  - Implementation AC:
    - [ ] Given a PR with ineligible evidence, then the thread's PR line and the Overview PR row show the gate status and each reason code; given the gate off, then they show what they show today.
    - [ ] Given a gated PR with ineligible evidence, then `Overview.Group.classify/1` returns waiting on you with `:evidence_blocked`; given eligible evidence, `:pr_ready` as before; given the gate off, unchanged.
    - [ ] Given a `blocked` or a `paused` run, then the dashboard enables reset; given a `completed` run, then it does not (the aggregate refuses it).
- [ ] **TRD-024-TEST**: `Overview.Group`, tab, workspace-card and dashboard action-matrix tests. [verifies TRD-024] [satisfies REQ-005] [depends: TRD-024] (4h)
  - Validates PRD ACs: AC-005-1
  - Target Files: `packages/foreman_server/test/foreman_server/overview/group_test.exs`, `packages/foreman_server/test/foreman_server/overview/tabs_test.exs`, `packages/foreman_server/test/foreman_server_web/live/project_workspace_live_test.exs`, `packages/foreman_server/test/foreman_server_web/operator_dashboard_test.exs`
  - Test AC:
    - [ ] Given reset stays disabled for `blocked`, when the action-matrix test runs, then it fails.
    - [ ] Given the PR line omits the gate status, when the workspace test runs, then it fails.

### PR 9: The adversarial suite passes, the exit record is filed and the documentation matches the code

**Shippable State:** The adversarial suite covers missing results, spoofed and stale results, head changes after approval and after publish, and re-runs per head, and passes against the real aggregate, gateway and publisher; a decision-style exit record states pass or fail per PRD criterion with source and test evidence and the remaining gaps; the operator documentation describes every identifier Phase 1 added.

- [ ] **TRD-025**: The adversarial suite (PRD §5 exit rule, REQ-004), driven through the real `CommandGateway`, `Aggregates.Run` and `PrReport.Publisher` with an injected `gh` runner. Scenarios: a required check missing from the rollup; a check present for another head; a status context named like a required `check_run` entry (spoof by name and kind); a passing check of another workflow name; an agent-written artifact claiming "all tests passed" with no GitHub result; a stale result left after a fix push; a head change after approval (approval void, `merge_approve` for the new head needs fresh evidence); a head change after publish (the old report stays for the old head and is edited for the new one); a re-run per head (the same check re-run changes `completed_at` and the digest); `merge_approve` and `run.pr.merge` still refuse without an approval pinned to the current head (REQ-004); a waiver for head H1 never covers H2; a worker-forged `run.pr.risk` with a lower level. Each scenario asserts the typed reason, not only that it was refused. [satisfies REQ-004] [satisfies REQ-001] [satisfies REQ-003] [depends: TRD-022] [depends: TRD-021] [depends: TRD-024] (8h)
  - Validates PRD ACs: AC-001-2, AC-001-4, AC-004-1, AC-004-2, AC-003-3
  - Target Files: `packages/foreman_server/test/foreman_server/pr_delivery_adversarial_test.exs`, `packages/foreman_server/test/support/pr_delivery_world.ex`
  - Implementation AC:
    - [ ] Given each scenario above, when the suite runs, then each ends in the typed reason named for it and the approval or publication it targets does not happen.
    - [ ] Given `merge_approve` is attempted without evidence for the current head, with a stale approval, and with a waiver for another head, then each is refused and the gate stays pending.
    - [ ] Given a head change after publish, then exactly one Foreman comment exists and it is bound to the new head.
- [ ] **TRD-025-TEST**: Mutation probes of the suite: with each guard reverted in a scratch copy, the matching scenario must go red (recorded in the PR description). [verifies TRD-025] [satisfies REQ-004] [depends: TRD-025] (4h)
  - Validates PRD ACs: AC-004-1, AC-004-2
  - Target Files: `packages/foreman_server/test/foreman_server/pr_delivery_adversarial_test.exs`
  - Test AC:
    - [ ] Given the evaluator is bypassed in the `merge_approve` handler, when the suite runs, then the missing-result, spoof and stale scenarios fail.
    - [ ] Given the fold stops resetting evidence on a head change, when the suite runs, then the head-change scenarios fail.
    - [ ] Given the Foreman marker is not excluded from `comment_ids`, when the suite runs, then the feedback scenario fails.
- [ ] **TRD-026**: The exit record. Write `docs/decisions/phase-1-trustworthy-pr-delivery-exit.md` in the house format of `docs/decisions/project-delete.md` and of the Phase 0 record: a table of every PRD criterion (18) with source evidence, test evidence, a pass, caveat or fail result and the remaining gaps (the gaps TRD §14 lists, the unverified `gh` write calls, the thresholds the operator confirmed or not); the operator's confirmation state for each open decision of §11; and the statement Phase 2's PRD needs ("Phase 1 exit criteria are fully met" holds, or which do not). It is an output of the other tasks and is written last but one. [satisfies REQ-004] [depends: TRD-025] (4h)
  - Validates PRD ACs: none (an exit record; PRD §5 exit criteria)
  - Target Files: `docs/decisions/phase-1-trustworthy-pr-delivery-exit.md`
  - Implementation AC:
    - [ ] Given the record, when each of the 18 criteria is read, then it names source and test evidence and a result, and a criterion not fully met says why.
    - [ ] Given the open decisions of §11, then the record states what the operator decided or that it is pending.
- [ ] **TRD-026-TEST**: A reviewer checklist in the PR description: every path and test cited exists; every criterion row has a result. [verifies TRD-026] [satisfies REQ-004] [depends: TRD-026] (1h)
  - Validates PRD ACs: none (a reviewer checklist)
  - Target Files: `docs/decisions/phase-1-trustworthy-pr-delivery-exit.md`
  - Test AC:
    - [ ] Given a cited path does not exist, when the reviewer applies the checklist, then the item names it and fails.
- [ ] **TRD-027**: Documentation gate. Document the identifiers this TRD adds in each of the four files that describes the surface they belong to (`docs/user-guide.md`, `docs/cli-reference.md`, `CLAUDE.md`, `README.md`) and record the gate mechanics in `docs/lessons/phase-execution-and-pr-mechanics.md`. `docs/cli-reference.md` already holds a minimal entry for the verb and the flag (TRD-012 and TRD-010 add them because `usage_drift_test.go` fails without the verb entry, `:181-201`); this task completes them. Identifiers: the setting `required_checks` (`project.update`, `foreman project update --required-checks`, the `foreman_project_settings_update` MCP refusal); the commands `run.pr.waive_evidence` (operator), `run.pr.findings`, `run.pr.risk`, `run.pr.comment_published` and `run.pr.ready_failed` (system); the CLI verb `foreman run waive-evidence` and the new fields in the output of `foreman run prs`; the events `PrEvidenceWaived`, `ReviewFindingsRecorded`, `PrRiskRecorded`, `PrCommentPublished`, `PrReadyFailed` and the new optional fields of `PrChecksChanged`; the effect class `pr_comment` and its key; the reason codes (`no_checks_configured`, `missing`, `failing`, `pending`, `stale`, `other_sha`, `findings_absent`, `findings_malformed`, `findings_other_sha`, `risk_missing`, `risk_other_sha`, `evidence_unreadable`); the refusals `{:evidence_ineligible, head, codes}`, `{:effect_undecided, key}`, `{:store_not_durable, note}`, `{:operator_only_setting, :required_checks}` and `redaction_failed`, and the `projection_unavailable` answer and the `{:event_log_read_failed, reason}` boot stop; the marker blocks `FOREMAN_REVIEW_FINDINGS` (JSON content now) and `FOREMAN_RISK_JUDGEMENT` and the comment marker `foreman:pr-report`; the DTO fields; the config switch `:require_durable_store_for_gating`; the doctor lines (`pr_observation`, the Phase 1 gating line, started keys in the effect-key list); the Overview reason `evidence_blocked`; the dashboard reset for blocked and paused runs. The same PR corrects the stale sentence at `docs/lessons/phase-execution-and-pr-mechanics.md:641-643` (a run whose PRs are all `stack_pr` phase PRs does reach the gate: `maybe_auto_pr/1` returns the phase PR as the run's PR, `workflow/run_executor.ex:2659-2683`). The PR description states, for each of the four files, the identifiers added or why the file does not describe the surface, and verifies every CLI, MCP and HTTP name against source (`foreman_cli/cmd/foreman/main.go`, `mcp/tools.ex`, the router), never against `docs/cli-reference.md`. [satisfies REQ-004] [depends: TRD-026] (4h)
  - Validates PRD ACs: none (the documentation gate)
  - Target Files: `docs/user-guide.md`, `docs/cli-reference.md`, `CLAUDE.md`, `README.md`, `docs/lessons/phase-execution-and-pr-mechanics.md`
  - Implementation AC:
    - [ ] Given an added identifier from the list, when one of the four files describes the surface it belongs to, then it is documented there; a file that does not describe the surface needs no edit and the PR description says so.
    - [ ] Given the documented limitations, then the documentation states what the gate does NOT do (the gate is per project and off by default; a waiver covers only the waivable reasons; the monitor or webhook is needed to see a head change without approving).
    - [ ] Given the TRD-027 Target Files, when PR 9 lands, then it touches documentation only; `docs/PRD/*` and `docs/TRD/*` are not edited.
- [ ] **TRD-027-TEST**: A reviewer checklist in the PR description: for each identifier in TRD-027's list, the description names the file or files documenting it, and for each of the four files either that or why not. [verifies TRD-027] [satisfies REQ-004] [depends: TRD-027] (1h)
  - Validates PRD ACs: none (a reviewer checklist for the documentation gate)
  - Target Files: `docs/user-guide.md`
  - Test AC:
    - [ ] Given a new setting is documented in none of the four files that describe its surface, when the reviewer applies the checklist, then the item fails and the PR is returned for correction.

## Files this TRD creates

Declared once here so every `Target Files:` line stays a bare path. Paths are relative to the repository root.

- `docs/decisions/phase-1-trustworthy-pr-delivery-exit.md`
- `packages/foreman_server/lib/foreman_server/events/pr_comment_published.ex`
- `packages/foreman_server/lib/foreman_server/events/pr_evidence_waived.ex`
- `packages/foreman_server/lib/foreman_server/events/pr_ready_failed.ex`
- `packages/foreman_server/lib/foreman_server/events/pr_risk_recorded.ex`
- `packages/foreman_server/lib/foreman_server/events/review_findings_recorded.ex`
- `packages/foreman_server/lib/foreman_server/github/pr_comment.ex`
- `packages/foreman_server/lib/foreman_server/github/pr_lookup.ex`
- `packages/foreman_server/lib/foreman_server/idempotency/reconcilers/pr_comment.ex`
- `packages/foreman_server/lib/foreman_server/pr_evidence.ex`
- `packages/foreman_server/lib/foreman_server/pr_report.ex`
- `packages/foreman_server/lib/foreman_server/pr_report/publisher.ex`
- `packages/foreman_server/lib/foreman_server/pr_risk.ex`
- `packages/foreman_server/lib/foreman_server/pr_risk/rubric.ex`
- `packages/foreman_server/test/foreman_server/github/pr_comment_test.exs`
- `packages/foreman_server/test/foreman_server/github/pr_lookup_test.exs`
- `packages/foreman_server/test/foreman_server/idempotency/effect_undecided_test.exs`
- `packages/foreman_server/test/foreman_server/idempotency/reconcilers/pr_comment_test.exs`
- `packages/foreman_server/test/foreman_server/pr_delivery_adversarial_test.exs`
- `packages/foreman_server/test/foreman_server/pr_evidence_test.exs`
- `packages/foreman_server/test/foreman_server/pr_report/publisher_test.exs`
- `packages/foreman_server/test/foreman_server/pr_report_test.exs`
- `packages/foreman_server/test/foreman_server/pr_risk/rubric_test.exs`
- `packages/foreman_server/test/foreman_server/pr_risk_test.exs`
- `packages/foreman_server/test/foreman_server/pr_watch_dto_test.exs`
- `packages/foreman_server/test/foreman_server/workflow/auto_pr_block_reset_resume_test.exs`
- `packages/foreman_server/test/support/pr_delivery_world.ex`

## Deferred (explicitly not in this plan)

- **Auto-merge** (Phase 2): every merge stays operator-approved and SHA-pinned; the evidence, risk record and eligibility are the inputs Phase 2 will read.
- **Server-run command checks** (decision B in §6): not in the first release. They would run project code in a checkout of the head on a host whose filesystem and network the Phase 0 execution profile records as unenforced.
- **Sweep ordering before executors resume** (the third item of `foreman-by6nl`): with TRD-002 an executor that reaches an undecided key is refused, so the order is a liveness matter and is not built (TRD-003).
- **Operator clearing of a refused effect key for a completed, cancelled or deleted run** (decision record limitation (xix)): unchanged.
- **Authenticated approver login**: the approver identity stays a claim checked against `ApproverAuthorizer`'s list.
- **Out-of-order observations** that rewind the head of record: fail-safe today (a refusal or a re-hold), not fixed here (§14).
- **Independent follow-up beads** (`foreman-6vlx6`, `foreman-t2627`, `foreman-p7asb`, `foreman-f6zmv` and `foreman-l30ao`, the ones the decision record cites): open in `.beads/issues.jsonl` on 2026-11-12 (read with `jq`) and not on a Phase 1 path.
- **Findings for the PRs a multi-repository run opens in other repositories**: recorded for the primary PR only (TRD-015); the other PRs read `findings_absent` until waived.

## 9. Sprint Planning

Informational only; `implement-trd-beads` does not parse this section. Hours per PR (implementation plus test): PR 1 4h (2 tasks), PR 2 39h (8), PR 3 39h (8), PR 4 35h (6), PR 5 30h (6), PR 6 30h (6), PR 7 32h (6), PR 8 35h (6), PR 9 22h (6); total 266h. The longest dependency chain, computed from `trd-cli parse`, is 100h over 17 tasks: TRD-006, 007, 009, 010, 011, 015, 016, 018, 019, 020, 021, 023, 024, 025, 026, 027, 027-TEST. PR 2 (the preconditions) does not lie on it: TRD-005 joins the chain only at TRD-010, so PR 2 and PR 3 can be built in parallel and merged in stack order; PR 5 (TRD-013, TRD-014) can start after PR 2 and before PR 4 lands, because TRD-015 is the first task that needs the evaluator.

## 10. Acceptance Criteria Traceability

Every PRD criterion has at least one implementation task and one test task (parse check: 18 of 18 covered, 5 of 5 requirements satisfied). Tasks that carry no PRD criterion are verified by inspection or by their own tests: TRD-001 (decision-record edit), TRD-002 to TRD-004 (preconditions P-1 and P-2), TRD-026 (exit record) and TRD-027 (documentation gate), with their `-TEST` siblings.

| Requirement | Implementation tasks |
|---|---|
| REQ-001 | 001 to 008, 010, 011, 012, 022, 025 |
| REQ-002 | 013, 014, 015 |
| REQ-003 | 016 to 021, 025 |
| REQ-004 | 022, 025, 026, 027 |
| REQ-005 | 007, 008, 009, 023, 024 |

| PRD criterion | Implementation | Test |
|---|---|---|
| AC-001-1 | 006, 007, 008 | 006-TEST, 007-TEST, 008-TEST |
| AC-001-2 | 011, 022, 025 | 011-TEST, 022-TEST |
| AC-001-3 | 011, 012 | 011-TEST, 012-TEST |
| AC-001-4 | 006, 010, 025 | 006-TEST, 010-TEST |
| AC-001-5 | 012 | 012-TEST |
| AC-001-6 | 005, 010 | 005-TEST, 010-TEST |
| AC-002-1 | 013, 014, 015 | 013-TEST, 014-TEST, 015-TEST |
| AC-002-2 | 013, 015, 022 | 013-TEST, 015-TEST, 022-TEST |
| AC-003-1 | 017, 018 | 017-TEST, 018-TEST |
| AC-003-2 | 016, 018 | 016-TEST, 018-TEST |
| AC-003-3 | 019, 020, 021, 025 | 019-TEST, 020-TEST, 021-TEST |
| AC-003-4 | 019 | 019-TEST |
| AC-003-5 | 016, 018 | 016-TEST, 018-TEST |
| AC-004-1 | 022, 025 | 022-TEST, 025-TEST |
| AC-004-2 | 007, 025 | 007-TEST, 025-TEST |
| AC-005-1 | 008, 023, 024 | 008-TEST, 023-TEST, 024-TEST |
| AC-005-2 | 007, 009, 023 | 007-TEST, 009-TEST, 023-TEST |
| AC-005-3 | 023 | 023-TEST |

## 11. Open Technical Decisions

Eight decisions need the operator. Each is a proposal with its basis; the repository has no evidence for the numbers, so none is presented as measured. TRD-026 records the operator's answer to each.

1. **Rubric thresholds.** Proposed in the table below; the level is the maximum over all rows and the model can only raise it.
2. **Gate semantics.** `merge_approve` is refused with a typed reason unless the evidence for the current head is eligible or explicitly waived (still operator-approved and SHA-pinned). Basis: PRD REQ-004 and the operator's decision on waivers.
3. **Observation.** Turn the PR monitor on for any deployment that gates a project (the webhook is optional); the doctor warns otherwise. The gate is safe without it (TRD-022).
4. **Sensitive-path table v1** (below).
5. **Waivable reasons.** `no_checks_configured`, `missing`, `findings_absent`, `findings_other_sha`. Never waivable: `failing`, `pending`, `stale`, `other_sha`, `findings_malformed`. An absent or malformed model judgement is HIGH (conservative; it makes LOW rare until the review prompts reliably emit the block).
6. **Default per project.** The gate is off until `required_checks` is set; publication follows the gate switch.
7. **Durable-store guard.** Enabling `required_checks` is refused (not only warned) while the idempotency store is ETS-only; true in `config/config.exs`, false in dev and test.
8. **Freshness window.** Check evidence older than 900 seconds is `stale`.

| Input | LOW | MEDIUM | HIGH |
|---|---|---|---|
| Changed files | 10 or fewer | 11 to 25 | more than 25 |
| Lines added plus deleted | 200 or fewer | 201 to 800 | more than 800 |
| Unresolved findings | none, or nitpicks only | any minor | any critical or major |
| Changed-file evidence | complete | complete | incomplete (`files_incomplete?`) |
| Sensitive path touched | no | no | yes |
| Required checks | all passing, not waived | not used | any not passing, none configured, or waived |
| Base branch | equals the run's recorded base | not used | differs |
| Model judgement | LOW | MEDIUM | HIGH, missing, malformed, or for another head |

Sensitive-path table v1 (every path exists in the repository; a prefix ends in a slash; paths under `packages/foreman_server/` are written from there):

| Group | Match |
|---|---|
| CI | prefix `.github/workflows/` |
| Runtime configuration | prefix `packages/foreman_server/config/` |
| Migrations | prefix `packages/foreman_server/priv/repo/migrations/` |
| Bundled workflows and prompts | prefix `packages/foreman_server/priv/defaults/workflows/` |
| Merge, approval and effect code | exact `lib/foreman_server/aggregates/run.ex`, `pr_gate.ex`, `run_pr_merge.ex`, `command_gateway.ex`, `github/pr_merge.ex`, `workflow/approver_authorizer.ex`, `workflow/merge_gate.ex`; prefix `lib/foreman_server/idempotency/` |
| Authentication and secrets | prefix `lib/foreman_server_web/plugs/`; exact `lib/foreman_server/mcp/auth.ex`, `mcp/policy.ex`, `aggregates/project_secret.ex`, `config_providers/secrets.ex` |
| Instruction files | base name `AGENTS.md`, `CLAUDE.md` |
| Dependency and build manifests | base name `mix.exs`, `mix.lock`, `go.mod`, `package.json`, `package-lock.json`, `devbox.json`, `devbox.lock`, `Dockerfile`, `docker-compose.yml` |
| Secret-like names | base name containing `secret` or starting with `.env` |

## 12. Testing Plan

- **Pure units:** `PrEvidence.evaluate/2` over every reason code and every combination of head, waiver and policy; `PrRisk.Rubric.classify/1` over every HIGH trigger, the MEDIUM triggers, LOW, raise-only and determinism; the findings parser over recorded, absent and every malformed shape.
- **Aggregate:** every new command validated strictly and rejected without appending; replay equals the live fold (`Aggregate.load/2`); the gate refusal is identical on replay.
- **Fold parity:** aggregate and projection hold the same `evidence` for the same events (TRD-007-TEST), including a cross-half head reset.
- **Gateway with a fake `gh` runner:** the fresh observation at approval, the head mismatch, a failed read, the durable-store guard, the waiver's live-head check.
- **Effects (`async: false`):** the refusal of an undecided key per status, the decision lifecycle, the repeatable exception, the sweep (decision written, failing read, on-demand scan), the `pr_comment` key and reconciler (crash on each side of the post), and the block, reset, resume walk for `foreman-tnlqt`.
- **Real fixtures:** rollup items captured from `gh` 2.103.3 (check run and status context) and the 100-of-223 file list.
- **Go:** `go test` for the new flag and verb in `packages/foreman_cli/cmd/foreman` (`project_settings_test.go`, `run_merge_test.go`, `usage_drift_test.go`).
- **Adversarial suite (TRD-025):** missing result, spoofed result (status context named like a required check run, another workflow's check, an agent-written artifact), stale result after a fix push, head change after approval and after publish, re-run per head, waiver for another head, forged risk level, feedback loop. TRD-025-TEST reverts each guard in a scratch copy and records that the matching scenario goes red.
- **Documentation gate (TRD-026, TRD-027):** reviewer checklists; every CLI, MCP and HTTP name checked against source.
- **Run one file:** `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test <path>'` (AGENTS.md); the full suite once, after all tasks land.

## 13. Rollout and Rollback

- **Order of exposure.** PR 1 to PR 3 add no gate. PR 4 adds the setting, off by default. PR 5 and PR 6 record findings and risk. PR 7 publishes, only for projects with `required_checks` set. PR 8 enforces, only for those projects. A project that never sets `required_checks` behaves as today, apart from P-1 (an undecided effect key is refused) and P-2 (an existing PR is adopted), which apply everywhere.
- **Enabling gating for a project (operator steps).** Switch the durable store on first (`config :foreman_server, :jido_ecto, enabled: true` and `JIDO_CHECKPOINT_DATABASE_URL`; `config/prod.exs:74-78` has it off); turn the PR monitor on (`FOREMAN_PR_MONITOR_ENABLED=true`); run `foreman doctor`; set `foreman project update <id> --required-checks '<json>'`; confirm the first PR shows its eligibility with `foreman run prs <id>`. The first publication needs the one-time scratch-PR check of TRD-019 (the `gh` writes are unverified).
- **Rollback.** Clear `required_checks` (`--clear required_checks`): the gate is off, publication stops, approval behaves as before. New events stay in the streams. A stream that contains a new optional field cannot be decoded by an older build, so rolling the binary back is safe only before the first gated PR; after that, roll forward or clear the setting and keep the build. `RunReset` returns the run state to its initial value (`aggregates/run.ex:306-307`), so evidence is re-observed after a reset.
- **Boot behaviour changes.** `ProjectionStore.init/1` stops with `{:event_log_read_failed, reason}` instead of starting empty (TRD-023): while the event log is unreadable the server does not boot, by design. An undecided effect key is refused until the sweep decides it (TRD-002, TRD-003); `foreman_doctor` lists such keys.

## 14. Self-Review Findings

Honest gaps, and corrections to the scout reports this TRD started from.

- **Corrected from the scouts.** `PhasePR` already looks up an open PR after its push (`phase_pr.ex:183-199`); `PrCreate` already adopts an existing PR by string match (`pr_create.ex:215-229`); a phase PR is already signalled as the run's PR (`run_executor.ex:2659-2683`), so the lessons file sentence at `:641-643` is stale (TRD-027 corrects it); the DTO is built from the projection, not the aggregate (`dto.ex:61-73`); GitHub's rollup does carry `completedAt` for check runs (probe); `PrObservation` is pure, so the policy is passed in; the waiver handler must live in `Run` because the gate check is private there; the usage drift test checks verbs, not flags; `foreman run prs` prints JSON, so there is no CLI change for the status; the documentation task is TRD-027.
- **Not built.** Sweep ordering before executors resume (the third item of `foreman-by6nl`): a `started` key of a run whose executor is alive is not orphaned by the sweep (`boot_reconciliation.ex:836-842`), so it stays refused until that executor ends and a later scan or a restart decides it. A refusal casts an on-demand scan; it does not remove this wait.
- **Out-of-order observations** can rewind the head of record; the effect is fail-safe (a refusal or a re-hold), not fixed here.
- **`status_context` is weaker than `check_run`.** A status context has no creator or app (probe), so anyone who can create statuses can satisfy an entry of that kind; an entry names its kind, and the operator chooses `check_run` where the source matters.
- **Proposals, not measurements:** the thresholds, the sensitive-path table, the waivable set and the freshness window (§11).
- **Unverified:** every `gh` comment write, that the node id `gh pr view` returns is accepted by `updateIssueComment`, and what `gh pr comment` prints on success (TRD-019 probes them on a scratch PR); the `go test` invocation; that a second reader would find every cited line unchanged (line numbers drift).
- **Findings are re-needed after every fix push:** `findings_other_sha` makes the PR ineligible until the review is re-run or the reason is waived. PRs of a multi-repository run other than the primary read `findings_absent` until waived.
- **A run with no review phase** records `absent` and needs a waiver when the gate is on.
- **Large PRs:** `gh pr view --json comments` pages every comment (26 s for 908), which slows the reconciler and `list/2`; over 100 changed files the list is incomplete and the rubric gives HIGH.
- **Operator-only is a convention of the API token:** whoever holds the token can send `run.pr.waive_evidence` and clear `required_checks`; the approver identity is a claim checked against `ApproverAuthorizer`'s list, as for `merge_approve`.
- **Constitution §5:** new events, new commands and a new CLI verb are changes that need the operator's approval (`docs/standards/constitution.md:132-140`); this TRD is the artifact for that review.

## 15. Design Readiness Scorecard

| Dimension | Score | Basis |
|---|---|---|
| Requirement traceability | 5 | 18 of 18 criteria and 5 of 5 requirements covered; the parse reports no warning |
| Source grounding | 4 | each design claim cites a line read in the worktree; no independent second pass; line numbers drift |
| Task decomposition | 4 | 27 implementation tasks and 27 test tasks, none over 8h, no forward dependency; several 7h tasks are dense |
| Test design | 4 | every implementation task has a mutation-style test task; GitHub behaviour is faked except the captured fixtures |
| Open unknowns | 3 | `gh` writes unverified; thresholds, waivable set and sensitive paths are proposals; eight operator decisions pending |

Average 4.0. PASS with concerns: the build can start with PR 1 to PR 4 while the operator answers §11; PR 7 needs the scratch-PR check first.

## 16. Changelog

| Version | Date | Changes |
|---|---|---|
| 1.0.0 | 2026-11-12 | Initial TRD: 27 implementation tasks and 27 test tasks in 9 PRs, locked to PRD v1.1.0 (18 acceptance criteria). |
