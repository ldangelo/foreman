---
document_id: PRD-2026-c7977e9d
label: prd-operator-run-dashboard
version: 1.0.1
status: Draft
date: 2026-09-23
scale_depth: STANDARD
total_requirements: 14
total_acceptance_criteria: 45
readiness_score: 4.8
---

# PRD: Operator Dashboard for Run Management

Foreman task title read from user-delivered Foreman subject: **Add operator dashboard for run management**

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 10 |
| Should | 4 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 14/14 (100%) |
| Acceptance criteria coverage | 45/45 (100%) |
| Risk flags | 8 |
| Dependencies | 13 |
| Open ambiguity markers | 0 |
| TRD decisions required | 2 |

## Acceptance Criteria Summary

| Requirement | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Provide one operator dashboard entry point | Must | Medium | 3 |
| REQ-002 | List runs with task context | Must | Medium | 4 |
| REQ-003 | Show run and phase status clearly | Must | Medium | 3 |
| REQ-004 | Show run logs | Must | High | 3 |
| REQ-005 | Show code changes and review targets | Must | High | 4 |
| REQ-006 | Support stop control | Must | High | 3 |
| REQ-007 | Support abandon control | Must | High | 3 |
| REQ-008 | Support restart control | Must | High | 4 |
| REQ-009 | Reuse the old cockpit/dashboard branch as baseline evidence | Must | Medium | 3 |
| REQ-010 | Preserve Foreman source-of-truth boundaries | Must | High | 3 |
| REQ-011 | Enforce auth and unsafe-action confirmation | Should | Medium | 3 |
| REQ-012 | Keep the dashboard live without overloading the server | Should | Medium | 3 |
| REQ-013 | Provide accessible, keyboard-first navigation | Should | Medium | 3 |
| REQ-014 | Document and test the operator workflow | Should | Medium | 3 |

## 1. Executive Summary

Foreman operators need a single dashboard for active and recent runs. Today run state, task context, logs, code changes, and run-control actions are spread across CLI commands, debug views, projections, worktrees, and provider-specific artifacts. This makes it hard to decide whether a run is healthy, blocked, failed, safe to stop, or ready to restart.

This PRD defines an operator dashboard that shows runs, associated tasks, phase/status details, logs, code changes, and control actions. The dashboard must support stop, abandon, and restart, backed by Foreman's existing run-control/domain boundaries rather than direct event-store or database writes. An old branch with similar cockpit/dashboard work exists and must be mined as a baseline, not blindly restored.

Foreman mode auto-selected STANDARD depth and skipped interviews. Refinement resolved the three ambiguity markers using best-effort defaults: confirmed the historical cockpit branch, selected a web-first initial surface, and mapped stop to pause/resumable stop.

## 2. Background and Evidence

Current source evidence:

- `packages/foreman_server/lib/foreman_server_web/router.ex` exposes JSON APIs for projects, tasks, runs, queue, and commands.
- `packages/foreman_server/lib/foreman_server_web/controllers/run_controller.ex` supports `GET /api/runs` and `GET /api/runs/:id` from `ProjectionStore`.
- `packages/foreman_server/lib/foreman_server_web/live_dashboard.ex` exists, but it is Jido/agent-oriented rather than a run-management cockpit.
- `ForemanServer.RunControl` and run commands already cover control primitives such as cancel/pause/resume/remove/reset.
- Durable run logs are projection-backed; `foreman_run_get_logs` and worker events are the source for run logs, not ordinary server logs.
- Confirmed historical baseline branch: `origin/fix/cockpit-close-run-row`. Evidence paths include `clients/cockpit/`, `clients/cockpit/run_actions.go`, `clients/cockpit/README.md`, and `docs/TRD/TRD-2026-019-operator-dashboard.md`.
- Reusable concepts from the baseline include keyboard-first navigation, run action affordances, logs/reports/files/PR tabs, changed-file diff handling, bounded panes, and non-color focus/selection markers.
- Stale baseline concepts include removed or unverified command/API assumptions such as `foreman board`, `foreman inbox`, task create/approve/update CLI flows, `/api/v1` store reads, and direct old cockpit retry/attach semantics.

