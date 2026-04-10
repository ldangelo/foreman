# Task Naming Cutover Plan

## Purpose

Foreman currently mixes three names for the unit of work it dispatches and tracks:

- `seedId` / `seed_id`
- `beadId`
- `taskId` / `task_id`

This document defines the canonical naming contract going forward and the phased cutover plan to reach it without lying about still-beads-backed boundaries.

## Current repo truth

As of this plan:

- Generic orchestration and persistence still use `seedId` / `seed_id` in many places.
- Explicit `br`/beads compatibility surfaces use `beadId`.
- Native task management code already uses `Task`, `taskId`, and `task_id` in `src/lib/task-store.ts` and related roadmap docs.
- `PRD-2026-006` is the roadmap authority for future native-task vocabulary and status semantics.

## Public product boundary note

This guide is about long-term generic naming inside backend-agnostic orchestration and persistence layers. It is not a statement that the current public CLI/UX has already switched away from beads.

- Public day-to-day task tracking remains beads-first in the current checkout.
- `foreman task` is currently restricted to transitional `import --from-beads` behavior.


## Canonical naming contract

### 1. Generic orchestration vocabulary
Use these names everywhere the code is describing Foreman's backend-agnostic unit of work:

- `Task`
- `TaskId`
- `taskId`
- `task_id`

This includes:

- dispatcher and pipeline orchestration
- workflow execution
- generic prompts/templates
- VCS/workspace helpers
- merge/refinery reports
- SQLite run/merge-queue records once migrated
- dashboard/status/debug surfaces that are not explicitly beads-only

### 2. Execution vocabulary
Use these names for execution instances:

- `Run`
- `RunId`
- `runId`

A run is not a task. A run is one execution attempt of a task.

### 3. Compatibility-edge vocabulary
Use these names only where the code is explicitly talking to `br` / beads compatibility surfaces:

- `Bead`
- `BeadId`
- `beadId`

This is limited to:

- `BeadsRustClient`
- bead-specific CLI compatibility flags/messages
- prompts or automation whose contract is explicitly bead-facing
- migration/bridge code that translates between generic tasks and beads

### 4. Forbidden future generic naming
Do not introduce new generic orchestration APIs using:

- `seedId`
- `seed_id`

Treat these as legacy names scheduled for removal.

## Design rules

1. One concept, one name.
   - Generic unit of work: `taskId`
   - Execution instance: `runId`
   - Beads compatibility identifier: `beadId`

2. No permanent shims.
   - Avoid adding long-lived alias layers that preserve both `seedId` and `taskId` in the same abstraction.

3. Truthful boundaries.
   - If a surface is still explicitly `br`-backed, it may stay bead-centric until the surface itself becomes backend-agnostic.

4. Schema truth matters.
   - Persistence columns should eventually match the canonical contract (`task_id`), not preserve `seed_id` indefinitely.

## Phased execution plan

### Phase 0 — Contract and audit
Goal: establish a single source of truth before renaming code.

Actions:

- Adopt this document as the naming contract.
- Link this document from operator-facing context docs.
- Audit remaining uses of `seedId` / `seed_id` / `beadId` / `taskId` by subsystem.

Exit criteria:

- Contributors can answer where `taskId` is required and where `beadId` is still allowed.

### Phase 1 — Generic TypeScript API cutover
Goal: rename backend-agnostic code surfaces from `seedId` to `taskId`.

Scope:

- generic interfaces/types in `src/orchestrator/types.ts`
- VCS/workspace helper parameter names and template vars
- non-beads-specific CLI and orchestrator request/response shapes
- generic prompt/template variables and interpolation payloads

Examples:

- `seedId` -> `taskId`
- `SeedInfo` -> `TaskInfo` where the type is generic rather than beads-specific
- `MergedRun.seedId` -> `MergedRun.taskId`
- `FinalizeTemplateVars.seedId` -> `FinalizeTemplateVars.taskId`

Non-goals:

- explicit `BeadsRustClient` APIs
- bead-only CLI flags/messages that still intentionally target `br`

Exit criteria:

- Generic orchestration code no longer introduces new `seedId` names.
- TypeScript-facing APIs describe the work unit as a task, not a seed.

Concrete Phase 1 target files:
- `src/orchestrator/types.ts` — rename generic types and result fields (`SeedInfo`, `seedId` result properties) to task-centric names.
- `src/orchestrator/dispatcher.ts` — rename backend-agnostic orchestration parameters, result shaping, and generic helper arguments to `taskId`/`TaskInfo`.
- `src/orchestrator/templates.ts` — rename generic task metadata types and interpolation payloads to task-centric names.
- `src/orchestrator/roles.ts` — rename generic prompt-builder context variables from `seedId` to `taskId` while preserving explicit bead-facing prompts separately.
- `src/orchestrator/phase-runner.ts` and `src/orchestrator/pipeline-executor.ts` — rename generic pipeline metadata/context fields that describe the work unit, not the beads backend.
- `src/orchestrator/session-log.ts`, `src/orchestrator/monitor.ts`, `src/orchestrator/merge-queue.ts`, and generic merge/refinery report types — cut result/report payloads to `taskId` where they are backend-agnostic.
- `src/lib/vcs/types.ts`, `src/lib/vcs/interface.ts`, `src/lib/workspace-paths.ts`, and backend implementations — rename generic parameter/template variable names from `seedId` to `taskId` where they describe the current unit of work rather than beads specifically.
- Generic tests that exercise these abstractions should be renamed in the same phase so the public TypeScript contract has one vocabulary.

### Phase 2 — Persistence cutover
Goal: make persistence match the canonical generic vocabulary.

Scope:

