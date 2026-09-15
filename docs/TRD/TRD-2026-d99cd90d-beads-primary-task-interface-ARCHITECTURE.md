---
document_id: TRD-2026-d99cd90d-arch
label: trd-beads-primary-interface-arch-design
phase: 2.4
version: 1.6.0
status: Final
date: 2026-09-12
architecture_option: B (Full Sync)
prd_reference: docs/PRD/PRD-2026-d99cd90d-beads-primary-task-interface.md
---

# Phase 2.4: System Architecture Design
## Beads as Primary Task Interface — Option B (Full Bidirectional Sync)

### 1. Architecture Overview

**Goal**: Implement full bidirectional status sync between Foreman runs and Beads issues, with automatic transient retry (3×, exponential backoff).

**Key insight**: Status transitions are Foreman's responsibility; the watcher only dispatches on `open` status. Foreman then owns the full lifecycle: mark `in_progress`, retry transients internally, and write terminal states back.

---

## 2. Component Breakdown

### 2.1 **Workflow.Catalog** — Manifest-Declared Type Mapping (REQ-001)

**Responsibility**: Load, validate, and hot-reload workflow manifests; build type→workflow reverse lookup.

**Changes**:
- Add `task_types:` field to YAML parser (array of strings)
- During load, scan all manifests and build `type_to_workflow: %{String.t() => String.t()}` map
- Fail closed if two workflows declare the same type (AC-001-1)
- Skip workflows with omitted `task_types:` (never auto-triggered)
- Hot-reload: rebuild the map on every file change

**Data structure** (new, stored in Catalog GenServer state):
```elixir
%{
  "foreman_prd" => "prd.yaml",
  "foreman_implement_trd" => "implement-trd-beads.yaml",
  "foreman_implement_trd_fallback" => "implement-trd.yaml"
}
```

**Integration point**: `BeadsWatcher` queries this map when processing `open` transitions to select the target workflow.

---

### 2.2 **BeadsWatcher** — Status-Gated Import (REQ-003, REQ-007)

**Current state**: Imports ALL beads regardless of status.

**Changes**:

1. **Status gate** (AC-003-1, AC-003-2, AC-003-3):
   - After dedupe check in `process_line/2`, add a new gate: `check_status/1`
   - Accept only `status: "open"`; all others (including `draft`) return `:skip_status`
   - Emit telemetry event `[:watcher, :status_gate, :skipped]` for non-open

2. **Workflow selection** (REQ-001):
   - Query `Catalog.type_to_workflow(issue_type)` to select the target workflow
   - If no mapping exists, emit `:unmapped_type` and hold (transient) — operator must update the workflow manifests
   - Add to `task.create` payload: `workflow_type: selected_workflow_name`

3. **`trd_path` extraction** (REQ-007, AC-007-1, AC-007-2):
   - After status gate, check if selected workflow requires `ImplementationContext`
   - Query `agent_context.trd_path` from the bead
   - If required but absent/empty: emit `:missing_trd_path`, move bead to `blocked`, write transition comment
   - If present: pass as `trd_path` in the `task.create` envelope

4. **Auto-approval**:
   - In `dispatch_new_bead/2`, when synthesizing the `task.create` command, add an immediate `task.approve` in the same transaction
   - Use `CommandGateway.dispatch_system/2` with both commands (or a new `dispatch_and_approve` variant)

**Transition outcomes** (in `advance_one_line/2`):
- `:imported` — task created and approved; cursor advances
- `:skipped` — status gate failed (draft, unmapped type, missing trd_path); cursor advances; bead moved to `blocked` with comment
- `:reconciled` — dedupe hit; cursor advances
- `:malformed` — JSON parse failure; cursor advances
- `:transient` — dispatch error (will retry on next poll)

**Telemetry events** (new):
- `[:watcher, :status_gate, :skipped]` — bead not `open`
- `[:watcher, :workflow_unmapped]` — no mapping for issue_type
- `[:watcher, :trd_path_missing]` — required but absent
- `[:watcher, :dispatch_and_approve]` — task created and approved in one action