## 3. Goals

- Give operators one place to understand run health, status, task context, logs, code changes, PR/check state, and next action.
- Make stop, abandon, and restart available from the dashboard with safe confirmation and clear outcomes.
- Reuse validated ideas from the old cockpit/dashboard branch where they still fit the current Elixir/Phoenix/Go CLI architecture.
- Preserve Foreman's typed command/event boundaries and projection-backed read model.

## 4. Non-Goals

- No direct writes to Beads SQLite, Foreman event-store tables, or projection state from the dashboard.
- No replacement for `foreman run *` CLI commands in this release.
- No new workflow engine semantics.
- No implementation of arbitrary task editing unless required for run-control UX.
- No provider-specific terminal attach requirement unless the TRD proves it is safe and already supported.

## 5. Personas

- **Foreman operator:** monitors runs, identifies stuck/failed work, reviews outputs, and chooses stop/abandon/restart actions.
- **Maintainer:** needs the dashboard to use existing APIs and commands, with tests proving no boundary bypass.
- **Reviewer:** uses code-change and log views to decide whether a run produced useful work.
- **Incident responder:** needs safe controls and clear audit trail when a run is consuming resources or blocking the queue.

## 6. Assumptions

- The first shippable surface should be web-first via Phoenix/Phoenix LiveView because the server already owns authenticated HTTP/API boundaries and can reuse projection reads without reviving stale CLI/TUI command assumptions. The old Go cockpit remains baseline evidence for layout, keyboard, and interaction patterns, not the initial delivery vehicle.
- Stop means `run pause`: halt active execution, commit partial work where supported, keep the run resumable, and preserve forensic context. A terminal `run cancel` action may exist only if labeled separately as Cancel, not as Stop.
- Abandon means "make this run no longer actionable and clean/release resources when safe".
- Restart means "start a new attempt from a safe state or resume a paused one, preserving auditability".
- Operators are authenticated through existing Foreman auth/token mechanisms.

## 7. Requirements

### REQ-001: Provide one operator dashboard entry point

Priority: Must  
Complexity: Medium

Foreman MUST provide a discoverable web-first dashboard entry point for run management.

- AC-001-1: Given the Foreman server is running, when an authenticated operator opens the web dashboard entry point, then the operator sees a run-management dashboard rather than a generic agent dashboard.
- AC-001-2: Given the dashboard loads, when run data is unavailable, then it shows a clear empty/error state without crashing.
- AC-001-3: Given the dashboard entry point is documented, when an operator follows the docs, then they can reach the dashboard with the configured auth method.

### REQ-002: List runs with task context

Priority: Must  
Complexity: Medium

The dashboard MUST list active and recent runs with associated task context.

- AC-002-1: Given projected runs exist, when the dashboard loads, then it lists run id, project id, status, current phase, created/started/completed timestamps when present, and task id when associated.
- AC-002-2: Given a run has task metadata, when the run appears, then the dashboard shows task title and relevant provider identifiers without requiring a separate CLI lookup.
- AC-002-3: Given many runs exist, when the operator filters by status or project, then only matching runs remain visible.
- AC-002-4: Given a run has no task, when it appears, then the dashboard labels it as ad-hoc/no-task rather than failing task lookup.

### REQ-003: Show run and phase status clearly

Priority: Must  
Complexity: Medium

The dashboard MUST make run state and phase progression understandable at a glance.

- AC-003-1: Given a multi-phase run, when selected, then the dashboard shows each phase name, status, start time, completion time, and failure/stall reason when projected.
- AC-003-2: Given a run is paused, cancelled, failed, stuck, completed, or in progress, when displayed, then the status label and color/icon treatment are distinct in text and non-color form.
- AC-003-3: Given a run has latest stall or attention data, when selected, then the dashboard shows that reason from projections rather than recomputing stall rules.

### REQ-004: Show run logs

Priority: Must  
Complexity: High  
Risk: Mixing server logs with worker logs can mislead operators.

