---
document_id: TRD-2026-007
prd_reference: PRD-2026-007
version: 1.0.0
status: Draft
date: 2026-03-30
design_readiness_score: 4.25
---

# TRD-2026-007: Epic Execution Mode

## Architecture Decision

### Chosen Approach: Option C — Extended Pipeline Executor

Extend the existing `pipeline-executor.ts` with an outer task loop for epic mode. The pipeline executor is foreman's core — both single-task and epic execution are pipeline execution, just at different granularities.

**Key insight:** The current `executePipeline()` already iterates phases. Epic mode wraps this in a task loop: for each task, execute the task's phases (developer→QA), commit, advance to next task. The `runPhase` callback reuses the same Pi SDK session across tasks for session continuity.

### Alternatives Considered

| Option | Pros | Cons | Rejected Because |
|--------|------|------|------------------|
| A: Thin Wrapper | Minimal code, reuses pipeline-executor directly | No session continuity, separate Pi SDK session per task | Violates REQ-008 |
| B: New Epic Executor | Full control, clean separation | ~500 lines duplication, two code paths to maintain | Divergence risk, violates DRY |

### Architecture Diagram

```
Dispatcher
  │
  ├─ type=task/bug/chore → executePipeline(singleTaskCtx)
  │                          phases: explorer→developer→QA→reviewer→finalize
  │
  └─ type=epic → executePipeline(epicCtx)
                   epicCtx.tasks = [child beads in dependency order]
                   outer loop: for each task
                     inner loop: taskPhases (developer→QA) with retry
                     commit on QA PASS
                   then: finalPhases (finalize) once
```

### Component Boundaries

| Component | File | Responsibility |
|-----------|------|----------------|
| **Dispatcher** | `dispatcher.ts` | Detect epic beads, create shared worktree, build epic context, spawn worker |
| **Pipeline Executor** | `pipeline-executor.ts` | Phase loop (existing) + new outer task loop for epic mode |
| **Epic Workflow Config** | `workflows/epic.yaml` | Define taskPhases, finalPhases, retry limits, timeouts |
| **Workflow Loader** | `workflow-loader.ts` | Parse epic-specific YAML fields (taskPhases, finalPhases) |
| **Agent Worker** | `agent-worker.ts` | Build PipelineContext with epic fields, handle session reuse |
| **Task Ordering** | `bv.ts` + new `task-ordering.ts` | Query bv --robot-next or topological sort fallback |
| **Resume Detection** | `pipeline-executor.ts` | Check git log for completed task commits, skip them |
| **Bead Status** | `task-backend-ops.ts` | Update child bead status as tasks complete |

### Data Flow

```
1. Dispatcher detects epic bead → queries children → sorts by dependency
2. Creates single worktree → runs npm install → writes TASK.md with all tasks
3. Spawns worker with epicMode=true, tasks=[ordered child beads]
4. Worker calls executePipeline() with epic context:
   a. For each task in ctx.tasks:
      - Build task-specific prompt with previous context
      - Run taskPhases (developer→QA) via existing phase loop
      - On QA PASS: vcs.commit(), update bead status, advance
      - On QA FAIL: create bug bead, retry developer (up to retryOnFail)
      - On max retries: mark task failed, apply onError policy
   b. After all tasks: run finalPhases (finalize) once
5. Finalize: rebase, test, push → refinery squash-merges to dev
```

---

## Master Task List

### Sprint 1: Core Epic Runner

#### TRD-001: Add epic workflow YAML fields to WorkflowConfig type and loader
**2h** | [satisfies REQ-002]
- Validates PRD ACs: AC-002-1, AC-002-3
- Implementation ACs:
  - Given a workflow YAML with `taskPhases` array and `finalPhases` array, when `loadWorkflowConfig()` parses it, then `WorkflowConfig.taskPhases` and `WorkflowConfig.finalPhases` are populated
  - Given a workflow YAML without `taskPhases`, when loaded, then `taskPhases` defaults to `undefined` (single-task mode)

