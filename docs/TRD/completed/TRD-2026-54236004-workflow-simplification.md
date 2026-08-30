---
document_id: TRD-2026-54236004
label: trd-workflow-simplification
prd_reference: docs/PRD/PRD-2026-54236004-workflow-simplification.md
prd_label: prd-workflow-simplification
version: 1.0.2
status: Draft
date: 2026-08-17
kind: trd
design_readiness_score: 4.25
---

# TRD-2026-54236004: Workflow Simplification — Curated Run Queue Dispatch

## Document Purpose

This document defines the implementation architecture and delivery plan for `PRD-2026-54236004` (v1.0.0, readiness 4.0, 19 REQs). The PRD micro UUID `54236004` is preserved so PRD/TRD artifacts correlate 1:1; the label prefix changes from `prd-` to `trd-` and is display-only.

## Reused Capabilities

The following existing TRDs provide the foundation; this TRD does not duplicate their work.

| Capability | Source | Reuse |
|---|---|---|
| JIDO harness integration | TRD-2026-8a1f3c2e | JIDO is the constant orchestration layer; `JidoHarnessAdapter` routes via jido-integration. No new runtime needed. |
| `foreman_work_submit` MCP tool | TRD-2026-0eac69b3 | Tool already exists; this TRD adds the `backend` field and validation. |
| WorkRequest aggregate | TRD-2026-0eac69b3 | Already handles `work.submit` → `WorkSubmitted` → `RunExecutor`. No new aggregate. |
| Global run-slot queue | TRD-2026-0eac69b3 | Already handles concurrency limits and FIFO queuing (REQ-006). |
| RunExecutor with `source: :work_request` | TRD-2026-0eac69b3 | Already routes work_request source through JIDO without TaskProvider callbacks. |
| `input` prompt block in snapshots | TRD-2026-0eac69b3 | `{{input.prompt}}` already substitutable at freeze time. |
| MCP auth and server | TRD-2026-0eac69b3 | `/mcp` HTTP mount already in place. |
| Worktree lifecycle via JIDO | TRD-2026-8a1f3c2e | JIDO owns worktree create/delete. Phase 1 preserves after completion (REQ-012). |

**No new foundational capability is required.** All PRD requirements map to existing runtime constructs plus the new curated workflow manifests and Go CLI command.

---

## Architecture Decision

### Selected: Option B — Balanced

Curated Workflow Manifests + Go CLI + Backend Field + Skill-Based Checkpointing + Auto-PR.

Add the `backend` field to `foreman_work_submit`, create the three curated YAML manifests, add the Go CLI command. Phase checkpoint push is implemented in the ensemble skills themselves via `--foreman` (each skill auto-commits/pushes after execution). Auto-PR creation remains an additive hook on `RunExecutor`.

### Alternatives Considered

#### Option A — Minimal (Rejected)

Curated workflow manifests + Go CLI only. Defers checkpoint push, auto-PR, and backend selection to future work.

- **Pros:** Fastest to ship; leverages existing infrastructure.
- **Cons:** Incomplete Phase 1; missing core PRD value (checkpoint, auto-PR).
- **Risk:** Low.
- **Complexity:** ~5 tasks.

#### Option B — Balanced (Selected)

Option A plus: `backend` field, skill-based checkpointing (via `--foreman`), auto-PR creation.

- **Pros:** Full Phase 1 scope delivered; checkpointing is skill-internal, not a new RunExecutor hook; auto-PR is a simple post-workflow hook.
- **Cons:** Requires ensemble skill modification (in a separate worktree per operator instruction).
- **Risk:** Medium.
- **Complexity:** ~22 tasks.

#### Option C — Most Complete (Rejected)

Option B plus: worktree lifecycle management (preserve after run), legacy workflow removal.

- **Pros:** Full Phase 1 scope delivered together.
- **Cons:** Larger PR stack; worktree preservation requires deeper RunExecutor integration.
- **Risk:** Medium-High.
- **Complexity:** ~30 tasks.

---