The dashboard MUST show durable run logs from the Foreman worker-log path.

- AC-004-1: Given a run has worker stdout/stderr events, when the operator opens logs, then the dashboard shows bounded, ordered log entries from the durable run-log projection/source.
- AC-004-2: Given the run does not exist, when logs are requested, then the dashboard reports a not-found state rather than an empty successful log.
- AC-004-3: Given logs are long, when displayed, then the dashboard supports paging or incremental loading without freezing the UI.

### REQ-005: Show code changes and review targets

Priority: Must  
Complexity: High  
Risk: Worktree/branch state can disappear or drift after cleanup.

The dashboard MUST expose what code or documents a run changed.

- AC-005-1: Given a run has a retained worktree or run branch, when selected, then the dashboard shows changed files relative to the recorded run base when that information is resolvable.
- AC-005-2: Given a run has associated PR metadata, when selected, then the dashboard shows PR URL, branch, and check/merge status when projected or retrievable through existing safe integrations.
- AC-005-3: Given a worktree was cleaned, when selected, then the dashboard shows the available branch/PR/artifact evidence and labels missing local worktree evidence explicitly.
- AC-005-4: Given a changed file is selected, when the operator opens it, then the dashboard launches or links to a read-only/diff review target without mutating the run.

### REQ-006: Support stop control

Priority: Must  
Complexity: High  
Risk: A wrong stop mapping can destroy useful partial work or leave workers running.

The dashboard MUST let authorized operators stop an active run through Foreman's supported pause command path.

- AC-006-1: Given a run is active, when the operator chooses Stop and confirms, then Foreman dispatches `run.pause` through the public command boundary and labels any separate terminal cancellation action as Cancel.
- AC-006-2: Given the pause command succeeds, when the dashboard refreshes, then the run status changes to paused/resumable and the UI shows the result without requiring a manual reload.
- AC-006-3: Given the pause command is rejected, when the dashboard shows the result, then it displays the typed rejection reason and leaves the previous run state visible.

### REQ-007: Support abandon control

Priority: Must  
Complexity: High  
Risk: Abandon can remove worktrees/branches or hide evidence if mapped carelessly.

The dashboard MUST let authorized operators abandon a run safely.

- AC-007-1: Given a run is terminal or no longer wanted, when the operator chooses abandon and confirms, then Foreman uses the supported removal/cleanup command path rather than direct filesystem or branch deletion.
- AC-007-2: Given abandoning may clean resources, when confirmation is shown, then the UI states what will be cleaned, what evidence remains, and whether the action is reversible.
- AC-007-3: Given abandon succeeds, when the dashboard refreshes, then the run no longer appears in default active views but remains discoverable through an explicit removed/abandoned filter if the projection supports it.

### REQ-008: Support restart control

Priority: Must  
Complexity: High  
Risk: Restart can duplicate runs, rerun against stale code, or bypass task-provider state.

The dashboard MUST support restarting a run only through safe Foreman semantics.

- AC-008-1: Given a paused run is resumable, when the operator chooses Restart/Resume, then Foreman dispatches `run.resume` and shows the resulting state.
- AC-008-2: Given a failed/stuck run is eligible for reset, when the operator chooses Restart, then the dashboard offers `run.reset` only where valid and does not expose removed task-retry CLI behavior.
- AC-008-3: Given a run is not eligible for restart, when selected, then the restart action is disabled with a reason.
- AC-008-4: Given restart creates a new attempt or modifies run state, when complete, then the dashboard makes the lineage/audit relation visible enough for the operator to find the prior attempt.

### REQ-009: Reuse the old cockpit/dashboard branch as baseline evidence

Priority: Must  
Complexity: Medium

The TRD MUST inspect the old dashboard branch before designing the new surface.

- AC-009-1: Given `origin/fix/cockpit-close-run-row` is available, when the TRD is written, then it lists reusable concepts, obsolete concepts, and rejected concepts with file/path evidence.
- AC-009-2: Given `clients/cockpit` exists on the old branch, when evaluated, then keyboard navigation, run action patterns, changed-file/diff handling, logs, reports, PR tabs, and bounded layout behavior are considered explicitly.
- AC-009-3: Given old docs mention commands or APIs no longer present, when reused, then the TRD marks them stale instead of copying them into current requirements.