---

### 2.3 **RunExecutor** — Transient Retry & Failure Classification (REQ-005)

**Current state**: Single dispatch attempt; failures go to `TaskProvider.fail/3` immediately.

**Changes**:

1. **Transient retry loop** (AC-005-3):
   - Max 3 attempts; exponential backoff: attempt 1 (0s wait before first try), attempt 2 (1s), attempt 3 (5s); if attempt 3 also fails transiently, escalate after a final 15s (per §8.1)
   - On each attempt, dispatch the phase and observe the outcome
   - If outcome is `:transient` AND attempts < 3: log, wait, retry
   - If outcome is `:transient` AND attempts == 3: escalate to `:permanent` and proceed to failure classification
   - If outcome is not `:transient` (success or permanent failure): proceed immediately

2. **Status sync on phase start** (AC-005-1):
   - Before dispatching phase 1, call `TaskProvider.update_status(task_id, :in_progress)`
   - This moves the bead to `in_progress`; if it fails, do NOT retry — log and continue

3. **Failure classification** (the new, critical piece):
   - **Transient classification logic**:
     - `:model_unreachable` — agent model not available (e.g., "Claude offline")
     - `:provider_unavailable` — provider service down (e.g., API 503, timeout)
     - `:database_unavailable` — Postgres/EventStore unavailable
     - `:network_error` — DNS resolution, TCP connection failure
     - `:worker_dispatch_error` — Jido/Overwatch dispatch failure (recoverable)
     - Pattern: **infrastructure-caused, not workflow-caused**
   - **Permanent classification logic**:
     - `:validation_error` — task/run validation failed
     - `:workflow_definition_error` — workflow manifest is invalid
     - `:agent_error` — agent script error (non-infrastructure)
     - `:phase_terminal` — run halted by design (e.g., gate failed)
     - Pattern: **operator action required; retry won't help**
   - **Default**: Anything not explicitly transient → permanent

3. **Implementing the classifier**:
   - Create new module `ForemanServer.Workflow.FailureClassifier` with `classify/1` function
   - Takes error payload from run outcome and returns `{:transient, reason}` or `{:permanent, reason}`
   - Used in `RunExecutor.dispatch_phase/4` after phase completion

4. **Status sync on terminal outcome**:
   - On success: call `TaskProvider.mark_completed(task_id)` → `br close`
   - On permanent failure: call `TaskProvider.fail(task_id)` with `--status blocked`
   - On transient-exhausted: call `TaskProvider.fail(task_id)` with `--status blocked` (same as permanent)

**Code shape**:
```elixir
@backoff_schedule_ms [1_000, 5_000, 15_000]

def dispatch_phase_with_retry(run_id, phase, attempt \\ 1) when attempt <= 3 do
  case dispatch_phase(run_id, phase) do
    {:ok, _} -> {:ok, ...}
    {:error, error} ->
      case FailureClassifier.classify(error) do
        {:transient, _reason} when attempt < 3 ->
          backoff_ms = Enum.at(@backoff_schedule_ms, attempt - 1)
          Process.sleep(backoff_ms)
          dispatch_phase_with_retry(run_id, phase, attempt + 1)
        {:transient, _reason} ->
          # Final settle wait (15s) before escalating; not a 4th attempt
          Process.sleep(Enum.at(@backoff_schedule_ms, attempt - 1))
          {:error, {:transient_exhausted, error}}
        {:permanent, _reason} ->
          {:error, error}
      end
  end
end
```

---

### 2.4 **TaskProvider Boundary** — Existing Callbacks, One Bug Fix (REQ-005, REQ-009)