## System Architecture

### Component Model

```mermaid
flowchart TD
    Operator --> CLI[Go CLI: foreman run submit]
    CLI --> MCP[MCP: foreman_work_submit]
    MCP --> CG[CommandGateway]
    CG --> WR[WorkRequest aggregate]
    WR --> RA[RunAdmission]
    RA --> RS[RunSlots]
    RA --> RE[RunExecutor]
    RE --> JIDO[JIDO Harness]
    JIDO --> JI[jido-integration]
    JI --> Provider[pi | claude | codex | opencode]
    RE -.-> Skills[Ensemble Skills (--foreman)]
    Skills -.-> Git[git add && commit && push per phase]
    RE --> APR[auto_pr]
    APR --> GH[gh pr create]
```

### Components and Responsibilities

| Component | Target | Responsibility |
|---|---|---|
| Go CLI `run_submit` | `packages/foreman_cli/cmd/foreman/run.go` (extend) | Accept `--work-id`, `--project-id`, `--workflow`, `--prompt`, `--backend`; POST to MCP `/mcp` |
| `backend` field on `foreman_work_submit` | `packages/foreman_server/lib/foreman_server/mcp/tools.ex` (extend) | Add `backend` to schema; validate against `JidoHarnessAdapter` catalog |
| `prd.yaml` manifest | `packages/foreman_server/priv/defaults/workflows/prd.yaml` (new) | ensemble-prd → ensemble-refine-prd → ensemble-create-trd → ensemble-implement-trd; each skill invoked with `--foreman` for auto-commit/push |
| `trd.yaml` manifest | `packages/foreman_server/priv/defaults/workflows/trd.yaml` (new) | ensemble-create-trd → ensemble-implement-trd; each skill invoked with `--foreman` |
| `fix.yaml` manifest | `packages/foreman_server/priv/defaults/workflows/fix.yaml` (new) | ensemble-fix-issue; invoked with `--foreman` |
| Ensemble skill `--foreman` checkpoint | `~/SunStone/ensemble` (modify in separate worktree) | Each skill auto-commits and pushes to branch after execution when `--foreman` is set; non-fatal on push failure |
| `auto_pr.ex` | `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex` (new) | Post-workflow: `gh pr create` from worktree branch |
| `RunExecutor` post-workflow wiring | `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` (extend) | Call `AutoPR.create/1` after final phase |
| Worktree preservation | `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` (extend) | Do NOT delete worktree after run completion |
| `RunSlots` concurrency verification | `packages/foreman_server/lib/foreman_server/aggregates/run_slots.ex` (verify) | Confirm existing queue mechanism satisfies REQ-006 |
| `workflow remove --all` | `packages/foreman_server/lib/foreman_server_web/controllers/workflow_controller.ex` (extend) | Interactive confirmation; delete legacy manifests from catalog |

### Public Contracts

**`foreman_work_submit` extended schema:**

```json
{
  "name": "foreman_work_submit",
  "inputSchema": {
    "type": "object",
    "properties": {
      "work_id": { "type": "string" },
      "project_id": { "type": "string" },
      "workflow": { "type": "string", "enum": ["prd", "trd", "fix"] },
      "prompt": { "type": "string" },
      "backend": { "type": "string", "enum": ["pi", "claude", "codex", "opencode"] }
    },
    "required": ["work_id", "project_id", "workflow", "prompt"]
  }
}
```

**`auto_pr.ex` contract:**

```elixir
defmodule ForemanServer.Workflow.AutoPR do
  @spec create(RunExecutor.State.t(), workflow :: String.t()) :: :ok | {:error, term()}
end
```

### Data Flow

