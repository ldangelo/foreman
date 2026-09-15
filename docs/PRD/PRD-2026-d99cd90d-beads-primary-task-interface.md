---
document_id: PRD-2026-d99cd90d
label: prd-beads-primary-interface
status: Final
date: 2026-09-12
scale_depth: LIGHT
total_requirements: 10
readiness_score: 4.125
readiness_status: PASS
---

# PRD: Beads as the Primary Task Interface, Foreman as Silent Worker

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 8 |
| Should | 1 |
| Could | 0 |
| Won't | 1 |

| Metric | Value |
|---|---:|
| Requirement coverage | 10/10 (100%) |
| Risk flags | 2 |
| Dependencies | 7 |
| Open ambiguity markers | 0 |
| TRD decisions required | 3 |

## Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Workflow-declared beads-type mapping | Must | Medium | 3 |
| REQ-002 | Mapping validation at startup + `foreman doctor` | Must | Medium | 2 |
| REQ-003 | Status-gated import and auto-approval (`open` triggers, `draft` does not) | Must | High | 3 |
| REQ-004 | Eventually-consistent watcher catch-up | Must | Medium | 1 |
| REQ-005 | Bidirectional status sync + transient/permanent failure classification | Must | High | 4 |
| REQ-006 | Remove all `task.*` operator commands; keep `run.*` commands | Must | High | 2 |
| REQ-007 | `trd_path` delivery via `agent_context` for TRD-requiring workflows | Must | Medium | 2 |
| REQ-008 | Restore `implement-trd` and `implement-trd-beads` workflow manifests | Must | Medium | 1 |
| REQ-009 | Provider-agnostic `TaskProvider`/`CommandGateway` naming | Should | Low | 1 |
| REQ-010 | Non-Beads provider watchers (Jira/Linear/GitHub/Kata) | Won't (this release) | — | 0 |

## 1. Executive Summary

Foreman currently supports two disconnected ways to originate work: the
operator-facing `foreman task create` (CLI/HTTP) path, and `br create`
against a project's Beads store, auto-imported by the opt-in `BeadsWatcher`
(shipped, TRD-81315f37). Maintaining both creates operator friction and
invites drift between them.

This PRD flips the model: **Beads (or whichever task provider a project
configures) becomes the only way to originate work; Foreman becomes a
silent execution backend** triggered entirely by task-provider state
transitions. `foreman task create` and the rest of the `task.*` operator
command surface are removed. Workflow selection, which today falls back
loosely from `task_type`, becomes an explicit mapping declared **by each
workflow manifest** (which beads type(s) trigger it) — restoring, in a new
form, a capability an earlier version of Foreman had (evidenced: commit
`afb775209` shipped one workflow YAML per beads type; several such stale
files still sit in the installed catalog). `implement-trd` and
`implement-trd-beads`, deleted three days prior by PR #488, are restored so
TRD-driven execution remains reachable from a beads type.

## 2. Background and Evidence

### 2.1 What exists today (verified against code)

- `BeadsWatcher` (`packages/foreman_server/lib/foreman_server/task_providers/beads_watcher.ex`)
  tails a project's `.beads/issues.jsonl`, skips beads already Foreman-tagged
  (`agent_context.foreman`), dedupes against `ProjectionStore`, and
  synthesizes a `task.create` command for any new bead — **with no status
  gate at all**: a `draft`-status bead is imported exactly like an `open`
  one today.
- `task_type` flows straight from beads `issue_type`; `workflow_type` is
  never set by the watcher, so workflow selection relies entirely on
  `Approval.prepare/2`'s `workflow_type || task_type` fallback
  (`command_gateway.ex:638-649`) — an implicit, undeclared contract.
- `CommandGateway.dispatch_operator/2` already rejects an operator-supplied
  `external_id` (`command_gateway.ex:234-242,865-874`) — precedent for
  locking down parts of the create path, but `task.create` itself is not
  blocked.
- `BeadsAdapter.fail/3` (`beads_adapter.ex:1920-1985`) currently sets a
  failed task's bead back to `--status open` — under this PRD's model,
  `open` is the dispatch trigger, so this existing behavior would cause an
  immediate re-dispatch loop and **must change**.