#### TRD-001-TEST: Unit tests for epic workflow YAML parsing
**1h** | [verifies TRD-001] [satisfies REQ-002] [depends: TRD-001]
- Test: taskPhases/finalPhases parsed from YAML
- Test: default values when fields absent
- Test: validation error on invalid taskPhases format

#### TRD-002: Create bundled epic.yaml workflow config
**1h** | [satisfies REQ-002]
- Validates PRD ACs: AC-002-1, AC-002-2, AC-002-3
- Implementation ACs:
  - Given `src/defaults/workflows/epic.yaml` exists, when an epic is dispatched, then it uses `taskPhases: [developer, qa]`, `finalPhases: [finalize]`, `qa.retryOnFail: 2`
  - Given the epic workflow config, when QA is configured, then `verdict: true` and `retryWith: developer` are set on the QA phase

#### TRD-003: Create task ordering module with bv fallback
**2h** | [satisfies REQ-004]
- Validates PRD ACs: AC-004-1, AC-004-2
- Implementation ACs:
  - Given an epic bead ID, when `getTaskOrder(epicId)` is called with bv available, then it returns child task IDs from `bv --robot-next` in dependency order
  - Given bv is unavailable, when `getTaskOrder(epicId)` is called, then it falls back to topological sort of child bead dependencies with priority as tiebreaker
  - Given a circular dependency, when topological sort runs, then it throws `CircularDependencyError`

#### TRD-003-TEST: Unit tests for task ordering
**1h** | [verifies TRD-003] [satisfies REQ-004] [depends: TRD-003]
- Test: bv available returns bv order
- Test: bv unavailable falls back to topological sort
- Test: priority tiebreaker when no deps
- Test: circular dependency throws

#### TRD-004: Add epic fields to PipelineContext and PipelineRunConfig
**1h** | [satisfies REQ-001, REQ-004, REQ-008]
- Validates PRD ACs: AC-001-1, AC-004-1
- Implementation ACs:
  - Given `PipelineContext`, when `epicTasks` is set, then it contains an ordered array of `{seedId, seedTitle, seedDescription}` objects
  - Given `PipelineRunConfig`, when `epicId` is set, then the run is linked to the parent epic bead

#### TRD-005: Implement outer task loop in executePipeline for epic mode
**4h** | [satisfies REQ-004, REQ-005, REQ-007] [depends: TRD-001, TRD-004]
- Validates PRD ACs: AC-004-1, AC-004-3, AC-005-1, AC-005-2, AC-005-3, AC-007-1, AC-007-2
- Implementation ACs:
  - Given `ctx.epicTasks` is set (epic mode), when `executePipeline()` runs, then it iterates tasks and for each runs only `taskPhases` from the workflow config
  - Given a task passes QA (verdict PASS), when the task completes, then `vcs.commit(worktreePath, "<title> (<beadId>)")` is called and the next task starts
  - Given a task fails QA with retries remaining, when the retry fires, then the developer phase re-runs with QA feedback context (existing retry logic)
  - Given `ctx.epicTasks` is NOT set (single-task mode), when `executePipeline()` runs, then behavior is identical to current (no regression)
  - Given all tasks complete, when the task loop ends, then `finalPhases` execute once

#### TRD-005-TEST: Integration tests for epic task loop
**3h** | [verifies TRD-005] [satisfies REQ-004, REQ-005, REQ-007] [depends: TRD-005]
- Test: 3 tasks execute in order, each commits
- Test: QA FAIL retries developer, then passes
- Test: QA FAIL exhausts retries, task marked failed
- Test: single-task mode unchanged (no epicTasks)
- Test: finalize runs once after all tasks
- Test: no empty commits after task loop