```
foreman run submit --workflow prd --prompt "..." --backend pi --project-id X --work-id Y
  → Go CLI: run_submit() → POST /mcp {type: "work.submit", backend: "pi", ...}
  → CommandGateway.dispatch_operator(work.submit)
  → WorkRequest: WorkSubmitted
  → RunAdmission.start() — RunSlots.acquire (global slot)
  → RunExecutor (source: :work_request)
        ├── Phase 1: ensemble-prd --foreman
        │     └── skill auto-commits: git add -A && git commit -m "checkpoint: phase-1" && git push [-u origin branch]
        ├── Phase 2: ensemble-refine-prd --foreman (autonomous)
        │     └── skill auto-commits: git add -A && git commit -m "checkpoint: phase-2" && git push
        ├── Phase 3: ensemble-create-trd --foreman
        │     └── skill auto-commits: git add -A && git commit -m "checkpoint: phase-3" && git push
        └── Phase 4: ensemble-implement-trd --foreman
              └── AutoPR.create(state, "prd") → gh pr create
```

### Configuration

```elixir
config :foreman_server, :curated_workflows,
  enabled: true,
  allowed_workflows: ["prd", "trd", "fix"]

config :foreman_server, :auto_pr,
  enabled: true,
  base_branch_source: :run_context  # derived from worktree config, not hardcoded
```

---

## Master Task List

### PR 0: Ensemble Worktree Setup (Prerequisite)

**Shippable State:** A separate worktree exists for `~/SunStone/ensemble` before any skill modifications begin.

- [ ] **TRD-016**: Create worktree for `~/SunStone/ensemble` before modifying skills (1h) [satisfies INFRA]
  - **Target:** `~/SunStone/ensemble`
  - **Implementation AC:**
    - Given skill modifications are needed, when the operator begins TRD-006, then a separate worktree for `~/SunStone/ensemble` is created first.
    - Given the worktree is created, when skill modifications are ready, then they are made in the worktree, not the main ensemble checkout.

---

### PR 1: Run Submit CLI + Backend Field

**Shippable State:** `foreman run submit --workflow prd --prompt "..." --project-id X --work-id Y` queues a run via the MCP endpoint and returns a run ID.

- [ ] **TRD-001**: Add `backend` field to `foreman_work_submit` MCP schema and handler (1h) [satisfies REQ-001] [satisfies REQ-002]
  - **Target:** `packages/foreman_server/lib/foreman_server/mcp/tools.ex`
  - **Validates PRD ACs:** AC-001-2, AC-001-3, AC-002-1, AC-002-2, AC-010-2, AC-010-3
  - **Implementation AC:**
    - Given `foreman_work_submit` is called with `backend: "unknown"`, when the handler runs, then it returns an error with installation instructions.
    - Given `foreman_work_submit` is called with `backend: "pi"` (default), when JIDO is available, then the run proceeds.
    - Given `foreman_work_submit` is called without `backend`, when JIDO is available, then the default backend (pi) is used.

- [ ] **TRD-002**: Add `run_submit()` function to Go CLI (3h) [satisfies REQ-001] [satisfies REQ-016]
  - **Target:** `packages/foreman_cli/cmd/foreman/run.go`
  - **Validates PRD ACs:** AC-001-1, AC-016-1, AC-016-2
  - **Implementation AC:**
    - Given `foreman run submit --work-id X --project-id Y --workflow prd --prompt "..."`, when the command runs, then it POSTs to `/mcp` with the correct envelope including `backend` if specified.
    - Given `--backend` is omitted, when the command runs, then `backend` is excluded from the payload (server uses default).
    - Given required flags are missing, when the command runs, then it prints usage and exits non-zero.

- [ ] **TRD-001-TEST**: Backend field validation tests (1h) [verifies TRD-001] [depends: TRD-001]
  - **Target:** `packages/foreman_server/test/foreman_server/mcp/tools_test.exs`
  - **Validates PRD ACs:** AC-002-1, AC-002-2

- [ ] **TRD-002-TEST**: CLI submit integration tests (2h) [verifies TRD-002] [depends: TRD-002]
  - **Target:** `packages/foreman_cli/cmd/foreman/run_test.go`

---

### PR 2: Three Curated Workflow Manifests

**Shippable State:** `foreman run submit --workflow prd --prompt "..."` loads `prd.yaml` from the catalog and executes the full ensemble chain with `--foreman` checkpointing per phase.