**Verified against source** (`task_provider.ex:76-83`, `run_executor.ex:99-130`,
`beads_adapter.ex:1651-1985`) — this section previously claimed
`complete/2` didn't exist and proposed new `start_execution/2`,
`complete_execution/2`, `fail_execution/3` callbacks. That premise was
never checked against source and was wrong: `claim/3`, `complete/3`,
and `fail/3` are already declared on the `TaskProvider` behaviour, are
already implemented by `BeadsAdapter`, and are **already called by
`RunExecutor`** (`provider_module.claim/3` at line 100,
`provider_module.complete/3` at line 113, `provider_module.fail/3` at
line 129). No new callbacks are needed, and REQ-009's provider-agnostic
naming is already satisfied by the existing contract — it predates
this PRD (TRD-2026-48f7b420).

**The one real gap**: `BeadsAdapter.fail/3` (`beads_adapter.ex:1946,1956`)
hardcodes `"--status", "open"` on both the `:update` request map and the
argv list, contradicting this PRD's requirement that a terminal failure
moves the bead to `blocked` (AC-005-4). This is the "shipped code must
change" item the PRD's own §6 Self-Critique item 2 already names. Fix:
change both hardcoded `"open"` literals to `"blocked"`.

**Also genuinely new** (no existing implementation found):
- `ForemanServer.Workflow.FailureClassifier.classify/1` — does not exist
- A transient retry loop around `RunExecutor`'s existing dispatch path —
  does not exist; today a dispatch failure calls the existing `fail/3`
  wrapper immediately, with no retry and no transient/permanent
  distinction

The retry loop wraps the *existing* dispatch call, and on final
(permanent or transient-exhausted) failure invokes the *existing*
`fail/3` call site (line 129) — it does not add a new call site or a
new callback.

---

### 2.5 **Workflow.Catalog.Doctor** — Type Coverage Reporting (REQ-002)

**New**: `foreman doctor` reports unmapped types.

**Implementation**:
1. Query all non-closed issues from the project's Beads store via `BeadsAdapter.list_ready` (or new method)
2. Extract distinct `issue_type` values
3. For each type, check `Catalog.type_to_workflow(type)` — if nil, it's unmapped
4. Report every unmapped type by name (AC-002-1, AC-002-2)

**Output shape**:
```
Workflow Type Coverage
├─ Mapped types: foreman_prd, foreman_implement_trd (2)
└─ Unmapped types in store: custom_analysis, research_task (2)

⚠️  Unmapped types found. Update workflow manifests or beads issue_types.
```

---

## 3. Data Flow Diagram (ASCII)

```
┌─────────────────────────────────────────────────────────────────┐
│                         Beads Store                              │
│  [issue_id: 123, issue_type: "foreman_prd", status: "open"]     │
└─────────────────────────────┬───────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  BeadsWatcher   │ (tail mode, polling)
                    └────────┬────────┘
                             │
                    ┌────────▼─────────┐
                    │  Status Gate     │ ◄─── only "open" passes
                    │  AC-003-1..3     │      (draft blocked)
                    └────────┬─────────┘
                             │
                    ┌────────▼──────────────┐
                    │  Workflow Selection   │ ◄─── Catalog.type_to_workflow
                    │  REQ-001              │      (unmapped = transient)
                    └────────┬──────────────┘
                             │
                    ┌────────▼──────────────┐
                    │  trd_path Check      │ ◄─── agent_context.trd_path
                    │  AC-007-1..2         │      (missing = blocked+comment)
                    └────────┬──────────────┘
                             │
                    ┌────────▼──────────────┐
                    │  task.create +        │
                    │  task.approve         │ ◄─── auto-approved, :imported
                    │  (dispatch_system)    │
                    └────────┬──────────────┘
                             │
                             ▼
                    ┌────────────────────┐
                    │   RunAdmission     │ ◄─── (scheduler, unchanged)
                    │   → RunExecutor    │
                    └────────┬───────────┘
                             │
                    ┌────────▼──────────────────┐
                    │  start_execution/2       │ ◄─── TaskProvider.start_execution
                    │  (bead → in_progress)    │      AC-005-1
                    └────────┬──────────────────┘
                             │
                    ┌────────▼──────────────────┐
                    │ dispatch_phase_with_retry│ ◄─── attempt 1,2,3
                    │ (3x backoff, transient)  │      FailureClassifier
                    │ AC-005-3..4              │
                    └────┬─────────────────┬───┘
                         │                 │
                    ┌────▼────┐      ┌─────▼─────┐
                    │  Success │      │  Failure  │
                    └────┬─────┘      └─────┬─────┘
                         │                  │
            ┌────────────▼────────┐  ┌──────▼──────────┐
            │ complete_execution  │  │ fail_execution  │
            │ (bead → closed)     │  │ (bead→blocked)  │
            │ AC-005-2            │  │ AC-005-4        │
            └─────────────────────┘  └─────────────────┘
```