#### TRD-006: Update dispatcher to detect epic beads and build epic context
**3h** | [satisfies REQ-001, REQ-003] [depends: TRD-003, TRD-004]
- Validates PRD ACs: AC-001-1, AC-001-2, AC-001-3, AC-003-1, AC-003-2
- Implementation ACs:
  - Given a ready bead with type `epic` and children, when the dispatcher encounters it, then it creates a single worktree, queries task order, and spawns an Epic Runner (worker with `pipeline=true` and `epicTasks` in config)
  - Given a ready bead with type `task`, when the dispatcher encounters it, then the standard pipeline path is used (no change)
  - Given an epic running, when counting active agents, then the epic counts as 1 agent slot regardless of how many child tasks it has

#### TRD-006-TEST: Unit tests for epic dispatch
**2h** | [verifies TRD-006] [satisfies REQ-001, REQ-003] [depends: TRD-006]
- Test: epic bead with children dispatches via epic path
- Test: task bead dispatches via standard path
- Test: epic with 0 children auto-closes
- Test: epic counts as 1 agent slot
- Test: epic + one-off tasks coexist within maxAgents

---

### Sprint 2: Session Continuity, Finalize, and Resume

#### TRD-007: Session reuse across tasks via runPhase callback
**3h** | [satisfies REQ-008] [depends: TRD-005]
- Validates PRD ACs: AC-008-1, AC-008-2
- Implementation ACs:
  - Given epic mode, when `runPhase` is called for task N, then it reuses the Pi SDK session from task N-1 (same `sessionId` passed to `session.prompt()`)
  - Given the session hits a token limit, when `runPhase` detects the limit error, then it creates a new session with a summary prompt of completed tasks and continues

#### TRD-007-TEST: Tests for session reuse
**2h** | [verifies TRD-007] [satisfies REQ-008] [depends: TRD-007]
- Test: mock runPhase receives same session handle across tasks
- Test: token limit triggers session refresh with summary
- Test: new session gets context of completed tasks

#### TRD-008: Single finalize phase at epic completion
**2h** | [satisfies REQ-009] [depends: TRD-005]
- Validates PRD ACs: AC-009-1, AC-009-2, AC-009-3
- Implementation ACs:
  - Given all tasks completed, when finalPhases run, then finalize rebases onto target branch, runs tests, and pushes
  - Given finalize test failure, when verdict is FAIL, then the executor loops back to developer with test output (reusing existing verdict retry logic)
  - Given finalize pushes, when the refinery processes the branch, then a single squash-merge commit appears on dev

#### TRD-008-TEST: Tests for epic finalize
**1h** | [verifies TRD-008] [satisfies REQ-009] [depends: TRD-008]
- Test: finalize runs once after all tasks
- Test: finalize FAIL verdict loops to developer
- Test: finalize PASS triggers merge queue

#### TRD-009: Resume from last completed task
**3h** | [satisfies REQ-010] [depends: TRD-005]
- Validates PRD ACs: AC-010-1, AC-010-2
- Implementation ACs:
  - Given an epic worktree with commits for tasks 1-15, when the epic is re-dispatched (resume), then `git log` is parsed to find committed task bead IDs and those tasks are skipped
  - Given task 16 was partially completed (developer done, no QA), when resume runs, then task 16 restarts from developer (no commit = not completed)
  - Given a resumed epic, when the task loop starts, then the log shows `[EPIC] Resuming from task 16 of 40 (15 completed)`

#### TRD-009-TEST: Tests for epic resume
**2h** | [verifies TRD-009] [satisfies REQ-010] [depends: TRD-009]
- Test: resume skips tasks with existing commits
- Test: partial task (no commit) restarts from beginning
- Test: resume with 0 completed tasks starts from task 1

---

### Sprint 3: Observability, Bug Beads, and Polish

#### TRD-010: Bug bead creation on QA failure
**1h** | [satisfies REQ-006] [depends: TRD-005]
- Validates PRD ACs: AC-006-1, AC-006-2
- Implementation ACs:
  - Given QA FAIL on task N, when the retry loop fires, then `br create --title "QA failure in <task>" --type bug --parent <epicId>` is called
  - Given the developer fixes and QA passes, when the task completes, then the bug bead is closed via `br close <bugId>`