- [ ] **TRD-003**: Create `prd.yaml` curated workflow manifest (2h) [satisfies REQ-003] [satisfies REQ-009]
  - **Target:** `packages/foreman_server/priv/defaults/workflows/prd.yaml`
  - **Validates PRD ACs:** AC-003-1, AC-009-1, AC-009-2, AC-009-3
  - **Implementation AC:**
    - Given `prd.yaml` is loaded, when `foreman_work_submit` is called with `workflow: "prd"`, then the manifest is resolved from the catalog.
    - Given the workflow starts, when phases execute, then they run in sequence: ensemble-prd --foreman → ensemble-refine-prd --foreman → ensemble-create-trd --foreman → ensemble-implement-trd --foreman.
    - Given ensemble-refine-prd runs, when recommendations are available, then the top recommendation is selected autonomously (no operator prompt).
    - Given autonomous selection is made, then it is logged in run artifacts.
    - Given `--foreman` is passed to a phase skill, when the skill completes, then it commits and pushes the worktree state to the branch.

- [ ] **TRD-004**: Create `trd.yaml` curated workflow manifest (1h) [satisfies REQ-003] [satisfies REQ-017]
  - **Target:** `packages/foreman_server/priv/defaults/workflows/trd.yaml`
  - **Validates PRD ACs:** AC-003-2, AC-017-1, AC-017-2

- [ ] **TRD-005**: Create `fix.yaml` curated workflow manifest (1h) [satisfies REQ-003] [satisfies REQ-017]
  - **Target:** `packages/foreman_server/priv/defaults/workflows/fix.yaml`
  - **Validates PRD ACs:** AC-003-3, AC-017-1, AC-017-2

- [ ] **TRD-003-TEST**: Curated workflow manifest resolution tests (2h) [verifies TRD-003, TRD-004, TRD-005] [depends: TRD-003, TRD-004, TRD-005]
  - **Target:** `packages/foreman_server/test/foreman_server/workflow/catalog_test.exs`

---

### PR 3: Skill-Based Phase Checkpointing

**Shippable State:** Each phase skill, when run with `--foreman`, auto-commits and pushes the worktree state to the branch after execution.

- [ ] **TRD-006**: Implement `--foreman` commit/push in ensemble skills (4h) [satisfies REQ-017]
  - **Target:** `~/SunStone/ensemble` (separate worktree, per TRD-016)
  - **Validates PRD ACs:** AC-017-1, AC-017-2
  - **Implementation AC:**
    - Given a skill is invoked with `--foreman`, when the skill completes successfully, then it runs `git add -A && git commit -m "checkpoint: <skill-name>" && git push` in the worktree.
    - Given the push fails (e.g., branch has no upstream), when the push runs, then `git push -u origin <branch>` is used for the first push.
    - Given the push fails for any other reason, when the push runs, then the error is logged and the run continues (non-fatal).
    - Given the skill is invoked without `--foreman`, when the skill completes, then no commit or push occurs.
  - **Note:** This task modifies `~/SunStone/ensemble`. A separate worktree must be created before this task begins (TRD-016).

- [ ] **TRD-006-TEST**: Skill-based checkpoint push tests (2h) [verifies TRD-006] [depends: TRD-006]
  - **Target:** `~/SunStone/ensemble/test` (in ensemble worktree)
  - **Validates PRD ACs:** AC-017-1, AC-017-2

---

### PR 4: Auto-PR Creation

**Shippable State:** When a curated workflow completes, a PR is automatically created from the worktree branch.

- [ ] **TRD-008**: Implement `auto_pr.ex` — post-workflow PR creation (4h) [satisfies REQ-011] [satisfies REQ-019]
  - **Target:** `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex` (new)
  - **Validates PRD ACs:** AC-011-1, AC-011-2, AC-019-1, AC-019-2
  - **Implementation AC:**
    - Given a curated workflow (prd/trd/fix) reaches the final phase, when it completes, then `gh pr create` is called from the worktree branch.
    - Given PR creation fails, when the workflow ends, then the failure is logged and the operator is notified.
    - Given the target base is determined, then it is derived from run/worktree context or config, not hardcoded to default branch.
    - Given `gh` is not authenticated in the worktree, when PR creation is attempted, then the failure is logged with instructions for authentication.

