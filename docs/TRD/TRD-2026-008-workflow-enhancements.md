# TRD-2026-008: Workflow Enhancements — Bash Phases, Merge Strategy, Type-Based Dispatch

| Field | Value |
|---|---|
| Document ID | TRD-2026-008 |
| PRD Reference | PRD-2026-008 |
| Version | 1.0.1 |
| Status | Draft |
| Date | 2026-04-18 |
| Design Readiness Score | 4.75 |

---

## Architecture Decision

### Approach: Extend Existing Abstractions

The Foreman pipeline executor already has clean extension points — `WorkflowPhaseConfig` for phase definitions, `ctx.runPhase()` as the single dispatch point, and `WorkflowConfig` for top-level YAML fields. The architecture adds three new capabilities by widening these existing interfaces rather than introducing new components.

**Alternatives considered:**
- **Plugin-based phase handlers**: Register phase type handlers via a plugin registry. Rejected — over-engineered for 3 phase types with no foreseeable growth beyond these.
- **Separate bash executor service**: Run bash phases through a dedicated process manager. Rejected — unnecessary complexity; `execFile` in the worktree is sufficient.

**Rationale:** All three features touch the same small surface area (workflow-loader → pipeline-executor → auto-merge/refinery). Extending existing types preserves backward compatibility and keeps the change set minimal.

### Component Changes

```
WorkflowConfig (workflow-loader.ts)
  - rejects top-level merge/pr tags       ← REQ-004

WorkflowPhaseConfig (workflow-loader.ts)
  + bash?: string                           ← REQ-001
  + command?: string                        ← REQ-002
  (prompt remains optional, exactly one required)

resolveWorkflowName() (workflow-loader.ts)
  + filesystem existence check              ← REQ-007
  + type → filename mapping                 ← REQ-006

pipeline-executor.ts (runPhaseSequence)
  + phase type dispatch: bash | command | prompt  ← REQ-003
  + runBashPhase() helper                   ← REQ-001
  + interpolateTaskPlaceholders() helper    ← REQ-008

store.ts (runs table)
  + merge_strategy column                   ← REQ-005

agent-worker.ts / auto-merge.ts / refinery.ts
  + explicit create-pr/pr-wait/merge builtin phases ← REQ-004
  + read derived merge_strategy compatibility state
```

### Data Flow

```
Dispatch:
  bead.type → resolveWorkflowName() → loadWorkflowConfig(name)
                                         ↓
                                    WorkflowConfig.phases → derive runs.merge_strategy
                                    WorkflowConfig.phases → pipeline-executor

Phase execution:
  phase.bash?    → execFile('/bin/sh', ['-c', bash], {cwd: worktree}) → stdout/stderr → artifact
  phase.command? → interpolate({task.*}) → Pi SDK session.prompt(command) → artifact
  phase.prompt?  → loadPromptFile(prompt) → Pi SDK session.prompt(content) → artifact

PR/merge phases:
  create-pr → create or reuse GitHub PR
  pr-wait   → wait for checks/review readiness
  merge     → final readiness gate and queue refinery merge
```

---

## Master Task List

### Sprint 1: Foundation (workflow-loader + store schema)

#### TRD-001: Add bash/command fields and reject legacy merge/pr workflow tags [4h]
[satisfies REQ-001, REQ-002, REQ-003, REQ-004]

**Validates PRD ACs:** AC-003-1, AC-003-2, AC-004-3

Extend `WorkflowPhaseConfig` with optional `bash?: string` and `command?: string` fields. Add validation in `loadWorkflowConfig()`: exactly one of `bash`, `command`, or `prompt` must be present per phase; top-level `merge:` and `pr:` workflow tags are invalid because PR/merge behavior is expressed by explicit phases.

**Implementation ACs:**
- Given a workflow YAML with a phase containing both `bash:` and `prompt:`, when `loadWorkflowConfig()` is called, then it throws a validation error mentioning both conflicting fields.
- Given a workflow YAML with a phase containing none of `bash:`, `command:`, or `prompt:`, when `loadWorkflowConfig()` is called, then it throws a validation error listing the missing fields.
- Given a workflow YAML with top-level `merge:` or `pr:`, when `loadWorkflowConfig()` is called, then it throws a validation error directing users to explicit PR/merge phases.