#### TRD-010-TEST: Tests for bug bead creation
**1h** | [verifies TRD-010] [satisfies REQ-006] [depends: TRD-010]
- Test: QA FAIL creates bug bead
- Test: QA PASS after retry closes bug bead
- Test: bug bead has correct parent and type

#### TRD-011: Per-task bead status updates
**1h** | [satisfies REQ-011] [depends: TRD-005]
- Validates PRD ACs: AC-011-1, AC-011-2
- Implementation ACs:
  - Given task N starts, when the task loop begins it, then `br update <taskId> --status in_progress` is called
  - Given task N passes QA, when the commit succeeds, then bead status transitions appropriately

#### TRD-011-TEST: Tests for bead status updates
**1h** | [verifies TRD-011] [satisfies REQ-011] [depends: TRD-011]
- Test: task start sets in_progress
- Test: task complete updates status

#### TRD-012: Epic progress display in foreman status
**2h** | [satisfies REQ-012, REQ-013] [depends: TRD-005]
- Validates PRD ACs: AC-012-1, AC-013-1
- Implementation ACs:
  - Given an active epic run, when `foreman status` displays it, then output includes `[EPIC] N/M tasks, current: <beadId>, elapsed: Xm, cost: $Y`
  - Given per-task cost tracking in RunProgress, when status is displayed, then a per-task breakdown is available

#### TRD-012-TEST: Tests for epic status display
**1h** | [verifies TRD-012] [satisfies REQ-012, REQ-013] [depends: TRD-012]
- Test: status shows task count progress
- Test: cost breakdown by task

#### TRD-013: onError behavior for epic runs
**1h** | [satisfies REQ-014] [depends: TRD-005]
- Validates PRD ACs: AC-014-1, AC-014-2
- Implementation ACs:
  - Given `onError: stop` and a task fails after max retries, when the failure occurs, then the epic halts and the run is marked stuck
  - Given a stuck epic, when `foreman retry <epicId>` runs, then resume logic (TRD-009) kicks in

#### TRD-013-TEST: Tests for epic onError
**1h** | [verifies TRD-013] [satisfies REQ-014] [depends: TRD-013]
- Test: onError=stop halts epic on task failure
- Test: foreman retry resumes stuck epic

#### TRD-014: Epic workflow override per project
**1h** | [satisfies REQ-015] [depends: TRD-001]
- Validates PRD ACs: AC-015-1
- Implementation ACs:
  - Given `.foreman/workflows/epic.yaml` in the project, when an epic loads, then the project-local config is used instead of the bundled default

#### TRD-015: Task timeout configuration
**1h** | [satisfies REQ-016] [depends: TRD-005]
- Validates PRD ACs: AC-016-1
- Implementation ACs:
  - Given `taskTimeout: 300` in epic workflow, when a task's developer phase exceeds 300s, then the phase is terminated and the task is marked failed

---

## Sprint Planning

### Sprint 1: Core Epic Runner (~20h)
- [ ] **TRD-001** (2h): Epic workflow YAML fields
- [ ] **TRD-001-TEST** (1h): Tests for YAML parsing
- [ ] **TRD-002** (1h): Bundled epic.yaml
- [ ] **TRD-003** (2h): Task ordering module
- [ ] **TRD-003-TEST** (1h): Tests for task ordering
- [ ] **TRD-004** (1h): Epic fields in PipelineContext
- [ ] **TRD-005** (4h): Outer task loop in executePipeline [CRITICAL PATH]
- [ ] **TRD-005-TEST** (3h): Integration tests for task loop
- [ ] **TRD-006** (3h): Dispatcher epic detection
- [ ] **TRD-006-TEST** (2h): Tests for epic dispatch

### Sprint 2: Session, Finalize, Resume (~13h)
- [ ] **TRD-007** (3h): Session reuse [depends: TRD-005]
- [ ] **TRD-007-TEST** (2h): Tests for session reuse
- [ ] **TRD-008** (2h): Single finalize [depends: TRD-005]
- [ ] **TRD-008-TEST** (1h): Tests for finalize
- [ ] **TRD-009** (3h): Resume from last task [depends: TRD-005]
- [ ] **TRD-009-TEST** (2h): Tests for resume