- [ ] **TRD-009**: Wire `auto_pr` into `RunExecutor` as a post-workflow handler (2h) [satisfies REQ-011] [depends: TRD-008]
  - **Target:** `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
  - **Validates PRD ACs:** AC-011-1

- [ ] **TRD-008-TEST**: Auto-PR creation tests (2h) [verifies TRD-008, TRD-009] [depends: TRD-008, TRD-009]
  - **Target:** `packages/foreman_server/test/foreman_server/workflow/auto_pr_test.exs`

---

### PR 5: Run Recovery — Restart from Event Stream

**Shippable State:** An interrupted run can be restarted from the beginning using its event stream.

- [ ] **TRD-010a**: Implement event stream replay and state reconstruction in `RunAdmission` (3h) [satisfies REQ-005]
  - **Target:** `packages/foreman_server/lib/foreman_server/run_admission.ex`
  - **Validates PRD ACs:** AC-005-1, AC-005-2
  - **Implementation AC:**
    - Given a run is interrupted, when `foreman run get <id>` is called, then the current state is returned from the event stream.
    - Given run state is insufficient for recovery, when recovery is attempted, then a clear error is reported and work is not silently lost.
    - Given the event stream is replayed, when events are processed, then the run state is reconstructed from persisted events.

- [ ] **TRD-010b**: Implement restart-from-beginning and operator resume command (2h) [satisfies REQ-005] [depends: TRD-010a]
  - **Target:** `packages/foreman_server/lib/foreman_server/run_admission.ex`
  - **Validates PRD ACs:** AC-005-1, AC-005-3
  - **Implementation AC:**
    - Given an interrupted run is restarted, when recovery is attempted, then the run restarts from the beginning using the event stream.
    - Given `foreman run resume <id>` is called, when the run is resumable, then it restarts from the beginning.

- [ ] **TRD-010-TEST**: Run recovery tests (3h) [verifies TRD-010a, TRD-010b] [depends: TRD-010a, TRD-010b]
  - **Target:** `packages/foreman_server/test/foreman_server/run_admission_recovery_test.exs`

---

### PR 6: Worktree Preservation + Concurrency Queue Verification

**Shippable State:** Worktree is preserved after run completion for operator review.

- [ ] **TRD-011**: Worktree preservation after run completion (2h) [satisfies REQ-004] [satisfies REQ-012]
  - **Target:** `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
  - **Validates PRD ACs:** AC-004-2, AC-012-1, AC-012-2
  - **Implementation AC:**
    - Given a run completes, when the operator is absent, then the worktree is NOT deleted.
    - Given the operator invokes cleanup, when cleanup is called, then the worktree is removed.

- [ ] **TRD-012**: Verify concurrency queue via existing `RunSlots` (1h) [satisfies REQ-006]
  - **Target:** `packages/foreman_server/lib/foreman_server/aggregates/run_slots.ex`
  - **Validates PRD ACs:** AC-006-1, AC-006-2
  - **Note:** RunSlots already handles concurrency (from TRD-2026-0eac69b3). This task verifies the existing mechanism satisfies REQ-006 and documents the integration.

---

### PR 7: Backend Availability Check

**Shippable State:** `foreman run submit --backend unknown` fails with descriptive error and installation instructions.

- [ ] **TRD-013**: Backend availability check in MCP handler (2h) [satisfies REQ-002]
  - **Target:** `packages/foreman_server/lib/foreman_server/mcp/tools.ex`
  - **Validates PRD ACs:** AC-002-1, AC-002-2, AC-002-3
  - **Implementation AC:**
    - Given `foreman_work_submit` is called with an unknown `backend`, when the handler runs, then it returns an error describing the backend and how to install it.
    - Given no `backend` is specified and the default is unavailable, when the handler runs, then it returns an error.