[depends: none]

---

#### TRD-001-TEST: Test workflow type validation [2h]
[verifies TRD-001] [satisfies REQ-003] [depends: TRD-001]

Write vitest tests for:
- Valid phase with `bash:` only — loads successfully
- Valid phase with `command:` only — loads successfully
- Phase with both `bash:` and `prompt:` — throws with clear message
- Phase with none of the three — throws with clear message
- `merge` phase present — derives auto-merge intent for persisted run compatibility
- `merge` phase absent — derives no workflow-driven merge intent
- Top-level `merge:` / `pr:` — throw validation errors

---

#### TRD-002: Add merge_strategy column to runs table [2h]
[satisfies REQ-005]

**Validates PRD ACs:** AC-005-1

Keep `merge_strategy` as persisted compatibility state derived from workflow phases. Update run creation paths to store `auto` when a `merge` phase exists and `none` when it does not.

**Implementation ACs:**
- Given a new run for a workflow with a `merge` phase, when `getRun()` is called, then the returned run object includes `merge_strategy: 'auto'`.
- Given a new run for a workflow without a `merge` phase, when `getRun()` is called, then the returned run object includes `merge_strategy: 'none'`.

[depends: none]

---

#### TRD-002-TEST: Test merge_strategy column [1h]
[verifies TRD-002] [satisfies REQ-005] [depends: TRD-002]

Write vitest tests for:
- `createRun()` stores and retrieves derived merge strategy correctly
- workflows with no `merge` phase store `none`
- Migration: existing runs without the column still work (Postgres ALTER TABLE compatibility)

---

#### TRD-003: Placeholder interpolation utility [2h]
[satisfies REQ-008]

**Validates PRD ACs:** AC-008-1, AC-008-2, AC-008-3

Create `interpolateTaskPlaceholders(template: string, task: TaskMeta): string` in a new file `src/lib/interpolate.ts`. Supports `{task.title}`, `{task.description}`, `{task.id}`, `{task.type}`, `{task.priority}`. Unknown placeholders left as-is with a warning logged. Backslash-escaped braces (`\{task.title\}`) emit literal text.

**Implementation ACs:**
- Given template `"/fix {task.title}"` and task with title `"Login bug"`, when interpolated, then result is `"/fix Login bug"`.
- Given template with `{task.unknown}`, when interpolated, then placeholder remains and a warning is logged.
- Given template with `\{task.title\}`, when interpolated, then result contains literal `{task.title}`.

[depends: none]

---

#### TRD-003-TEST: Test placeholder interpolation [1h]
[verifies TRD-003] [satisfies REQ-008] [depends: TRD-003]

Write vitest tests for:
- All 5 supported placeholders interpolate correctly
- Unknown placeholder left as-is + warning
- Escape syntax `\{...\}` produces literal braces
- Empty/null task fields interpolate as empty string
- Template with no placeholders passes through unchanged

---

#### TRD-010: Pass task metadata through PipelineContext [2h]
[satisfies REQ-008] [satisfies ARCH]

**Validates PRD ACs:** AC-008-1, AC-008-2

Define a `TaskMeta` interface (`{ id: string; title: string; description: string; type: string; priority: number }`) in `src/lib/interpolate.ts`. Add a `taskMeta: TaskMeta` field to the `WorkerConfig` / `PipelineContext` types. In the dispatcher, populate `taskMeta` from the bead's metadata when spawning. In the pipeline executor, pass `taskMeta` to `interpolateTaskPlaceholders()` when executing `bash:` or `command:` phases.

**Implementation ACs:**
- Given a dispatched bead with title "Fix login timeout", when the pipeline executor runs a command phase, then `ctx.taskMeta.title` is `"Fix login timeout"`.
- Given a PipelineContext without taskMeta (legacy runs), when a phase tries to interpolate, then placeholders are left as-is with a warning.

[depends: TRD-003]

---

#### TRD-010-TEST: Test task metadata propagation [1h]
[verifies TRD-010] [satisfies REQ-008] [depends: TRD-010]

Write vitest tests:
- WorkerConfig with taskMeta populated from bead — fields match
- PipelineContext passes taskMeta to interpolation
- Missing taskMeta (null/undefined) — graceful fallback with warning

---

### Sprint 2: Phase Execution (pipeline-executor)