---

## 4. Failure Classification Strategy

### 4.1 Classification Matrix

| Error Pattern | Cause Type | Classification | Action |
|---|---|---|---|
| `{:error, :model_unavailable}` | Infrastructure | Transient | Retry (3×) |
| `{:error, :provider_timeout}` | Infrastructure | Transient | Retry (3×) |
| `{:error, :database_connection_failed}` | Infrastructure | Transient | Retry (3×) |
| `{:error, :validation_failed, ...}` | Workflow | Permanent | Block, no retry |
| `{:error, :phase_terminal, ...}` | Design | Permanent | Block, no retry |
| `{:error, :agent_error, ...}` | Agent | Permanent | Block, no retry |
| Anything not explicitly transient | Unknown | Permanent | Block, safe default |

### 4.2 FailureClassifier Implementation Shape

```elixir
defmodule ForemanServer.Workflow.FailureClassifier do
  @transient_patterns [
    {:error, :model_unavailable},
    {:error, :provider_unavailable},
    {:error, :database_unavailable},
    {:error, :network_error},
    {:error, {:worker_dispatch_error, _}}
  ]

  def classify(error) do
    case error do
      pattern when pattern in @transient_patterns ->
        {:transient, inspect(error)}
      {:error, :validation_failed, _} ->
        {:permanent, "validation error"}
      {:error, :phase_terminal, _} ->
        {:permanent, "phase terminal"}
      {:error, _} ->
        {:permanent, "unknown error"}
      _ ->
        {:permanent, "unexpected outcome"}
    end
  end
end
```

---

## 5. Integration Points

| Component | Changed | Change Type | REQ |
|---|---|---|---|
| `Workflow.Catalog` | New field `task_types:` | YAML parse, reverse map | REQ-001 |
| `Workflow.Catalog.Doctor` | New command | Status reporting | REQ-002 |
| `BeadsWatcher.process_line/2` | Add status gate | Gate logic | REQ-003 |
| `BeadsWatcher.process_line/2` | Workflow selection | Query Catalog | REQ-001 |
| `BeadsWatcher.process_line/2` | trd_path check | Query agent_context | REQ-007 |
| `RunExecutor.dispatch_phase/4` | Retry logic | 3× backoff loop | REQ-005 |
| `RunExecutor.dispatch_phase/4` | Failure classify | New FailureClassifier | REQ-005 |
| `RunExecutor` (phase start) | Status sync | Existing `claim/3` call site already fires (line 100) | REQ-005, AC-005-1 |
| `RunExecutor` (phase end) | Status sync | Existing `complete/3`/`fail/3` call sites (lines 113, 129) | REQ-005, AC-005-2/4 |
| `BeadsAdapter.fail/3` | Bug fix | Hardcoded `"open"` → `"blocked"` (2 literals) | REQ-005 |
| `CLI (foreman task *)` | Bare subcommand deletion | Reject all `task.*` commands via standard "unknown command" | REQ-006 |

---

## 6. Testing Strategy (Preview for Phase 5)

### Unit Tests
- **FailureClassifier**: parametrized test over all error shapes
- **Catalog.type_to_workflow**: collision detection, type resolution
- **BeadsWatcher**: status gate, workflow selection, trd_path extraction
- **RunExecutor retry loop**: transient hold, exponential backoff (1s/5s/15s schedule), exhaustion
- **CLI `task.*` removal**: invoking any removed subcommand produces the CLI's standard "unknown command" error, no side effect
- **Catalog.Doctor**: default output is ASCII tree; `--json` produces valid, equivalent machine-readable output
- **BeadsWatcher telemetry**: each skip reason (unmapped_type, missing_trd_path, draft_status) emits its own distinct event bucket, not a shared `:skipped` event