- [ ] **TRD-013-TEST**: Backend availability tests (1h) [verifies TRD-013] [depends: TRD-013]
  - **Target:** `packages/foreman_server/test/foreman_server/mcp/backend_availability_test.exs`

---

### PR 8: Legacy Workflow Removal

**Shippable State:** `foreman workflow remove --all` removes all legacy workflows after interactive confirmation.

- [ ] **TRD-014**: Implement `foreman workflow remove` with interactive confirmation (3h) [satisfies REQ-015]
  - **Target:** `packages/foreman_server/lib/foreman_server_web/controllers/workflow_controller.ex` (extend)
  - **Validates PRD ACs:** AC-015-1, AC-015-2, AC-015-3
  - **Implementation AC:**
    - Given `foreman workflow remove --all` is called, when the operator confirms interactively, then all legacy workflows are removed from the catalog.
    - Given the operator does not confirm, when the command runs, then no changes are made and the command exits.
    - Given legacy workflows are removed, when recovery is needed, then the workflows can be restored from git.

- [ ] **TRD-014-TEST**: Legacy workflow removal tests (1h) [verifies TRD-014] [depends: TRD-014]
  - **Target:** `packages/foreman_server/test/foreman_server/workflow/workflow_removal_test.exs`

---

## Sprint Planning

### Sprint 1: Foundation
- TRD-016, TRD-001, TRD-002, TRD-001-TEST, TRD-002-TEST
- TRD-003, TRD-004, TRD-005, TRD-003-TEST

### Sprint 2: Skill Checkpointing + Auto-PR
- TRD-006 (ensemble skill modifications), TRD-006-TEST
- TRD-008, TRD-009, TRD-008-TEST

### Sprint 3: Recovery and Polish
- TRD-010a, TRD-010b, TRD-010-TEST
- TRD-011, TRD-012
- TRD-013, TRD-013-TEST
- TRD-014, TRD-014-TEST

---

## Acceptance Criteria Traceability

| REQ-NNN | Description | Implementation Tasks | Test Tasks |
|---------|-------------|----------------------|------------|
| REQ-001 | Run Submit CLI Command | TRD-002 | TRD-002-TEST |
| REQ-002 | Backend Availability Check | TRD-001, TRD-013 | TRD-001-TEST, TRD-013-TEST |
| REQ-003 | Three Curated Workflows | TRD-003, TRD-004, TRD-005 | TRD-003-TEST |
| REQ-004 | Worktree-Based Execution | TRD-011 | — |
| REQ-005 | Run Recovery | TRD-010a, TRD-010b | TRD-010-TEST |
| REQ-006 | Concurrency Limits | TRD-012 | — |
| REQ-007 | Logs and Artifacts | — | Covered by existing JIDO runtime (TRD-2026-8a1f3c2e): logs written to ~/.foreman/logs/{run-id}; artifacts via foreman run get |
| REQ-008 | No Artificial Timeout | — | Covered by existing runtime behavior (TRD-2026-0eac69b3): no timeout enforcement in RunExecutor |
| REQ-009 | Autonomous Recommendation Selection | TRD-003 | — |
| REQ-010 | JIDO as Orchestration Layer | — | Covered by existing JIDO harness (TRD-2026-8a1f3c2e) |
| REQ-011 | Automatic PR Creation | TRD-008, TRD-009 | TRD-008-TEST |
| REQ-012 | Worktree Lifecycle — Preserve for Review | TRD-011 | — |
| REQ-013 | Single Worktree for PRD Chain | — | Covered by existing JIDO worktree lifecycle (TRD-2026-8a1f3c2e); worktree created once, reused across phases |
| REQ-014 | Backend-Agnostic (Phase 2) | — | Deferred to Phase 2; Phase 1 uses JIDO+Pi |
| REQ-015 | Remove Legacy Workflows | TRD-014 | TRD-014-TEST |
| REQ-016 | Work Submit CLI Command (Go) | TRD-002 | TRD-002-TEST |
| REQ-017 | Phase Checkpoint Push | TRD-004, TRD-005, TRD-006 | TRD-006-TEST |
| REQ-018 | Ensemble Backend-Agnostic (Phase 2) | — | Deferred to Phase 2 |
| REQ-019 | PR Lifecycle | TRD-008 | TRD-008-TEST |