#### TRD-004: Bash phase execution in pipeline-executor [4h]
[satisfies REQ-001]

**Validates PRD ACs:** AC-001-1, AC-001-2, AC-001-3, AC-001-4, AC-001-5

Add `runBashPhase()` to `pipeline-executor.ts`. When a phase has `bash:` set:
1. Interpolate `{task.*}` placeholders via `interpolateTaskPlaceholders()` using the `taskMeta` from PipelineContext
2. Run the command via `execFile('/bin/sh', ['-c', command])` with `cwd` set to worktree path. This supports multi-arg commands (`npm run test`), shell operators (`&&`, `||`, `|`), and redirects.
3. Capture stdout + stderr
4. If `artifact:` is set, write captured output to that file in the worktree
5. Determine verdict: exit code 0 = PASS, non-zero = FAIL
6. Enforce 120-second timeout — kill process on timeout, treat as FAIL
7. Existing verdict/retry logic (`retryWith`, `retryOnFail`) applies unchanged

Integrate into `runPhaseSequence()`: before calling `ctx.runPhase()`, check if `phase.bash` is set and call `runBashPhase()` instead. Skip Pi SDK session creation entirely for bash phases.

**Implementation ACs:**
- Given a bash phase `"npm run test"`, when executed in a worktree, then stdout/stderr are captured and the artifact file is written.
- Given a bash phase that exits 0 with `verdict: true`, when the phase completes, then PASS is recorded.
- Given a bash phase that runs for 130 seconds, when 120 seconds elapse, then the process is killed and the phase fails.

[depends: TRD-001, TRD-003]

---

#### TRD-004-TEST: Test bash phase execution [3h]
[verifies TRD-004] [satisfies REQ-001] [depends: TRD-004]

Write vitest tests (may need test fixtures with temp directories):
- Bash phase runs command in worktree cwd
- Exit code 0 → PASS verdict
- Exit code 1 → FAIL verdict
- stdout/stderr written to artifact file
- Timeout kills process after 120s (use a `sleep` command to test)
- retryWith triggers on FAIL (verify retry loop integration)
- Placeholders in bash string are interpolated

---

#### TRD-005: Command/skill phase execution in pipeline-executor [2h]
[satisfies REQ-002]

**Validates PRD ACs:** AC-002-1, AC-002-2, AC-002-3

When a phase has `command:` set:
1. Interpolate `{task.*}` placeholders
2. Create Pi SDK session (same as `prompt:` phases)
3. Send the interpolated command string as the prompt (instead of loading from a `.md` file)
4. All other phase config options work identically to `prompt:` phases (models, maxTurns, artifact, verdict, retryWith, retryOnFail, mail, files, skipIfArtifact)

Integrate into `runPhaseSequence()`: check `phase.command` before `phase.prompt`, create session with inline prompt.

**Implementation ACs:**
- Given a command phase with `/ensemble:fix-issue {task.title}`, when executed, then a Pi SDK session receives the interpolated string as its prompt.
- Given a command phase with `verdict: true` that produces FAIL, when retryWith is configured, then retry loop triggers.

[depends: TRD-001, TRD-003]

---

#### TRD-005-TEST: Test command phase execution [2h]
[verifies TRD-005] [satisfies REQ-002] [depends: TRD-005]

Write vitest tests:
- Command string sent to Pi SDK session as prompt
- Placeholders interpolated before sending
- Verdict/retry works same as prompt phases
- All config options (mail, files, skipIfArtifact) accepted without error

---

### Sprint 3: Phase-Driven Merge + Type Dispatch

#### TRD-006: Type-based workflow resolution [3h]
[satisfies REQ-006, REQ-007]

**Validates PRD ACs:** AC-006-1, AC-006-2, AC-006-3, AC-007-1

Modify `resolveWorkflowName()` in `workflow-loader.ts`:
1. Keep existing label check first (`workflow:<name>` label)
2. Remove hardcoded `smoke` and `epic` checks
3. Map bead type directly to workflow name (e.g., `"bug"` → `"bug"`)
4. Check if workflow file exists in `.foreman/workflows/` or bundled defaults
5. If file exists, return the type name; if not, return `"default"`

The function signature changes from pure to requiring a `projectPath` parameter for filesystem checks. Update all call sites (dispatcher.ts, agent-worker.ts).