### Sprint 3: Observability and Polish (~11h)
- [ ] **TRD-010** (1h): Bug bead creation [depends: TRD-005]
- [ ] **TRD-010-TEST** (1h): Tests for bug beads
- [ ] **TRD-011** (1h): Per-task bead status [depends: TRD-005]
- [ ] **TRD-011-TEST** (1h): Tests for bead status
- [ ] **TRD-012** (2h): Epic progress display [depends: TRD-005]
- [ ] **TRD-012-TEST** (1h): Tests for status display
- [ ] **TRD-013** (1h): onError for epics [depends: TRD-005]
- [ ] **TRD-013-TEST** (1h): Tests for onError
- [ ] **TRD-014** (1h): Workflow override [depends: TRD-001]
- [ ] **TRD-015** (1h): Task timeout [depends: TRD-005]

**Total: ~44h estimated across 30 tasks (15 implementation + 15 test)**

---

## Acceptance Criteria Traceability

| REQ | Description | Implementation Tasks | Test Tasks |
|-----|-------------|---------------------|------------|
| REQ-001 | Epic bead detection | TRD-004, TRD-006 | TRD-006-TEST |
| REQ-002 | Epic workflow YAML | TRD-001, TRD-002 | TRD-001-TEST |
| REQ-003 | Parallel epic execution | TRD-006 | TRD-006-TEST |
| REQ-004 | Sequential task execution | TRD-003, TRD-004, TRD-005 | TRD-003-TEST, TRD-005-TEST |
| REQ-005 | Per-task dev→QA loop | TRD-005 | TRD-005-TEST |
| REQ-006 | Bug bead on QA failure | TRD-010 | TRD-010-TEST |
| REQ-007 | Per-task commits | TRD-005 | TRD-005-TEST |
| REQ-008 | Session continuity | TRD-004, TRD-007 | TRD-007-TEST |
| REQ-009 | Single finalize | TRD-008 | TRD-008-TEST |
| REQ-010 | Resume from last task | TRD-009 | TRD-009-TEST |
| REQ-011 | Per-task bead status | TRD-011 | TRD-011-TEST |
| REQ-012 | Epic progress display | TRD-012 | TRD-012-TEST |
| REQ-013 | Epic cost tracking | TRD-012 | TRD-012-TEST |
| REQ-014 | onError for epics | TRD-013 | TRD-013-TEST |
| REQ-015 | Workflow override | TRD-014 | — |
| REQ-016 | Task timeout | TRD-015 | — |

---

## Design Readiness Scorecard

| Dimension | Score (1-5) | Notes |
|-----------|-------------|-------|
| Architecture Completeness | 4 | All components defined; session reuse depends on Pi SDK behavior (tested at TRD-007) |
| Task Coverage | 5 | Every REQ has implementation + test tasks; traceability matrix complete |
| Dependency Clarity | 4 | Linear dependency chain through TRD-005 (critical path); no circular deps |
| Estimate Confidence | 4 | TRD-005 (4h) is the riskiest; similar scope to original pipeline-executor |
| **Overall** | **4.25** | **PASS** |

### Issues Identified and Resolved

1. **Session token limits** (REQ-008): Pi SDK sessions have context limits. TRD-007 handles this by detecting limit errors and creating a fresh session with a summary. Tested explicitly.

2. **Critical path risk**: TRD-005 (outer task loop) is the foundation — everything depends on it. Estimated at 4h which is aggressive for a core control flow change. Mitigation: it reuses existing phase loop logic, just wraps it.

3. **VCS commit in epic mode**: Per-task commits (TRD-005) must work with both git and jujutsu backends. The existing `vcs.commit()` is used, which already handles both. No jj-specific issues since we removed `jj new` from commit().

4. **Squash merge at finalize**: The refinery already does squash merge (fixed this session). Epic branches with N task commits will become 1 commit on dev.