### Integration Tests
- **E2E watcher → RunExecutor**: draft (skip) → open (import) → dispatch → transient (retry) → success
- **Failure classification in-context**: run with transient error, observe 3 retries, then permanent
- **Status sync round-trip**: open → in_progress → closed (via `br show`)

### Adversarial Tests
- Unmapped workflow type: hold transient, emit telemetry
- Missing trd_path + required workflow: move to blocked, operator retries with `br update --agent-context`
- Transient failure (attempt 1): hold, emit telemetry, wait 1s before retry
- Transient failure (attempt 3, exhausted): mark blocked, no more retries

---

## 7. Assumptions & Constraints

1. **Beads interface stability**: `br update --status`, `br close`, `agent_context` (JSON) remain as documented
2. **Transient classification is heuristic**: The classifier pattern-matches error envelopes; edge cases may need tuning post-launch
3. **No new persistence layer**: Retry state (attempt count) is in-memory only; restarts reset the counter (conservative; failed run may be re-approved manually)
4. **Single operator, concurrent manual writes possible**: One human operator, but that operator's manual `br update`/`bv --robot-plan` commands may run concurrently with Foreman execution — this is exactly what the watcher's `BeadsDbLease` acquisition (§7.5, decision 2) serializes against, not assumed away.
5. **One run per task**: Task → Task.run_id (1:1 current session); multiple runs per task are out of scope

---

## 7.5 Ratified Architectural Risk Decisions (2026-09-12)

Three risks identified during architecture design were resolved by interview with the operator:

1. **Coverage drift at watcher boot**: If `br sync --status --json` reports `coverage_drift == true`, the watcher refuses to start its boot-time full-replay and alerts the operator with the drift counts, rather than silently importing a partial snapshot.
2. **Watcher/BeadsDbLease scope**: The watcher acquires the existing `BeadsDbLease` during boot-time full-replay and each periodic catch-up tail, so a manual `br update` or `bv --robot-plan` mutation mid-scan cannot race the watcher's reads.
3. **Status transition detection**: The watcher uses a filesystem watch on `.beads/issues.jsonl` as the primary (sub-second) trigger, backed by a periodic poll as an eventual-consistency backstop.

Exact implementation parameters (poll interval, debounce window, telemetry event names, watch library) are Phase 3 task-level decisions, not yet ratified.

---

## 8. Resolved Design Decisions (2026-09-12, via interview)