**Implementation ACs:**
- Given type `"bug"` and `bug.yaml` exists in `.foreman/workflows/`, when resolved, then returns `"bug"`.
- Given type `"bug"` and no `bug.yaml` exists anywhere, when resolved, then returns `"default"`.
- Given label `workflow:smoke` and type `bug`, when resolved, then returns `"smoke"` (label wins).

[depends: TRD-001]

---

#### TRD-006-TEST: Test type-based workflow resolution [2h]
[verifies TRD-006] [satisfies REQ-006, REQ-007] [depends: TRD-006]

Write vitest tests (using temp directories with/without workflow files):
- Type maps to matching filename when file exists
- Type falls back to `"default"` when file doesn't exist
- Label `workflow:<name>` takes precedence over type
- Existing `smoke` and `epic` types still resolve (via file existence, not hardcoded)
- Unknown type with no matching file returns `"default"`

---

#### TRD-007: Phase-driven PR/merge routing [4h]
[satisfies REQ-004, REQ-005]

**Validates PRD ACs:** AC-004-1, AC-004-2, AC-004-3, AC-004-4, AC-005-1

1. **Dispatcher**: When dispatching a run, derive `merge_strategy` from the loaded workflow phases: `auto` when a `merge` phase exists, otherwise `none`.
2. **agent-worker.ts**: Implement builtin `create-pr`, `pr-wait`, and `merge` phases. Finalize no longer creates PRs or enqueues merges implicitly.
3. **auto-merge.ts / merge queue**: Keep `merge_strategy` handling for persisted compatibility and legacy queue reconciliation.

**Implementation ACs:**
- Given a workflow with `create-pr`, when that phase runs, then a GitHub PR is created or reused.
- Given a workflow with `pr-wait`, when that phase runs, then checks/review readiness is enforced.
- Given a workflow with `merge`, when that phase runs, then refinery merge processing is queued.
- Given a workflow without `merge`, when finalize succeeds, then no workflow-driven merge queue entry is created.

[depends: TRD-001, TRD-002]

---

#### TRD-007-TEST: Test merge strategy routing [3h]
[verifies TRD-007] [satisfies REQ-004, REQ-005] [depends: TRD-007]

Write vitest tests:
- workflow with `merge` phase derives `merge_strategy: 'auto'`
- workflow without `merge` phase derives `merge_strategy: 'none'`
- `create-pr` phase creates/reuses PR metadata
- `merge` phase queues refinery merge processing
- top-level `merge:` / `pr:` workflow tags are rejected

---

### Sprint 4: Integration + Sample Workflow

#### TRD-008: Create sample bug.yaml workflow [1h]
[satisfies ARCH]

Create `src/defaults/workflows/bug.yaml` as a bundled workflow demonstrating all three new features:

```yaml
name: bug
phases:
  - name: fix
    command: "/ensemble:fix-issue {task.title} {task.description}"
    models:
      default: sonnet
    maxTurns: 80
    artifact: DEVELOPER_REPORT.md
    mail:
      onStart: true
      onComplete: true
  - name: test
    bash: "npm run test"
    artifact: TEST_RESULTS.md
    verdict: true
    retryWith: fix
    retryOnFail: 2
  - name: finalize
    prompt: finalize.md
    models:
      default: haiku
    maxTurns: 30
    artifact: FINALIZE_VALIDATION.md
    verdict: true
    retryWith: fix
    retryOnFail: 1
```

**Implementation ACs:**
- Given a bead of type `bug`, when dispatched, then `bug.yaml` is selected and the pipeline runs fix → test → finalize → auto-merge.

[depends: TRD-001, TRD-004, TRD-005, TRD-006]

---

#### TRD-009: End-to-end integration test [3h]
[satisfies REQ-001, REQ-002, REQ-004, REQ-006] [depends: TRD-004, TRD-005, TRD-006, TRD-007, TRD-010]

Write an integration test that:
1. Creates a temp project with `.foreman/workflows/bug.yaml`
2. Creates a bead of type `bug`
3. Dispatches it — verifies `bug.yaml` is selected
4. Runs through a mock pipeline: command phase → bash phase → finalize
5. Verifies merge strategy is respected
6. Verifies retryWith across phase types works (bash phase FAIL → retries command phase)