- `runs.seed_id` -> `runs.task_id`
- `merge_queue.seed_id` -> `merge_queue.task_id`
- related indexes, queries, row types, helpers, tests, and JSON output

Required work:

- add a real schema migration path for existing SQLite databases
- update store methods and callers coherently
- rename row/interface fields in code and test fixtures

Design note:

- Do not keep permanent code that treats both `seed_id` and `task_id` as equal first-class names.
- If transitional migration support is needed, isolate it to schema migration logic and remove it once cutover completes.

Exit criteria:

- Generic run/merge persistence uses `task_id` consistently in schema and code.

Concrete Phase 2 target files and schema objects:
- `src/lib/store.ts` — `Run`, `createRun()`, `getRunsForSeed()`, `hasActiveOrPendingRun()`, and related query helpers should move from `seed_id`/`seedId` to `task_id`/`taskId` as the generic run foreign key.
- `src/orchestrator/merge-queue.ts` — queue row types, enqueue/reset/query helpers, and SQL should move from `seed_id` to `task_id`.
- JSON/status/debug/dashboard output built from run or merge-queue rows should adopt `task_id` or expose `taskId` in their generic shapes.
- Tests and fixtures that currently insert into `runs.seed_id` or `merge_queue.seed_id` should migrate with the schema, not via permanent dual-name support.
- Migration code must update existing project SQLite databases in-place before generic code assumes the new columns exist.

### Phase 3 — Compatibility-edge isolation
Goal: confine beads language to explicit beads boundaries.

Scope:

- `BeadsRustClient`
- bead write queue / bead-specific operations
- bead-facing prompts and compatibility commands
- CLI help/output that intentionally talks about beads because the operator is using `br`

Required work:

- translate between generic `taskId` and compatibility `beadId` only at the edge
- keep bead-specific naming out of backend-agnostic orchestration internals

Exit criteria:

- `beadId` exists only where the code is explicitly beads-specific.

Concrete Phase 3 compatibility-edge files:
- `src/lib/beads-rust.ts` and the `ITaskClient` compatibility path when backed by `br`.
- `src/orchestrator/task-backend-ops.ts` and bead write queue/drain code that intentionally shells out to `br`.
- bead-specific CLI surfaces such as `retry.ts`, `recover.ts`, `merge --bead`, and bead-specific help/output while those commands remain explicitly beads-backed.
- bead-facing prompts/templates such as `recover.md` and `troubleshooter.md`, plus any tool schemas that explicitly accept `beadId`.
- Translation points between generic orchestration `taskId` and compatibility `beadId` should be isolated here rather than spread through dispatcher/store/refinery internals.

### Phase 4 — Docs and prompt alignment
Goal: make docs tell the same truth as the code.

Scope:

- `README.md`
- `CLAUDE.md`
- relevant PRD/TRD/guides
- generic prompts/templates
- test descriptions and fixtures where names are part of the documented contract

Rules:

- Generic docs use task language.
- Beads-specific docs say beads intentionally.
- Historical docs may preserve historical language when needed, but current guidance must not be ambiguous.

Exit criteria:

- Operator docs consistently distinguish task-generic versus bead-specific surfaces.

Concrete Phase 4 docs and prompt targets:
- `README.md`, `CLAUDE.md`, and `docs/guides/task-naming-cutover.md` itself.
- generic prompt templates under `src/defaults/prompts/default/` that currently interpolate `seedId` for backend-agnostic phases.
- guides and PRD/TRD examples that are meant to describe current generic orchestration rather than legacy beads compatibility.
- test names and fixture labels where the terminology is part of the documented contract exposed to maintainers.

### Phase 5 — User-facing surface review
Goal: decide whether remaining bead-centric CLI UX should stay bead-centric or become task-centric.

Examples to review:

- `foreman retry`
- `foreman recover`
- `foreman merge --bead`
- bead-oriented prompt language in recovery/troubleshooter flows

Decision rule:

- If the command is still explicitly a `br` compatibility surface, `beadId` may remain truthful.
- If the command becomes backend-agnostic, rename it to task-centric UX in one coherent cutover.

## Suggested execution order

1. Phase 0 — contract + audit
2. Phase 1 — generic TypeScript API cutover
3. Phase 2 — persistence migration
4. Phase 3 — compatibility-edge isolation
5. Phase 4 — docs/prompt alignment
6. Phase 5 — final user-facing CLI review

## Verification strategy

After each phase:

- run targeted tests for touched subsystems
- run `npx tsc --noEmit`
- grep for forbidden names in the intended scope

Recommended verification gates by phase:
- Phase 1 grep gate: remaining `seedId`/`seed_id` matches in touched generic files must be either deliberate persistence leftovers for Phase 2 or explicit beads-edge references.
- Phase 2 grep gate: schema/query code should no longer introduce new generic `seed_id` references after migration lands.
- Phase 3 grep gate: `beadId` should appear only in `br` adapters, bead-specific commands/prompts, and explicit compatibility translation boundaries.
- Phase 4 grep gate: current operator docs should use task language for generic orchestration and bead language only when the surface is intentionally bead-specific.
- Every phase should re-run targeted tests for the touched subsystem plus `npx tsc --noEmit` before moving on.

Verification questions:

- Does this identifier name the generic work unit? Then it should be `taskId`.
- Does this identifier name one execution attempt? Then it should be `runId`.
- Does this identifier refer specifically to `br` / beads? Then `beadId` is allowed.
- Is the current name only historical inertia? Rename it.

## Immediate execution items

The next concrete work items to execute are:

1. Define and publish the naming contract.
2. Cut over generic TypeScript APIs to `taskId`.
3. Migrate generic persistence from `seed_id` to `task_id`.
4. Isolate beads compatibility to explicit edge surfaces.

These four items should be completed together before treating the cutover as established.