### REQ-010: Preserve Foreman source-of-truth boundaries

Priority: Must  
Complexity: High  
Risk: A dashboard that writes around CommandRouter can corrupt run/task state.

The dashboard MUST use Foreman's existing query and command boundaries.

- AC-010-1: Given the dashboard reads runs, tasks, phases, logs, inbox, and PR data, when source code is reviewed, then reads come from controllers/MCP/projections or approved read APIs, not raw event-store or Beads SQLite reads.
- AC-010-2: Given the dashboard mutates run state, when source code is reviewed, then mutation goes through existing command HTTP/MCP/CLI surfaces that route to `CommandGateway`/`CommandRouter`.
- AC-010-3: Given a required read model is missing, when implementation reaches that gap, then it adds a typed server API/projection path instead of scraping logs or shelling out to private internals.

### REQ-011: Enforce auth and unsafe-action confirmation

Priority: Should  
Complexity: Medium

The dashboard SHOULD protect operational data and destructive controls.

- AC-011-1: Given an unauthenticated operator opens the dashboard, when auth is required, then access is rejected by existing Foreman auth guards.
- AC-011-2: Given stop, abandon, or restart is selected, when the action has side effects, then the operator must confirm before dispatch.
- AC-011-3: Given an action is dispatched, when audit data is available, then the actor, action, target run id, and result are visible in dashboard history or logs.

### REQ-012: Keep the dashboard live without overloading the server

Priority: Should  
Complexity: Medium

The dashboard SHOULD refresh automatically within bounded resource use.

- AC-012-1: Given a run changes state, when the dashboard is open, then the visible state refreshes within 2 seconds under normal local-server conditions.
- AC-012-2: Given the server is slow or unavailable, when refresh fails, then the dashboard keeps the last known state and shows stale/error status.
- AC-012-3: Given many runs exist, when polling or subscriptions are active, then refresh requests are bounded by pagination, filters, or backoff.

### REQ-013: Provide accessible, keyboard-first navigation

Priority: Should  
Complexity: Medium

The dashboard SHOULD be usable without a mouse and without relying only on color.

- AC-013-1: Given the operator uses keyboard navigation, when moving through runs, tabs, logs, and changed files, then every primary view and action is reachable.
- AC-013-2: Given terminal or browser color is unavailable, when statuses are displayed, then text labels or symbols still distinguish them.
- AC-013-3: Given the viewport is narrow, when the dashboard renders, then it degrades to a usable list/detail layout rather than truncating all actionable data.

### REQ-014: Document and test the operator workflow

Priority: Should  
Complexity: Medium

The dashboard SHOULD ship with tests and operator docs for the new workflow.

- AC-014-1: Given implementation is complete, when tests run, then they cover run list rendering, empty/error states, action eligibility, action confirmation, and rejected command display.
- AC-014-2: Given docs are updated, when an operator reads them, then they explain how to open the dashboard, interpret statuses, view logs/changes, and use stop/abandon/restart safely.
- AC-014-3: Given externally visible identifiers are added or changed, when documentation discipline is applied, then `CLAUDE.md`, `AGENTS.md`, `README.md`, `docs/user-guide.md`, and `docs/cli-reference.md` are checked and edited only where behavior changed.

## 8. Non-Functional Requirements

Covered above in REQ-011 through REQ-014. Additional constraints:

- Dashboard must not expose secrets from logs, env, prompts, or tool outputs beyond existing authorized log visibility.
- UI must keep long logs and large diffs bounded by default.
- Action failures must be loud and typed; no silent optimistic success.

## 9. Dependency Map