**Implementation ACs:**
- Given a full pipeline with command + bash + finalize phases, when all phases succeed, then the run completes with the correct merge strategy applied.
- Given a bash phase that fails with `retryWith: fix` (a command phase), when the retry triggers, then the command phase re-executes via Pi SDK session.

---

## Team Configuration

> **Auto-configured by /ensemble:configure-team** — edit agent assignments below if needed.
>
> | Metric | Value |
> |---|---|
> | Task count | 18 |
> | Estimated hours | 42h |
> | Domain count | 2 (backend, database) |
> | Cross-cutting tasks | 2 |
> | Dependency depth | 3 |
> | Tier | **Medium** |

```yaml
team:
  lead:
    agent: tech-lead-orchestrator
    owns: [task-selection, architecture-review, final-approval]
  builders:
    - agent: backend-developer
      owns: [implementation]
      domains: [backend, database]
      tasks: [TRD-001, TRD-002, TRD-003, TRD-004, TRD-005, TRD-006, TRD-007, TRD-008, TRD-010]
  test:
    agent: test-runner
    owns: [test-execution]
    tasks: [TRD-001-TEST, TRD-002-TEST, TRD-003-TEST, TRD-004-TEST, TRD-005-TEST, TRD-006-TEST, TRD-007-TEST, TRD-009, TRD-010-TEST]
```

---

## Sprint Planning Summary

| Sprint | Tasks | Hours | Focus |
|---|---|---|---|
| Sprint 1 | TRD-001 through TRD-003, TRD-010 (+ tests) | 15h | Foundation: types, schema, interpolation, metadata flow |
| Sprint 2 | TRD-004, TRD-005 (+ tests) | 11h | Phase execution in pipeline-executor |
| Sprint 3 | TRD-006, TRD-007 (+ tests) | 12h | Merge strategy + type dispatch |
| Sprint 4 | TRD-008, TRD-009 | 4h | Sample workflow + integration test |
| **Total** | **10 impl + 8 test = 18 tasks** | **42h** | |

---

## Acceptance Criteria Traceability

| REQ | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-001 | Bash command phases | TRD-001, TRD-004 | TRD-001-TEST, TRD-004-TEST, TRD-009 |
| REQ-002 | Command/skill phases | TRD-001, TRD-005 | TRD-001-TEST, TRD-005-TEST, TRD-009 |
| REQ-003 | Phase type resolution | TRD-001 | TRD-001-TEST |
| REQ-004 | Per-workflow merge strategy | TRD-001, TRD-007 | TRD-001-TEST, TRD-007-TEST, TRD-009 |
| REQ-005 | Merge strategy propagation | TRD-002, TRD-007 | TRD-002-TEST, TRD-007-TEST |
| REQ-006 | Workflow resolution by bead type | TRD-006 | TRD-006-TEST, TRD-009 |
| REQ-007 | Workflow file discovery | TRD-006 | TRD-006-TEST |
| REQ-008 | Task metadata interpolation | TRD-003, TRD-010 | TRD-003-TEST, TRD-010-TEST |

**Traceability check: 8/8 requirements covered, 0 uncovered, 0 orphaned annotations.**

---

## Design Readiness Scorecard

| Dimension | Score | Notes |
|---|---|---|
| Architecture completeness | 5 | All components, interfaces, and data flows defined; no new components needed |
| Task coverage | 5 | Every REQ-NNN has implementation + test tasks; traceability matrix is complete |
| Dependency clarity | 5 | Dependencies are explicit, acyclic, and organized into sprints by dependency order |
| Estimate confidence | 4 | Estimates are consistent; TRD-004 (bash phases, 4h) and TRD-007 (merge strategy, 4h) could run longer if pipeline-executor integration is complex |
| **Overall** | **4.75** | **PASS** |

---

## Changelog

| Date | Version | Changes |
|---|---|---|
| 2026-04-18 | 1.0.0 | Initial TRD from PRD-2026-008 |
| 2026-04-18 | 1.0.1 | Refinement: fixed frontmatter readiness score (TBD→4.75), changed bash execution to `/bin/sh -c` for multi-arg support, added TRD-010 + TRD-010-TEST for task metadata propagation through PipelineContext, added retryWith cross-phase-type test to TRD-009, fixed task count (17→18) |