---

## Traceability Validation

**Traceability check: 19 requirements accounted for (13 via new TRD tasks; 4 via existing infrastructure; 2 deferred to Phase 2), 0 uncovered, 0 orphaned annotations.**

---

## Open Questions (Resolved)

| # | Question | Resolution |
|---|----------|------------|
| 1 | Backend selection mechanism | `--backend` CLI flag; server validates against `JidoHarnessAdapter` catalog; default = pi |
| 2 | PR creation | Automatic after final phase via `AutoPR.create/1` |
| 3 | Worktree cleanup | Worktree preserved after completion; manual cleanup |
| 4 | PRD workflow chaining | One worktree through all 4 steps via RunExecutor source: work_request |
| 5 | Existing workflows | Removed via `foreman workflow remove --all` with interactive confirmation |
| 6 | Backend-agnostic | Phase 1: JIDO+Pi only; Phase 2 deferred |
| 7 | Checkpoint implementation | Skill-based via `--foreman` flag in ensemble skills (TRD-006); manifests updated (TRD-004, TRD-005) |

---

### v1.0.2 — 2026-08-17

- **Refinement:** Removed `[satisfies REQ-010]` from TRD-001 (REQ-010 = existing JIDO harness infrastructure; no new work required). Updated traceability: REQ-010 moved to existing infrastructure column.
- **Refinement:** Fixed TRD-016 stale reference to non-existent TRD-015 — now references only TRD-006.
- **Refinement:** Split TRD-010 (5h) into TRD-010a (3h: event stream replay + state reconstruction) and TRD-010b (2h: restart-from-beginning + operator resume) [depends: TRD-010a]. Updated TRD-010-TEST to verify both.
- **Refinement:** Added `[depends: TRD-009]` to TRD-008-TEST to ensure RunExecutor wiring is complete before test execution.
- **Refinement:** Updated sprint planning: added `### Sprint 3:` heading; moved TRD-010a/b and remaining tasks to Sprint 3.
- **Refinement:** Corrected traceability summary from 15+3+1 to 13+4+2 (19 total).

### v1.0.1 — 2026-08-17

- **Refinement:** Checkpointing moved from `phase_checkpoint.ex` (Elixir hook) to ensemble skill `--foreman` flag. TRD-006 retargeted to `~/SunStone/ensemble` skill modification (in separate worktree). TRD-007 removed (no RunExecutor hook needed). TRD-004 and TRD-005 now explicitly cover REQ-017 for trd.yaml and fix.yaml manifests.
- **Refinement:** Added TRD-016 as prerequisite worktree creation for `~/SunStone/ensemble` before skill modifications.
- **Refinement:** Added `--foreman` commit/push AC to TRD-003 manifest task.
- **Refinement:** Removed `phase_checkpoint.ex` component, contract, and configuration from System Architecture section.
- **Refinement:** Updated data flow to show `--foreman` skill flag per phase instead of `PhaseCheckpoint.after_phase` hook.
- **Refinement:** Updated component table to reflect skill-based checkpointing and remove `phase_checkpoint.ex`.
- **Refinement:** Added PR 0 (TRD-016) as prerequisite before PR 3.
- **Refinement:** Updated sprint planning to reflect new task order.
- **Refinement:** Updated traceability: REQ-017 now covered by TRD-004, TRD-005, TRD-006 (was TRD-006, TRD-007).
- **Refinement:** PRD reference version corrected from 1.0.0 to 1.0.1.

---

*Generated via ensemble:create-trd — Phase 1 scope. Refined via ensemble:refine-trd.*