| Requirement | Depends On | Notes |
|---|---|---|
| REQ-001 | REQ-010 | Entry point must use approved boundary. |
| REQ-002 | REQ-010 | Run/task data source decision. |
| REQ-003 | REQ-002 | Phase detail hangs off selected run. |
| REQ-004 | REQ-002, REQ-010 | Logs must use durable run-log source. |
| REQ-005 | REQ-002, REQ-010 | Code evidence depends on branch/worktree/projection availability. |
| REQ-006 | REQ-010, REQ-011 | Stop must be authenticated and confirmed. |
| REQ-007 | REQ-010, REQ-011 | Abandon must be authenticated and confirmed. |
| REQ-008 | REQ-010, REQ-011 | Restart must be state-aware. |
| REQ-009 | none | Baseline research precedes TRD architecture. |
| REQ-010 | none | Boundary constraint for all other requirements. |
| REQ-011 | REQ-001 | Auth wraps entry/action surface. |
| REQ-012 | REQ-002, REQ-003 | Refresh targets visible state. |
| REQ-013 | REQ-001 | Navigation depends on chosen UI surface. |
| REQ-014 | all | Docs/tests cover delivered behavior. |

Implementation clusters:

1. Baseline research and surface decision: REQ-001, REQ-009, REQ-010.
2. Read-only operator visibility: REQ-002 through REQ-005, REQ-012, REQ-013.
3. Run-control actions: REQ-006 through REQ-008, REQ-011.
4. Release readiness: REQ-014.

No circular dependencies identified.

## 10. Adversarial Review Findings

Foreman mode auto-applied recommended resolutions where possible.

1. **Issue:** "Stop" can mean pause or cancel.  
   **Resolution:** Resolved Stop as `run.pause` / resumable stop. Terminal `run.cancel` may exist only as a separately labeled Cancel action.

2. **Issue:** The old branch may target obsolete APIs and command names.  
   **Resolution:** Confirmed `origin/fix/cockpit-close-run-row` as baseline evidence and required stale-reference rejection for removed commands/APIs.

3. **Issue:** Code-change viewing depends on whether worktrees survive cleanup.  
   **Resolution:** REQ-005 requires explicit missing-evidence states and use of branch/PR/artifact fallback.

4. **Issue:** A dashboard could be implemented by scraping logs or direct stores for speed.  
   **Resolution:** REQ-010 makes typed read/query and command boundaries mandatory.

5. **Issue:** Run-control actions can be destructive.  
   **Resolution:** REQ-011 requires auth, confirmation, and audit visibility.

6. **Issue:** Live refresh can overload a local dev server if implemented as aggressive polling.  
   **Resolution:** REQ-012 requires bounded polling/subscription behavior and stale-state display.

7. **Issue:** UI choice is unresolved.  
   **Resolution:** Resolved the initial delivery surface as web-first Phoenix/LiveView; old Go cockpit informs interaction patterns but is not the primary surface.

8. **Issue:** Logs and diffs can be huge or secret-bearing.  
   **Resolution:** Added bounded-display and existing authorization constraints.

## 11. Implementation Readiness Gate

| Dimension | Score | Rationale |
|---|---:|---|
| Completeness | 5 | Covers visibility, actions, boundaries, baseline reuse, docs/tests, selected initial surface, and stop mapping. |
| Testability | 5 | Requirements have observable ACs and source-boundary checks. |
| Clarity | 4.5 | Requirements are precise; remaining TRD work is design detail rather than product ambiguity. |
| Feasibility | 4.5 | Existing run/task APIs, control commands, logs, and old cockpit branch provide strong starting points. |

Overall readiness score: **4.8 / 5.0**  
Gate decision: **PASS**

## 12. Suggested Next Step

Create a TRD that inspects `origin/fix/cockpit-close-run-row`, designs the web-first Phoenix/LiveView dashboard, and maps stop/abandon/restart to current Foreman run-control commands (`run.pause`, `run.remove`, `run.resume`/`run.reset`) without reviving stale cockpit command assumptions.

Suggested command:

```text
/ensemble-create-trd docs/PRD/PRD-2026-c7977e9d-operator-run-dashboard.md
```


## Changelog

- 2026-09-23 — v1.0.1: Refined PRD in Foreman mode; resolved baseline branch, initial surface, and Stop mapping ambiguities; updated readiness score and health summary.