1. **Backoff schedule**: 1s → 5s → 15s, 3 attempts (revised from 100ms/1000ms — agent dispatch failures operate on a slower timescale than network retries).
2. **`task.*` command removal behavior**: Bare deletion, standard CLI "unknown command" error, no guided-migration message, no distinct exit code. (Reverses PRD REQ-006's original guided-error resolution — see PRD changelog 1.3.0.)
3. **Doctor output format**: ASCII tree by default; `--json` flag for machine-readable output.
4. **Transition comment on missing trd_path**: `"Blocked: workflow requires trd_path in agent_context. Re-run: br update <id> --agent-context '{\"trd_path\":\"docs/TRD/...\"}' --status open"`.
5. **Telemetry granularity**: Finer-grained than the original draft — separate event buckets per skip reason (e.g. `[:watcher, :status_gate, :skipped, :unmapped_type]`, `[:watcher, :status_gate, :skipped, :missing_trd_path]`, `[:watcher, :status_gate, :skipped, :draft_status]`), not one coarse `:skipped` event.

---

## 9. Relationship to PRD

| PRD Req | Architecture Component | Delivery |
|---|---|---|
| REQ-001 | Catalog + type_to_workflow map | ✓ In 2.2 |
| REQ-002 | Catalog.Doctor + type coverage | ✓ In 2.5 |
| REQ-003 | BeadsWatcher status gate | ✓ In 2.2 |
| REQ-004 | Full-replay-on-boot (existing) | ✓ Reuse TRD-81315f37 |
| REQ-005 | FailureClassifier (new) + retry loop (new) + fail/3 bug fix; claim/complete/fail already wired | ✓ In 2.3, 2.4 (corrected) |
| REQ-006 | CLI bare command removal | ✓ Resolved 2026-09-12 (§8.2) |
| REQ-007 | BeadsWatcher + agent_context.trd_path | ✓ In 2.2 |
| REQ-008 | Restore implement-trd.yaml, implement-trd-beads.yaml | Deferred to Phase 3 |
| REQ-009 | Already satisfied by existing `TaskProvider` contract (predates this PRD) | ✓ No new work (§2.4) |

---

## 10. Phase 3 Handoff

**Ready for task breakdown**:
- All 5 design questions resolved via interview (§8)
- Three architectural risks resolved via interview (§7.5)
- Backoff schedule finalized: 1s → 5s → 15s
- Doctor format, transition comment, telemetry granularity finalized
- TRD can proceed to master task list (TRD-001 through TRD-NNN)

**User go-ahead received 2026-09-12.** Proceeding to Phase 3 task breakdown.

---

## Changelog

- **1.6.0** — 2026-09-12 — User reviewed and finalized the corrected
  architecture. Status Draft → Final.
- **1.5.0** — 2026-09-12 — Corrected §2.4's false premise, verified
  against source: `claim/3`, `complete/3`, `fail/3` already exist on
  `TaskProvider` and are already called by `RunExecutor`
  (`run_executor.ex:99-130`) — no new `start_execution`/
  `complete_execution`/`fail_execution` callbacks needed. The one real
  gap is `BeadsAdapter.fail/3` hardcoding `--status open` instead of
  `blocked` (2 literals). REQ-009 traceability corrected: already
  satisfied by the existing contract, no new work. Status Final →
  Draft pending re-review.
- **1.4.0** — 2026-09-12 — User confirmed architecture is complete;
  status Draft → Final. Proceeding to Phase 3 Master Task List
  generation.
- **1.3.0** — 2026-09-12 — Fixed dead code in §2.3's backoff sample: the
  3rd schedule value (15_000ms) was never read (guard blocked
  `Enum.at/2` at attempt 3), so escalation happened immediately with no
  final wait, contradicting the adjacent prose. Clarified via interview:
  3 total attempts, waits of 1s/5s/15s — the 15s is a settle wait before
  escalating to `:transient_exhausted`, not a 4th attempt. Code now
  sleeps on that branch. Remains Draft pending user go-ahead (§10).
- **1.2.0** — 2026-09-12 — ensemble-refine-trd pass: fixed stale REQ-006
  row in §5 Integration Points (was "Guided errors", now bare-removal);
  fixed §2.3's backoff description and code sample (were 100ms/1000ms,
  now match §8.1's ratified 1s/5s/15s schedule); added `prd_reference` to
  frontmatter; added unit-test coverage for the 5 §8-resolved decisions;
  corrected imprecise "§7.5.2" cross-reference to "§7.5, decision 2" (no
  subsection anchors exist in §7.5's plain numbered list). Remains Draft
  pending user go-ahead (§10).
- **1.1.0** — 2026-09-12 — Added §7.5 (three ratified architectural risk
  decisions: coverage drift, watcher-lease scope, status trigger); resolved
  all 5 §8 design questions via interview (backoff schedule, task.*
  removal behavior, doctor format, transition comment text, telemetry
  granularity); fixed §7 assumption #4 (concurrent-write assumption
  contradicted the lease decision); updated §9 REQ-006 traceability row
  to reflect bare-removal resolution. Remains Draft pending user go-ahead
  (§10).
- **1.0.0** — 2026-09-12 — Initial Phase 2.4 architecture design (Option
  B, Full Bidirectional Sync).