- The workflow catalog currently ships only 4 manifests
  (`assess`, `fix`, `prd`, `review`); `implement-trd`, `implement-trd-beads`,
  `implement`, `discover`, `plan`, `release`, `trd`, `verify` were deleted by
  commit `1fd9f6b7` (PR #488, 2026-09-09) — the installed
  `~/.foreman/workflows/` directory retaining all of them is a stale
  pre-cleanup snapshot, not evidence they are still bundled.
- `trd_path`/`ImplementationContext` is required only by `implement-trd`
  and `implement-trd-beads` (`run_executor.ex:2095-2106`,
  `packages/foreman_cli/cmd/foreman/task.go:95,142`); none of the 4
  remaining bundled workflows declare `worktree.base`, so none need it
  today.
- `br update --status` refuses terminal states (`closed`, `tombstone`) —
  closing a bead requires the dedicated `br close` command
  (verified via `br update --help`).
- `br` has a real `draft` status (undocumented in `--help` but accepted and
  schema-valid; verified empirically), excluded from `br list`'s default
  view — the natural fit for "backlog."

### 2.2 Prior art referenced by the requester

An earlier Foreman version mapped workflows to task types via a
one-workflow-YAML-per-type convention. The exact original mapping
mechanism (as a discrete data structure, versus the file-naming
convention) could not be located in git history after a bounded search;
this PRD does not attempt to resurrect the old mechanism verbatim, only
its intent, via REQ-001's workflow-declared `task_types:` field.

## 3. Personas

- **Engineer using `br create`** (primary). Never touches Foreman directly;
  creates and manages work entirely through beads status transitions.
- **Foreman operator/maintainer** (the requester). Configures workflow
  manifests and their beads-type mappings; uses `foreman doctor` and
  `foreman run *` for operational visibility and intervention.

## 4. Requirements

### REQ-001: Workflow-Declared Beads-Type Mapping

Priority: Must | Complexity: Medium

Each workflow manifest declares the beads `issue_type` value(s) that
trigger it via a new field, e.g. `task_types: [foreman_prd]`.
`ForemanServer.Workflow.Catalog` builds the reverse type→workflow lookup
from all loaded manifests at load and hot-reload time. A workflow may omit
`task_types:` entirely (never auto-triggered by beads — the current
behavior of `assess`/`fix`/`review` is unaffected unless explicitly opted
in).

**Field format:** `task_types:` is an array of strings, e.g.
`task_types: ["foreman_prd", "foreman_implement"]`. A workflow may declare
zero, one, or multiple types; multiple types may map to the same workflow
(fan-in). Two workflows must not share a type (enforced by REQ-002).

- AC-001-1: Given two workflows declare the same `task_types` entry, when
  the catalog loads, then loading fails closed with an error naming both
  workflows and the colliding type.
- AC-001-2: Given a workflow omits `task_types:`, when the catalog loads,
  then it loads successfully and is never auto-triggered by a beads status
  transition.
- AC-001-3: Given a workflow declares `task_types: ["type_a", "type_b"]`,
  when beads issues with either type transition to `open`, then both are
  routed to that single workflow.

### REQ-002: Startup and `foreman doctor` Mapping Validation

Priority: Must | Complexity: Medium | Depends on: REQ-001

The conflict check in REQ-001 runs at Catalog load (fail-closed, no
partially-loaded catalog). `foreman doctor` additionally reports type
coverage against a project's actual beads data.

- AC-002-1: Given `foreman doctor` runs against a beads-backed project,
  when one or more distinct, non-closed `issue_type` values in that
  project's store have no matching workflow mapping, then doctor reports
  every such type by name.
- AC-002-2: Given every non-closed `issue_type` in use has a matching
  workflow, when `foreman doctor` runs, then it reports full coverage with
  no unmapped types listed.

### REQ-003: Status-Gated Import and Auto-Approval

Priority: Must | Complexity: High | Depends on: REQ-001

`BeadsWatcher` creates **and immediately approves** a Foreman task only
when a bead's status is, or transitions to, `open`. `draft` (backlog)
produces no Foreman task or side effect of any kind.

- AC-003-1: Given a bead is created with status `draft`, when the watcher
  processes that line, then no Foreman task is created and no entry is
  recorded that would block a later transition from being treated as new.
- AC-003-2: Given a bead later transitions `draft -> open` (a new JSONL
  line), when the watcher processes it, then a Foreman task is created and
  approved as a single effective step from the operator's perspective.
- AC-003-3: Given a bead is created directly with status `open` (skipping
  `draft`), when the watcher processes that line, then the same
  create-and-approve happens immediately — `open` is unconditionally the
  trigger regardless of path.

### REQ-004: Eventually-Consistent Watcher Catch-Up

Priority: Must | Complexity: Medium | Depends on: REQ-003

Watcher downtime or lag delays, but never loses, a `draft -> open`
transition. This generalizes the watcher's existing full-replay-on-boot
design (TRD-81315f37 §2.2.6) to the new status gate.

- AC-004-1: Given the watcher is stopped while a bead transitions to
  `open`, when the watcher restarts, then its boot replay still creates
  and approves the corresponding task.

### REQ-005: Bidirectional Status Sync and Failure Classification

Priority: Must | Complexity: High [RISK: new failure-cause classifier;
no such mechanism exists today] | Depends on: REQ-003

Foreman writes the run's lifecycle back to the bound bead's status.
Failures classify as **transient** (infrastructure-caused: model
unreachable, database unreachable, network error — retried automatically
with exponential backoff, up to 3 attempts) or **permanent** (anything
else, e.g. a workflow-definition or validation error — no retry).

**Failure handling mechanism:** `RunExecutor` internally retries transient
failures *before* invoking the `TaskProvider` (e.g. `BeadsAdapter`) boundary.
`fail/3` is invoked only on a **terminal outcome**: success (→ `br close`),
permanent failure (→ `--status blocked`), or transient failure exhausted
(→ `--status blocked`). Transient retries are Foreman-internal; the bound
bead's status remains at `in_progress` throughout.

- AC-005-1: Given a run starts, when Foreman dispatches it, then the bound
  bead's status becomes `in_progress`.
- AC-005-2: Given a run reaches terminal success, when Foreman finalizes
  it, then the bead is closed via `br close` (not `br update --status`,
  which refuses terminal states).
- AC-005-3: Given a run fails with a transient-classified cause and fewer
  than 3 attempts have been made, when the failure occurs, then `RunExecutor`
  retries internally without invoking `BeadsAdapter.fail/3`; the bead's
  status remains unchanged at `in_progress`.
- AC-005-4: Given a run fails with a permanent-classified cause, OR a
  transient failure has exhausted 3 attempts, when `RunExecutor` determines
  the outcome is terminal, then `BeadsAdapter.fail/3` is invoked with
  `--status blocked`.

### REQ-006: Remove All `task.*` Operator Commands; Keep `run.*` Commands

Priority: Must | Complexity: High [RISK: removes a currently-shipped,
possibly-scripted CLI/API surface] | Depends on: REQ-003, REQ-004

`foreman task create`, `task approve`, `task retry`, and `task get` (the
full `task.*` operator surface) are deleted from the CLI entirely — no
special-cased guided error, no beads-replacement hint. Invoking any of
them produces the CLI's standard "unknown command" error, identical to
invoking any other nonexistent subcommand, with the CLI's existing exit
code for that case. All `run.*` commands (`cancel`, `get`, `list`,
`reset`, `remove`) are unaffected — they have no beads equivalent
(worktrees, phases, runs are Foreman-internal concepts).

**Removal behavior:** No custom migration message and no distinct exit
code are introduced. Operators discover the beads-native replacement
(`br create`, `br update --status open`, `br show`/`bv`) via `foreman
doctor` and documentation, not via command-invocation error text.

- AC-006-1: Given an operator runs any `task.*` command, when the CLI
  dispatches it, then the CLI's standard "unknown command" error fires
  (identical to any other nonexistent subcommand), and no task-lifecycle
  side effect occurs.
- AC-006-2: Given an operator runs any `run.*` command, when the CLI
  dispatches it, then behavior is identical to today.

### REQ-007: `trd_path` Delivery via `agent_context`

Priority: Must | Complexity: Medium | Depends on: REQ-001, REQ-008

For workflows requiring `ImplementationContext` (`implement-trd`,
`implement-trd-beads`), the watcher reads `trd_path` from the bead's
`agent_context` JSON object (set via `br create --agent-context` /
`br update --agent-context`) before creating+approving the task.

**Missing `trd_path` handling:** When a workflow requires `trd_path` but it
is absent or empty in `agent_context`, Foreman does not create a task.
Instead, it emits a distinct telemetry outcome and optionally writes a
comment to the bead.
**Ratified default:** Foreman moves the bead to `blocked` with a
transition comment naming the missing field, so the gap is immediately
visible in `br show` / `bv --robot-triage`; the operator re-runs
`br update <id> --agent-context '{"trd_path":"..."}' --status open` to
retry.

- AC-007-1: Given the mapped workflow requires `trd_path` and
  `agent_context.trd_path` is a non-empty string, when the watcher
  dispatches, then `trd_path` flows into the task exactly as
  `foreman task create --trd-path` does today.
- AC-007-2: Given the mapped workflow requires `trd_path` and it is absent
  from `agent_context`, when the watcher processes the `open` transition,
  then no task is created; the bead is moved to `blocked` with a
  transition comment explaining the missing `trd_path` (operator-visible
  in `br show`/`bv --robot-triage`); an internal telemetry event is
  emitted.

### REQ-008: Restore `implement-trd` and `implement-trd-beads` Workflow Manifests

Priority: Must | Complexity: Medium

Reintroduce the two manifests deleted by PR #488
(`packages/foreman_server/priv/defaults/workflows/implement-trd.yaml`,
`implement-trd-beads.yaml`), each declaring its own `task_types:` entry
per REQ-001.

- AC-008-1: Given the restored manifests are installed, when the catalog
  loads, then both are loadable and pass REQ-002's conflict validation.

### REQ-009: Provider-Agnostic `TaskProvider`/`CommandGateway` Naming

Priority: Should | Complexity: Low

Keep the `TaskProvider` behaviour boundary and `CommandGateway` free of
Beads-specific naming/assumptions, so a future Jira/Linear/GitHub/Kata
adapter is not structurally blocked by this work (its own watcher
equivalent remains separate future work — see REQ-010).

- AC-009-1: Given a future non-Beads `TaskProvider` implementing the
  existing behaviour, when it is registered, then no Beads-specific code
  introduced by this PRD needs to change to accommodate it structurally.

### REQ-010: Non-Beads Provider Watchers (Jira/Linear/GitHub/Kata)

Priority: Won't (this release) | Complexity: —

Only `BeadsAdapter` is implemented today (`KataAdapter` is designed but
unbuilt per TRD-8030852f; no Jira/Linear/GitHub adapter exists). Building
watcher-equivalents for those backends is out of scope here.

## 5. Dependency Map

| REQ | Depends On |
|---|---|
| REQ-002 | REQ-001 |
| REQ-003 | REQ-001 |
| REQ-004 | REQ-003 |
| REQ-005 | REQ-003 |
| REQ-006 | REQ-003, REQ-004 |
| REQ-007 | REQ-001, REQ-008 |
| REQ-008 | (none) |
| REQ-009 | (cross-cutting, no hard dependency) |

## 6. Self-Critique (resolved during elicitation)

1. **REQ-005 failure handling was undefined** — resolved: permanent →
   `blocked`; transient → retry w/ backoff, max 3, then `blocked`.
2. **`BeadsAdapter.fail/3` conflicts with the new `open`-triggers-dispatch
   rule** — its current `--status open` behavior must change to `--status
   blocked` (transient-exhausted) or stay silent mid-retry; this is a
   change to existing, shipped code, not new-only logic.
3. **REQ-006 removal has a migration hazard** — resolved (revised
   2026-09-12): bare removal, standard "unknown command" CLI error, no
   guided migration message.
4. **Mapping location and doctor scope were unspecified** — resolved:
   mapping lives in the workflow manifest (`task_types:`), and doctor
   reports every non-closed unmapped type with no reserved-prefix
   filtering.
5. **Command-removal scope was ambiguous** (create-only vs. all task
   commands) — resolved: all `task.*` commands removed, all `run.*`
   commands retained.

## 7. Open Ambiguities and Defaults

- **REQ-007 AC-007-2 missing-`trd_path` signal mechanism** (RATIFIED):
  Bead → `blocked` + transition comment (operator-visible, immediate).
  Operator re-runs `br update <id> --agent-context '{"trd_path":"..."}' --status open` to retry.

- **Migration/backfill plan for tasks created via removed `foreman task create`** (RATIFIED):
  Changelog entry stating "tasks created prior to [release] have no beads linkage (`external_id`);
  such tasks remain executable. On the first task.retry, Foreman warns in operator logs but does
  not block." No backfill required for v1.

## 8. Out of Scope
- Watcher/import implementations for non-Beads task providers (REQ-010).
- Any change to `run.*` operator commands.
- Resurrecting the exact historical task_type-mapping mechanism verbatim
  (only its intent is restored, via REQ-001's manifest-declared mapping).
- Changing shipped `BeadsAdapter.fail/3` behavior; transient retries are
  handled internally by `RunExecutor`, not at the TaskProvider boundary.
  **Superseded** by REQ-005/AC-005-4 (§ above) and TRD-013: `fail/3`'s
  hardcoded `--status open` on terminal failure *did* change, to
  `--status blocked`, because REQ-003's `open`-triggers-dispatch rule made
  the old behavior an immediate re-dispatch loop (see line 85-88 above).
  This bullet is preserved verbatim as historical intent — the scope
  boundary it drew (no *new* TaskProvider-boundary retry mechanics beyond
  the one hardcoded status flip) held; only the literal claim that `fail/3`
  itself would be untouched did not (CodeRabbit review).

## Appendix: Evidence Index

| Claim | Location |
|---|---|
| `BeadsWatcher` import/dedupe logic | `packages/foreman_server/lib/foreman_server/task_providers/beads_watcher.ex:1-736` |
| `workflow_type \|\| task_type` fallback | `packages/foreman_server/lib/foreman_server/command_gateway.ex:638-649` |
| `dispatch_operator` rejects operator `external_id` | `command_gateway.ex:234-242,865-874` |
| `fail/3` sets `--status open` today | `packages/foreman_server/lib/foreman_server/task_providers/beads_adapter.ex:1920-1985` |
| PR #488 deleted 8 workflow manifests | `git show 1fd9f6b7 --stat` |
| Bundled workflow catalog is 4 manifests | `git ls-tree HEAD -- packages/foreman_server/priv/defaults/workflows/` |
| `trd_path` required only by `implement-trd*` | `packages/foreman_cli/cmd/foreman/task.go:95,142`; `run_executor.ex:2095-2106` |
| `br update` refuses terminal status | `br update --help` |
| `draft` status valid, excluded from default list | empirical test in scratch repo; `br schema issue` `Status` enum |

## Appendix B: Readiness Gate Scorecard

| Dimension | Score | Justification |
|---|---:|---|
| Completeness | 4.5/5 | All 10 reqs address the goal; failure-cause mechanism clarified (RunExecutor-internal retry); AC-007-2 has concrete default. Backoff schedule (base/cap) deferred to TRD. |
| Testability | 4/5 | ACs are Given/When/Then; AC-005-3 mechanism explicit (RunExecutor + no fail/3 call); AC-007-2 observable (blocked+comment default). Environment-dependent checks (AC-002-1) acceptable. |
| Clarity | 4/5 | Terminology consistent; task_types format named (array); guided-error behavior specified (exit non-zero); failure-handling mechanism detailed. |
| Feasibility | 4/5 | No blockers; RunExecutor-internal retry is achievable; no shipped-code change to fail/3 needed. Failure classifier design required but feasible. |
| **Average** | **4.125** | **PASS** |

Gate status: PASS. Both ambiguities ratified during interactive elicitation
(see changelog 1.2.0): missing-trd_path signal mechanism → bead blocked+comment;
pre-existing task migration → warn-only, no block. Refinements from elicitation:
- AC-005-3: clarified that transient retries are RunExecutor-internal
  (no fail/3 invocation until terminal outcome)
- AC-007-2: added ratified default (bead → blocked + comment on missing trd_path)
- REQ-006: revised 2026-09-12 to bare removal (standard "unknown command"
  CLI error, no guided-migration message)
- REQ-001: documented task_types field format (array of strings)

## Changelog

- **1.4.0** — 2026-09-12 — User confirmed architecture (Phase 2.4,
  TRD-2026-d99cd90d-arch v1.3.0) and PRD are complete; status Draft →
  Final. No further requirement changes; proceeding to Phase 3 Master
  Task List generation.
- **1.3.0** — 2026-09-12 — User reversed REQ-006's migration-hazard
  resolution during architecture-phase interview: bare command removal
  (standard "unknown command" CLI error) replaces the guided-error
  behavior specified in 1.1.0/1.2.0. Version bumped for design-phase PRD
  revision, not implementation drift. Gate status unchanged: PASS
  (4.125/5); score not re-run since the change narrows behavior rather
  than adding scope.
- **1.2.0** — 2026-09-12 — User ratification of both ambiguity defaults during PRD lock; status Draft → Final; ambiguity markers 2 → 0. Gate status unchanged: PASS (4.125/5).
- **1.1.0** — 2026-09-12 — Readiness gate refinement: clarified AC-005-3
  failure-handling mechanism (RunExecutor-internal retry, no fail/3 call
  until terminal); documented task_types field format; specified
  guided-error behavior; added default assumptions for REQ-007 and
  migration plan. Gate status: PASS (4.125/5).
- **1.0.0** — 2026-09-12 — Initial PRD via `/ensemble-create-prd`, interactive
  elicitation (LIGHT depth, solo).
