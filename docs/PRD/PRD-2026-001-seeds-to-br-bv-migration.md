# PRD-2026-001: Migrate Task Management from seeds (sd) to br + bv

**Document ID:** PRD-2026-001
**Version:** 1.0
**Status:** Draft
**Date:** 2026-03-16
**Author:** Product Management
**Stakeholders:** Engineering (Foreman maintainers), Agent operators

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Goals and Non-Goals](#3-goals-and-non-goals)
4. [User Personas](#4-user-personas)
5. [Current State Analysis](#5-current-state-analysis)
6. [Solution Overview](#6-solution-overview)
7. [Functional Requirements](#7-functional-requirements)
8. [Non-Functional Requirements](#8-non-functional-requirements)
9. [Migration Strategy](#9-migration-strategy)
10. [Risks and Mitigations](#10-risks-and-mitigations)
11. [Acceptance Criteria](#11-acceptance-criteria)
12. [Success Metrics](#12-success-metrics)
13. [Release Plan](#13-release-plan)
14. [Open Questions](#14-open-questions)

---

## 1. Executive Summary

Foreman currently uses `seeds` (`sd`, `@os-eco/seeds-cli`) as its task store and a hand-rolled PageRank algorithm (`pagerank.ts`) for dispatch prioritization. This PRD proposes replacing seeds with `br` (beads_rust) as the authoritative task store and integrating `bv` (beads_viewer) as a graph-aware triage sidecar that drives execution ordering via `--robot-*` flags.

The migration delivers: faster task operations (Rust vs Node.js/bun), richer query capabilities, elimination of the custom PageRank implementation, and a first-class graph-aware triage model that surfaces critical-path tasks automatically. The `BeadsRustClient` in `src/lib/beads-rust.ts` already exists and is partially wired in `sling.ts`, giving this migration a substantial head-start.

---

## 2. Problem Statement

### 2.1 Seeds Limitations

**Performance.** `seeds` is a Node.js/bun CLI. Every task operation — `ready`, `list`, `show`, `update`, `close` — spawns a bun subprocess. Under load (many concurrent agents polling seed state), this creates non-trivial process-spawn overhead and JSON-parse cost.

**Graph capabilities.** Seeds exposes a `graph` command that returns nodes and edges, but the graph output is basic. Foreman has compensated by implementing its own PageRank in `src/orchestrator/pagerank.ts` (BFS-based impact scoring over the seeds graph). This is custom infrastructure that must be maintained, tested, and tuned independently of the underlying task store.

**No native triage intelligence.** Seeds cannot answer questions like "which task unblocks the most downstream work?" without the additional PageRank layer. There is no concept of betweenness centrality, critical path, or HITS scoring built in.

**Dual-tracker friction.** The `sling` command already writes tasks to both `sd` and `br` simultaneously (supporting `--sd-only` and `--br-only` flags). The existence of this dual-write path signals that the team has already recognized `br` as the target and seeds as transitional. Maintaining both systems increases cognitive overhead and test surface area.

**Naming inconsistency.** `src/lib/seeds.ts` exports `BeadsClient`, `Bead`, `BeadDetail`, and `BeadGraph` as deprecated aliases — evidence of a previous incomplete rename attempt that left the codebase in an intermediate state.

### 2.2 bv's Unanswered Value

`bv` (beads_viewer) provides precomputed graph metrics — PageRank, betweenness centrality, critical path, HITS, eigenvector centrality, k-core decomposition — via deterministic `--robot-*` flags. These metrics are exactly what Foreman's dispatcher needs to answer "which ready task should be dispatched first?" Without integration, Foreman maintains a parallel, lower-fidelity answer to the same question.

### 2.3 The Gap Between Intent and Implementation

`src/lib/beads-rust.ts` exists. `BeadsRustClient` is implemented. `sling.ts` already uses it. But the core dispatcher, monitor, agent worker, and all CLI commands except `sling` still use `SeedsClient`. The gap between the existing `br` infrastructure and full adoption is the scope of this migration.

---

## 3. Goals and Non-Goals

### 3.1 Goals

- Replace all `SeedsClient` usage in the dispatcher, monitor, agent worker, and CLI commands with `BeadsRustClient`.
- Replace the custom `calculateImpactScores` / PageRank implementation in `pagerank.ts` with `bv --robot-next` and `bv --robot-triage` calls.
- Update all agent prompts (`templates/worker-agent.md` and inline prompts in `dispatcher.ts`) to use `br` commands instead of `sd` commands.
- Update `foreman init` to initialize `.beads/` via `br init` instead of `.seeds/` via `sd init`.
- Update `foreman status` and `foreman doctor` to query `br` instead of `sd`.
- Provide a data migration path for existing `.seeds/issues.jsonl` data into `.beads/beads.jsonl`.
- Preserve all existing behavior: dispatch, monitor, reset, merge, PR creation, pipeline phases.
- Add a `--bv-triage` flag to `foreman run` that uses `bv --robot-triage` for dispatch ordering instead of static priority sort.

### 3.2 Non-Goals

- Rewriting agent pipeline business logic (Explorer, Developer, QA, Reviewer, Finalize phases).
- Changing the SQLite state store (`ForemanStore`) schema or behavior.
- Changing git worktree management.
- Rewriting the TRD parser or `sling` execution engine (already `br`-aware).
- Adding new agent capabilities not related to the task store.
- Removing `.seeds/` data from disk (migration is additive; old data is preserved).
- Supporting `bv` in non-`--robot-*` mode (bare `bv` launches an interactive TUI — this is out of scope and actively dangerous in agent contexts).

---

## 4. User Personas

### 4.1 Operator (primary)

An engineer running `foreman run` to dispatch work. Cares that tasks are dispatched in the right order, that completion is detected reliably, and that `foreman status` reflects reality. Does not care which underlying binary handles task state, as long as the CLI surface is unchanged or clearly documented.

### 4.2 Agent Worker (secondary, non-human)

A Claude Code agent running inside an isolated git worktree. Receives a `TASK.md` with instructions. Calls `br` (not `sd`) to update task status and close the issue when done. Must have the `br` binary on `PATH` in the worktree environment.

### 4.3 Foreman Developer (tertiary)

An engineer maintaining or extending Foreman itself. Benefits from removing the dual-tracker complexity, the deprecated alias layer in `seeds.ts`, and the custom PageRank code. Wants clear module boundaries and a single source of truth for task state.

---

## 5. Current State Analysis

### 5.1 Module Inventory

The following modules contain `seeds`/`sd`-specific code that must be updated:

| Module | Current Usage | Migration Action |
|--------|---------------|-----------------|
| `src/lib/seeds.ts` | `SeedsClient` class, `execSd`, interfaces (`Seed`, `SeedDetail`, `SeedGraph`) | Retain as deprecated shim or remove after migration |
| `src/lib/beads-rust.ts` | `BeadsRustClient`, `execBr`, interfaces (`BrIssue`, `BrIssueDetail`) | Extend with `ready()`, `getGraph()`/bv integration |
| `src/orchestrator/dispatcher.ts` | `seeds.ready()`, `seeds.getGraph()`, `calculateImpactScores()`, `seeds.update()` | Replace with `BeadsRustClient` + bv ordering |
| `src/orchestrator/agent-worker.ts` | `sd close`, `sd update` via `execFileSync` in `finalize()` and `markStuck()` | Replace with `br close`, `br update` |
| `src/orchestrator/monitor.ts` | `seeds.show()` to poll completion, `seeds.update()` on mismatch fix | Replace with `BeadsRustClient.show()` |
| `src/orchestrator/pagerank.ts` | Custom BFS PageRank scoring | Replace dispatch ordering with `bv --robot-next` |
| `src/cli/commands/run.ts` | `new SeedsClient(projectPath)` passed to `Dispatcher` | Pass `BeadsRustClient` instead |
| `src/cli/commands/reset.ts` | `seeds.update()`, `seeds.show()`, `detectAndFixMismatches()` | Replace with `BeadsRustClient` equivalents |
| `src/cli/commands/status.ts` | Direct `sd` CLI calls via `execFileSync` | Replace with `br` CLI calls |
| `src/cli/commands/init.ts` | `sd init`, binary check at `~/.bun/bin/sd` | Replace with `br init`, binary check at `~/.local/bin/br` |
| `src/cli/commands/doctor.ts` | Binary availability check (via `Doctor` class) | Update `Doctor` to check `br` not `sd` |
| `src/cli/commands/seed.ts` | Creates seeds from natural language | Update to create `br` issues |
| `src/cli/commands/plan.ts` | Creates seed hierarchy, closes on completion | Update to create `br` issues |
| `src/cli/commands/merge.ts` | Seed usage in refinery | Update to `br` |
| `src/cli/commands/sling.ts` | Already dual sd+br; `--br-only` flag | After migration, deprecate `--sd-only` |
| `templates/worker-agent.md` | `sd update {{SEED_ID}} --claim`, `sd close {{SEED_ID}}`, `sd update --notes` | Replace with `br` equivalents |

### 5.2 Agent Worker Detail

The `finalize()` function in `agent-worker.ts` (lines 614-623) hardcodes:
```
const sdPath = join(process.env.HOME ?? "~", ".bun", "bin", "sd");
execFileSync(sdPath, ["close", seedId, "--reason", "Completed via pipeline"], opts);
```

The `markStuck()` function (lines 820-824) hardcodes:
```
const sdPath = join(process.env.HOME ?? "~", ".bun", "bin", "sd");
execFileSync(sdPath, ["update", seedId, "--status", "open"], ...);
```

Both must be updated to use `~/.local/bin/br`.

### 5.3 Dispatcher Prompt Detail

The `spawnAgent()` method (lines 508-516) and `resumeAgent()` method (lines 557-564) in `dispatcher.ts` build inline prompts that contain:
```
sd close ${seed.id} --reason "Completed"
```

These must be updated to `br close ${seed.id} --reason "Completed"`.

### 5.4 Existing br Infrastructure

`BeadsRustClient` in `src/lib/beads-rust.ts` already implements: `create`, `list`, `show`, `update`, `close`, `addDependency`, `search`, `ensureBrInstalled`, `isInitialized`. It is missing:

- `ready()` — required to replace `seeds.ready()` in the dispatcher
- `bv`-based ordering — replaces `seeds.getGraph()` + `calculateImpactScores()`
- `compact()` — low-priority analog to `seeds.compact()`

### 5.5 bv Integration Points

`bv` operates on `.beads/beads.jsonl`. Before every `bv` call, `br sync --flush-only` must be executed to export the in-memory database to the JSONL file that `bv` reads. Failure to do this causes `bv` to operate on stale data.

`bv` must only be called with `--robot-*` flags. Bare `bv` opens an interactive TUI that blocks the calling process indefinitely. This is especially dangerous in the dispatcher, which runs in the main `foreman run` process.

---

## 6. Solution Overview

### 6.1 Architecture After Migration

```
foreman run
    |
    v
Dispatcher (BeadsRustClient)
    |
    |-- brClient.ready()          -> br list --status=open (unblocked)
    |
    |-- bv ordering               -> br sync --flush-only
    |                                bv --robot-next --format toon
    |                                (replaces pagerank.ts)
    |
    |-- brClient.update(in_progress)
    |
    v
agent-worker (isolated worktree)
    |
    |-- br update <id> --claim    (TASK.md instruction)
    |-- br close <id> --reason "Completed via pipeline"
    |-- br update <id> --status open   (markStuck recovery)
    |
    v
Monitor (BeadsRustClient)
    |
    |-- brClient.show(id)         -> detect closed status
```

### 6.2 bv Dispatch Ordering

The current `calculateImpactScores()` in `pagerank.ts` computes a custom BFS score combining direct dependents, transitive dependents, and a priority boost. This is replaced by:

```
br sync --flush-only
bv --robot-next --format toon
```

`bv --robot-next` returns the single highest-priority actionable item with a copy-paste claim command. For multi-task dispatch (up to `maxAgents` slots), the dispatcher calls `bv --robot-triage --format toon` to get a ranked list and selects the top N ready tasks.

When `bv` is unavailable or returns an error, the dispatcher falls back to priority-order sort (P0 first, P4 last), matching current behavior without the graph scoring.

### 6.3 Data Model Mapping

| seeds field | br field | Notes |
|-------------|----------|-------|
| `id` | `id` | Same semantics |
| `title` | `title` | Same |
| `type` | `type` | Vocabulary changes: seeds `task` = br `task`; seeds `epic` = br `epic` |
| `priority` | `priority` | seeds uses P0-P4 strings; br uses integers 0-4 — adapter layer needed |
| `status` | `status` | seeds: `open/in_progress/closed`; br: `open/in_progress/closed` — identical |
| `assignee` | `assignee` | Same |
| `parent` | `parent` | Same |
| `dependencies` | `dependencies` | Same semantics |
| `notes` | Notes stored as description or label | br has no dedicated `notes` field — use description append or label |
| `acceptance` | `acceptance` | br `BrIssueDetail` has `acceptance` field (already in `update()`) |

Priority adapter: `SeedsClient` uses string priorities ("P0"–"P4"). `BeadsRustClient` uses numeric strings ("0"–"4"). The `Dispatcher.selectModel()` function uses priority for tie-breaking and must be updated to handle both formats or normalize to integers.

### 6.4 BvClient Wrapper

A new `BvClient` class (or standalone functions) in `src/lib/bv.ts` encapsulates all `bv` calls:

- Always calls `br sync --flush-only` before any `bv --robot-*` invocation
- Always appends `--format toon` to minimize token consumption in agent contexts
- Enforces that bare `bv` (no `--robot-*` flag) is never called
- Returns structured results from `bv` JSON output
- Provides graceful fallback when `bv` is not installed or returns non-zero

---

## 7. Functional Requirements

### 7.1 Core Library

**REQ-001** — Replace SeedsClient in dispatcher with BeadsRustClient.
The `Dispatcher` class must accept `BeadsRustClient` as its task client. The constructor signature changes from `SeedsClient` to `BeadsRustClient`.

**REQ-002** — Add `ready()` method to BeadsRustClient.
`BeadsRustClient` must expose a `ready(): Promise<BrIssue[]>` method that returns all open, unblocked issues (equivalent to `br ready --json`).

**REQ-003** — Create BvClient in `src/lib/bv.ts`.
A new `BvClient` class must wrap all `bv` CLI invocations with:
- Pre-call `br sync --flush-only`
- Enforcement of `--robot-*` flag requirement
- `--format toon` appended by default
- Graceful degradation when `bv` is unavailable
- Binary path: `~/.local/bin/bv`

**REQ-004** — BvClient must expose `robotNext()` and `robotTriage()` methods.
`robotNext()` returns the single top-priority actionable task. `robotTriage()` returns a ranked list of actionable tasks with scores.

**REQ-005** — Dispatcher must use bv ordering when bv is available.
When dispatching without a specific `--seed` filter, the dispatcher must call `bvClient.robotTriage()` to obtain a ranked task list. Tasks are dispatched in bv's ranked order, up to `maxAgents`. When `bv` is unavailable, the dispatcher falls back to priority-field sort (current behavior).

**REQ-006** — Remove dependency on `pagerank.ts` from dispatcher.
After migrating to bv-based ordering, `src/orchestrator/pagerank.ts` must no longer be imported by `dispatcher.ts`. The file may be retained for unit tests or deleted in a follow-up.

**REQ-007** — Update `foreman run` to instantiate BeadsRustClient.
`src/cli/commands/run.ts` must construct `BeadsRustClient(projectPath)` and pass it to `Dispatcher`. The `SeedsClient` construction in this file must be removed.

**REQ-008** — Update `foreman reset` to use BeadsRustClient.
All `seeds.update()` and `seeds.show()` calls in `reset.ts` and `detectAndFixMismatches()` must be replaced with `BeadsRustClient` equivalents.

**REQ-009** — Update `foreman monitor` to use BeadsRustClient.
`src/orchestrator/monitor.ts` must accept `BeadsRustClient` as its task client. The `seeds.show()` call for completion detection must use `brClient.show()`.

**REQ-010** — Update `foreman status` to query br.
`src/cli/commands/status.ts` must replace all `execFileSync(sdPath, ...)` calls with equivalent `execFileSync(brPath, ...)` calls. The binary path must change from `~/.bun/bin/sd` to `~/.local/bin/br`.

**REQ-011** — Update `foreman init` to initialize br.
`src/cli/commands/init.ts` must:
- Check for `br` binary at `~/.local/bin/br` instead of `sd` at `~/.bun/bin/sd`
- Run `br init` instead of `sd init` when `.beads/` does not exist
- Print instructions for installing `br` (cargo install beads_rust) instead of seeds

**REQ-012** — Update `foreman doctor` to check br binary.
The `Doctor` system check must verify `~/.local/bin/br` exists and is executable instead of `~/.bun/bin/sd`.

**REQ-013** — Update agent worker to use br for task closure.
`src/orchestrator/agent-worker.ts` `finalize()` function must call `~/.local/bin/br close <seedId> --reason "Completed via pipeline"` instead of `sd close`.

**REQ-014** — Update agent worker to use br for stuck recovery.
`src/orchestrator/agent-worker.ts` `markStuck()` function must call `~/.local/bin/br update <seedId> --status open` instead of `sd update`.

**REQ-015** — Update worker prompt templates to use br commands.
`templates/worker-agent.md` must replace all `sd` references:
- `sd update {{SEED_ID}} --claim` → `br update {{SEED_ID}} --status in_progress`
- `sd close {{SEED_ID}} --reason "Completed"` → `br close {{SEED_ID}} --reason "Completed"`
- `sd update {{SEED_ID}} --notes "Blocked: ..."` → `br update {{SEED_ID}} --description "Blocked: ..."`

**REQ-016** — Update dispatcher inline prompts to use br commands.
The `spawnAgent()` and `resumeAgent()` prompt strings in `dispatcher.ts` must reference `br close` not `sd close`.

**REQ-017** — Update `foreman seed` command to create br issues.
`src/cli/commands/seed.ts` must create issues via `BeadsRustClient` instead of `SeedsClient`.

**REQ-018** — Update `foreman plan` command to create br issues.
`src/cli/commands/plan.ts` must create issues via `BeadsRustClient` instead of `SeedsClient`.

**REQ-019** — Update `foreman merge` command for br compatibility.
`src/cli/commands/merge.ts` must use `BeadsRustClient` for any task status reads or writes during merge orchestration.

**REQ-020** — Priority normalization adapter.
The dispatcher and any other consumer of task priorities must handle both the seeds string format ("P0"–"P4") and the br numeric-string format ("0"–"4"). A shared `normalizePriority(p: string): number` utility must be added to `src/lib/priority.ts` (or equivalent).

### 7.2 Migration Tooling

**REQ-021** — Add `foreman migrate-seeds` command.
A new CLI command `foreman migrate-seeds` must:
- Read `.seeds/issues.jsonl`
- Map each seed to a `br create` call with equivalent fields
- Map `blocks` dependencies via `br dep add`
- Preserve `closed` status by creating and immediately closing completed issues
- Report how many issues were created, skipped (already exist by title match), and failed
- Be idempotent: re-running must not duplicate issues

**REQ-022** — Migration command must preserve dependency graph.
All `blocks` dependency edges from `.seeds/issues.jsonl` must be recreated in `.beads/beads.jsonl` after migration.

**REQ-023** — Migration command must handle in_progress seeds.
Seeds with `status: in_progress` in `.seeds/issues.jsonl` must be created in br with `status: open` (reset to avoid orphaned in-progress state).

### 7.3 bv Integration Safety

**REQ-024** — BvClient must never call bare bv.
Any call to the `bv` binary without a `--robot-*` flag must throw a programming error at the TypeScript level (compile-time guard via allowed method signatures, not just runtime).

**REQ-025** — BvClient must always sync before calling bv.
`br sync --flush-only` must complete successfully before any `bv --robot-*` call. If sync fails, the bv call must be skipped and the fallback ordering used.

**REQ-026** — BvClient must have a configurable timeout.
`bv` calls must timeout after a configurable duration (default: 10 seconds) to prevent the dispatcher from blocking indefinitely if bv hangs.

**REQ-027** — bv unavailability must not block dispatch.
If `~/.local/bin/bv` does not exist, `BvClient` methods must return `null` or an empty result, triggering the priority-sort fallback in the dispatcher. `foreman run` must not exit with an error when bv is absent.

### 7.4 Sling Command Updates

**REQ-028** — Deprecate `--sd-only` flag in `foreman sling`.
After full migration, the `--sd-only` flag in `sling.ts` must print a deprecation warning and behave as a no-op (br-only write). The flag must not be removed in this release for backwards compatibility.

**REQ-029** — `--br-only` becomes the default behavior in sling.
When neither `--sd-only` nor `--br-only` is specified, `sling` must write to `br` only (not both), since `sd` is no longer the active store.

---

## 8. Non-Functional Requirements

**REQ-NF-001 — Binary availability check on startup.**
`foreman run`, `foreman status`, and `foreman reset` must verify `~/.local/bin/br` exists before proceeding. Clear error messages with installation instructions (`cargo install beads_rust`) must be printed on failure.

**REQ-NF-002 — Worker binary path in spawned env.**
The `PATH` injected into worker environments must include the directory containing the `br` binary (`~/.local/bin`). Currently the path includes `/opt/homebrew/bin`. The migration must ensure `~/.local/bin` is also present.

**REQ-NF-003 — No increase in agent dispatch latency.**
The bv-based dispatch ordering (sync + robot-triage) must complete within 3 seconds for projects with up to 500 issues. If it exceeds this threshold, the fallback ordering must activate automatically.

**REQ-NF-004 — Backwards compatibility for existing runs.**
In-flight SQLite run records that reference seeds IDs must continue to be trackable during and after migration. The `seed_id` column in the SQLite store stores issue IDs which are the same format in both `sd` and `br`.

**REQ-NF-005 — Test coverage.**
- Unit tests for `BvClient`: sync-before-call behavior, timeout, fallback on unavailability, bare-bv guard.
- Unit tests for `BeadsRustClient.ready()`.
- Unit tests for priority normalization adapter.
- Integration tests for `foreman migrate-seeds`: idempotency, dependency preservation.
- Updated dispatcher tests replacing SeedsClient mocks with BeadsRustClient mocks.
- Updated monitor tests replacing SeedsClient mocks with BeadsRustClient mocks.
- Target: unit >= 80%, integration >= 70% (unchanged from project standard).

**REQ-NF-006 — TypeScript strict mode compliance.**
All new and modified files must pass `npx tsc --noEmit` with zero errors. No `any` escape hatches.

**REQ-NF-007 — ESM import compliance.**
All new imports must use `.js` extensions per project ESM convention.

---

## 9. Migration Strategy

### 9.1 Phase 0 — Foundation (no breaking changes)

Deliverables that can be merged to `main` without breaking existing functionality:

1. Add `ready()` to `BeadsRustClient` in `src/lib/beads-rust.ts`.
2. Create `src/lib/bv.ts` with `BvClient` class.
3. Create `src/lib/priority.ts` with `normalizePriority()`.
4. Add unit tests for all three.
5. Implement `foreman migrate-seeds` command (standalone, does not affect run path).

No existing code paths change in Phase 0.

### 9.2 Phase 1 — Library Core (guarded by feature flag)

Replace `SeedsClient` with `BeadsRustClient` in the runtime path, guarded by environment variable `FOREMAN_TASK_BACKEND`:

- `FOREMAN_TASK_BACKEND=br` → use `BeadsRustClient` + `BvClient`
- `FOREMAN_TASK_BACKEND=sd` (default during transition) → use `SeedsClient` (existing behavior)

Deliverables:
1. Update `Dispatcher` constructor to accept `SeedsClient | BeadsRustClient` (union type via shared interface).
2. Update `Monitor` constructor to accept the same union.
3. Update `run.ts`, `reset.ts`, `monitor.ts` (CLI) to check env var and instantiate the appropriate client.
4. Update `agent-worker.ts` `finalize()` and `markStuck()` to check env var and call `br` or `sd` accordingly.
5. Update dispatcher inline prompts to use env-conditional task commands.

### 9.3 Phase 2 — Template and Prompt Migration

Update agent-facing content (does not require env flag since agents follow TASK.md):
1. Update `templates/worker-agent.md` to use `br` commands.
2. Update dispatcher prompt strings to use `br close` and `br update`.
3. Update `foreman seed`, `foreman plan`, `foreman merge` to use `BeadsRustClient`.

Workers spawned after this phase will use `br` commands unconditionally. Workers already in-flight (running against `sd`) will complete normally since they carry their prompts in `TASK.md`.

### 9.4 Phase 3 — Init and Status Migration

Migrate the foreman project setup surface:
1. Update `foreman init` to check `br` binary and run `br init`.
2. Update `foreman status` to query `br` CLI.
3. Update `foreman doctor` to check `br` binary.
4. Set `FOREMAN_TASK_BACKEND=br` as the new default.
5. Deprecate `--sd-only` in `sling`.

### 9.5 Phase 4 — Cleanup

After a stabilization period (minimum 2 weeks of production use):
1. Remove the `FOREMAN_TASK_BACKEND` feature flag.
2. Remove `SeedsClient` construction from all CLI commands.
3. Archive `src/lib/seeds.ts` to `src/lib/seeds.deprecated.ts` or delete it.
4. Delete or archive `src/orchestrator/pagerank.ts` (replaced by bv).
5. Remove deprecated `BeadsClient`, `Bead`, `BeadDetail`, `BeadGraph` aliases.

### 9.6 Data Migration

Operators with existing `.seeds/issues.jsonl` data must run `foreman migrate-seeds` once before switching to `FOREMAN_TASK_BACKEND=br`. The migration:

1. Reads `.seeds/issues.jsonl`.
2. For each issue in priority order (P0 first):
   - Calls `br create --title "..." --type <mapped-type> --priority <n>`
   - Records the mapping of old seed ID to new br ID.
3. After all issues are created, replays `blocks` dependency edges using the ID mapping.
4. Closes issues that were `closed` in seeds via `br close <id>`.
5. Writes a migration report to `docs/seeds-migration-report.md`.

Issues that are `in_progress` in seeds are created as `open` in br. In-flight foreman runs against seeds-based tasks will continue until their current pipeline completes, after which the task will be closed in seeds. Operators should run `foreman reset` before running the migration to ensure no tasks are stuck in `in_progress`.

---

## 10. Risks and Mitigations

### 10.1 Critical Risks

**RISK-001 — bv TUI blocking agent processes.**
If any code path calls `bv` without `--robot-*` flags, it opens an interactive TUI that blocks the calling process indefinitely. In agent workers, this would cause the entire pipeline to stall and eventually be marked `stuck`.

Mitigation: `BvClient` enforces `--robot-*` flag at the TypeScript method signature level. There is no public method that permits bare `bv` invocation. Integration tests verify the flag is always present in the subprocess arguments.

**RISK-002 — Stale bv data due to missing sync.**
`bv` reads from `.beads/beads.jsonl`. If `br sync --flush-only` is not called before `bv`, the triage output may not reflect recently created or updated issues, causing the dispatcher to order tasks incorrectly.

Mitigation: `BvClient.robotTriage()` and `BvClient.robotNext()` always call `br sync --flush-only` as their first step. This is not optional and cannot be bypassed by callers.

**RISK-003 — br binary unavailable in agent worktrees.**
Agent workers run in isolated git worktrees with the parent process environment. If `~/.local/bin` is not on `PATH` in the spawned environment, workers cannot call `br close` or `br update`, leaving tasks in `in_progress` state forever.

Mitigation: `buildWorkerEnv()` in `dispatcher.ts` must include `~/.local/bin` in the `PATH`. This is verified by a startup check in `foreman doctor`. Agent integration tests verify `br` is callable from within a simulated worktree environment.

**RISK-004 — Priority format mismatch.**
Seeds uses "P0"–"P4" string priorities. `br` uses numeric integers 0–4. If the dispatcher's model selection or tie-breaking logic receives a numeric string ("0") instead of "P0", `priorityBoost()` in `pagerank.ts` returns 0.0, causing all tasks to tie on priority.

Mitigation: `normalizePriority()` in `src/lib/priority.ts` handles both formats. All priority comparisons in the dispatcher (and `selectModel()`) must go through this utility. `pagerank.ts` is deleted in Phase 4, removing the affected code.

### 10.2 Medium Risks

**RISK-005 — In-flight runs during migration cutover.**
If `FOREMAN_TASK_BACKEND` is switched from `sd` to `br` while agents are in-flight working against seeds issues, the `monitor.ts` will call `brClient.show(seedId)` but the issue ID does not exist in `.beads/`. `show()` will throw, causing the monitor to mark the run as `failed`.

Mitigation: Run `foreman reset` (which resets all active runs to open) before running `foreman migrate-seeds` and before switching the backend. Document this as a required migration step. Monitor's `show()` error handler must distinguish "issue not found" from genuine failure and treat "not found" as a transient state rather than immediately marking the run failed.

**RISK-006 — Missing `notes` field in br.**
`SeedsClient.update()` accepts a `notes` field. `br update` has no `--notes` flag. Worker agents that call `sd update --notes "Blocked: ..."` to record blockers have no direct equivalent in `br`.

Mitigation: Map `notes` to a description append or use `br update --description "..."` with a "NOTE:" prefix. Update the worker prompt template to use description instead of notes. This is a behavioral change agents must follow per their updated `TASK.md`.

**RISK-007 — bv install not standard.**
`bv` (beads_viewer) is a separate binary from `br` (beads_rust). Operators who have `br` installed may not have `bv`. The dispatcher must not fail if only `br` is present.

Mitigation: `BvClient` returns `null` from all methods when `~/.local/bin/bv` does not exist. The dispatcher treats `null` from bv as a signal to use priority-sort fallback. `foreman doctor` reports `bv` as a warning (not a failure) when absent.

### 10.3 Low Risks

**RISK-008 — Type mapping for `SeedGraph` consumers.**
The `reset.ts` `detectAndFixMismatches()` function and any other code that uses `SeedGraph` will need to use the br equivalent. `br` does not expose a `graph` command — graph data is consumed via `bv --robot-*`.

Mitigation: `detectAndFixMismatches()` only uses `seeds.show()` and `seeds.update()`, not `getGraph()`. The graph is only used in the dispatcher for ordering, which is replaced by bv. The `SeedGraph` type and `getGraph()` method have no consumers after the dispatcher migration.

**RISK-009 — `foreman doctor` failing for both sd and br.**
During the transition period, projects that have initialized with `sd init` but not yet run `foreman migrate-seeds` will fail `doctor` checks for both `br` (not yet initialized) and potentially `sd` (being deprecated).

Mitigation: During Phase 1-2, `foreman doctor` checks for both `br` and `sd` binaries, treating `sd` absence as a warning and `br` absence as a failure. After Phase 4, only `br` is checked.

---

## 11. Acceptance Criteria

### AC-001 — Dispatcher uses br for task discovery

**Given** a project with `.beads/beads.jsonl` containing 5 open unblocked issues,
**When** `foreman run` is invoked,
**Then** the dispatcher calls `brClient.ready()` (not `execSd(["ready"])`) and returns the 5 issues as dispatch candidates.

### AC-002 — bv ordering replaces PageRank

**Given** a project with bv installed and `.beads/beads.jsonl` containing 10 tasks with dependencies,
**When** `foreman run` is invoked without a `--seed` filter,
**Then** `br sync --flush-only` is called before dispatch ordering, `bv --robot-triage --format toon` is called to rank tasks, and dispatched tasks appear in bv's ranked order.

### AC-003 — bv unavailability triggers fallback

**Given** a project where `~/.local/bin/bv` does not exist,
**When** `foreman run` is invoked,
**Then** the dispatcher logs a warning, uses priority-field sort as fallback, and dispatches tasks normally without exiting with an error.

### AC-004 — Agent worker uses br for task closure

**Given** an agent worker completing a task in pipeline mode,
**When** the finalize phase executes,
**Then** `~/.local/bin/br close <seedId> --reason "Completed via pipeline"` is called (not `sd close`), and the issue's status in `.beads/beads.jsonl` becomes `closed`.

### AC-005 — Agent worker uses br for stuck recovery

**Given** an agent worker that fails in the developer phase,
**When** `markStuck()` executes,
**Then** `~/.local/bin/br update <seedId> --status open` is called, and the issue is visible in `br ready` output.

### AC-006 — TASK.md instructs agent to use br

**Given** a task is dispatched with `FOREMAN_TASK_BACKEND=br`,
**When** `TASK.md` is written to the worktree,
**Then** the TASK.md file contains `br update`, `br close`, and `br update --description` instructions and no `sd` command references.

### AC-007 — foreman init initializes br

**Given** a project directory without `.beads/`,
**When** `foreman init` is run,
**Then** `.beads/beads.jsonl` is created via `br init`, and `foreman doctor` passes the br binary check.

### AC-008 — foreman status displays br task counts

**Given** a project with 10 open br issues (3 unblocked, 2 in_progress, 5 closed),
**When** `foreman status` is run,
**Then** the output displays: Ready: 3, In Progress: 2, Completed: 5, and no subprocess calls to `~/.bun/bin/sd` are made.

### AC-009 — foreman migrate-seeds is idempotent

**Given** a project with `.seeds/issues.jsonl` containing 20 issues and `.beads/beads.jsonl` already containing 10 of those issues (by title match),
**When** `foreman migrate-seeds` is run,
**Then** exactly 10 new br issues are created, 10 are skipped, 0 errors occur, and the command exits 0.

### AC-010 — foreman migrate-seeds preserves dependency graph

**Given** `.seeds/issues.jsonl` containing issue A that blocks issue B,
**When** `foreman migrate-seeds` runs,
**Then** the corresponding br issues have the same `blocks` dependency relationship, and `br ready` does not include the br-B issue until br-A is closed.

### AC-011 — br binary on PATH in worker environment

**Given** a worker agent spawned by the dispatcher,
**When** the worker executes `br close <id>`,
**Then** the command succeeds without "command not found" error, because `~/.local/bin` is present in the worker's PATH.

### AC-012 — Monitor detects br task completion

**Given** an active run tracking br issue `xyz`,
**When** `brClient.show("xyz")` returns `status: "closed"`,
**Then** `Monitor.checkAll()` marks the SQLite run as `completed` and logs a `complete` event.

### AC-013 — foreman reset resets br task status

**Given** a run in `stuck` status with br issue `abc` in `in_progress`,
**When** `foreman reset` is run,
**Then** `brClient.update("abc", { status: "open" })` is called, and `br ready` includes issue `abc` afterwards.

### AC-014 — BvClient enforces sync before triage

**Given** a `BvClient` instance,
**When** `robotTriage()` is called,
**Then** `br sync --flush-only` completes before `bv --robot-triage` is called (verifiable via subprocess call order in unit tests).

### AC-015 — BvClient times out gracefully

**Given** a `BvClient` with a 5-second timeout configuration,
**When** `bv --robot-triage` does not return within 5 seconds,
**Then** the call is aborted, `robotTriage()` returns `null`, and the dispatcher logs a warning and uses the fallback ordering.

### AC-016 — TypeScript compiles without errors

**Given** all migration changes applied,
**When** `npx tsc --noEmit` is run,
**Then** zero TypeScript errors are reported.

### AC-017 — Existing tests pass

**Given** all migration changes applied,
**When** `npm test` is run,
**Then** all previously passing tests continue to pass (no regressions). Updated mock types must use `BeadsRustClient` interfaces.

---

## 12. Success Metrics

| Metric | Baseline (seeds) | Target (br + bv) | Measurement |
|--------|-----------------|-----------------|-------------|
| Task query latency (`ready`) | ~80ms (bun spawn) | <30ms (Rust binary) | `time br ready` vs `time sd ready` |
| Dispatch ordering accuracy | Custom BFS PageRank | bv betweenness + critical path | % of highest-impact tasks dispatched first in A/B test |
| Code maintainability: LOC removed | 0 | -300 LOC (pagerank.ts + seeds.ts aliases) | `git diff --stat` |
| Agent completion rate | Baseline | No regression (<1% delta) | Runs completed / runs dispatched over 2 weeks |
| Doctor check pass rate | Baseline | >95% of projects pass br check after migration | `foreman doctor` exit code |
| bv fallback rate | N/A | <5% of dispatches use fallback | Log analysis: "bv unavailable" log lines / total dispatches |

---

## 13. Release Plan

### Sprint 1 — Phase 0: Foundation (1 week)

Tasks:
- Add `ready()` to `BeadsRustClient`
- Create `src/lib/bv.ts` (`BvClient`)
- Create `src/lib/priority.ts` (`normalizePriority`)
- Implement `foreman migrate-seeds` command
- Unit tests for all new code

Exit criteria: `npm test` passes, `foreman migrate-seeds --dry-run` works on existing `.seeds/` data.

### Sprint 2 — Phase 1: Runtime Core (1 week)

Tasks:
- Add `FOREMAN_TASK_BACKEND` env var feature flag
- Update `Dispatcher` to accept br client
- Update `Monitor` to accept br client
- Update `run.ts`, `reset.ts`, `monitor.ts` CLI commands
- Update `agent-worker.ts` `finalize()` and `markStuck()`
- Integration tests: dispatch with `FOREMAN_TASK_BACKEND=br`

Exit criteria: `FOREMAN_TASK_BACKEND=br foreman run` dispatches tasks using br and bv ordering.

### Sprint 3 — Phase 2 + 3: Templates and Init (1 week)

Tasks:
- Update `templates/worker-agent.md`
- Update dispatcher inline prompts
- Update `foreman seed`, `foreman plan`, `foreman merge`
- Update `foreman init` (br init)
- Update `foreman status` (br queries)
- Update `foreman doctor` (br binary check)
- Set `FOREMAN_TASK_BACKEND=br` as default

Exit criteria: All CLI commands work end-to-end without sd. `foreman doctor` passes on a fresh br-initialized project.

### Sprint 4 — Phase 4: Cleanup and Stabilization (1 week)

Tasks:
- Remove `FOREMAN_TASK_BACKEND` feature flag
- Archive/delete `src/lib/seeds.ts` deprecated aliases
- Archive/delete `src/orchestrator/pagerank.ts`
- Remove `SeedsClient` from all imports
- Update all test mocks to use `BeadsRustClient`
- Deprecation warning on `--sd-only` in sling
- Final documentation pass

Exit criteria: `grep -r "SeedsClient\|execSd\|~/.bun/bin/sd" src/` returns zero results (except in archived files).

---

## 14. Open Questions

**Q1.** Should `pagerank.ts` be archived (moved to `src/lib/legacy/`) or deleted outright after migration? Keeping it allows reactivation if bv proves unavailable in CI environments. Deleting it enforces the migration irreversibly.

**Q2.** Does `br update` support a `--claim` atomic flag equivalent to `sd update --claim`? The `BeadsRustClient.update()` method includes `claim?: boolean` but the underlying br CLI behavior needs verification to confirm atomicity under concurrent agent dispatch.

**Q3.** What is the br equivalent for `sd blocked`? The `foreman status` command calls `sd blocked --json` to count blocked tasks. If `br` has no `blocked` subcommand, this count must be derived from `br list --status=open` minus `br ready`.

**Q4.** Should `foreman migrate-seeds` attempt to preserve original issue IDs? `br` may assign new sequential IDs on create. If SQLite run records reference seeds IDs and those IDs change, the monitor will fail to find in-flight runs. The recommended approach is to complete or reset all in-flight runs before migration, but an ID-preservation option in `br create` (if available) would simplify rollback.

**Q5.** Is `bv --robot-triage --format toon` output stable enough for programmatic parsing? The `toon` (Token-Optimized Output Notation) format is described as lower-LLM-context, but if its schema changes between bv versions, `BvClient` parsing will break silently. A version pin or output schema validation may be needed.

---

## Appendix A: File Change Summary

| File | Change Type | Phase |
|------|-------------|-------|
| `src/lib/beads-rust.ts` | Extend (add `ready()`) | Phase 0 |
| `src/lib/bv.ts` | Create (`BvClient`) | Phase 0 |
| `src/lib/priority.ts` | Create (`normalizePriority`) | Phase 0 |
| `src/cli/commands/migrate-seeds.ts` | Create | Phase 0 |
| `src/orchestrator/dispatcher.ts` | Replace SeedsClient, add bv ordering | Phase 1 |
| `src/orchestrator/monitor.ts` | Replace SeedsClient | Phase 1 |
| `src/orchestrator/agent-worker.ts` | Replace sd binary paths | Phase 1 |
| `src/cli/commands/run.ts` | Replace SeedsClient instantiation | Phase 1 |
| `src/cli/commands/reset.ts` | Replace SeedsClient | Phase 1 |
| `src/cli/commands/monitor.ts` | Replace SeedsClient | Phase 1 |
| `templates/worker-agent.md` | Replace sd commands with br | Phase 2 |
| `src/cli/commands/seed.ts` | Replace SeedsClient | Phase 2 |
| `src/cli/commands/plan.ts` | Replace SeedsClient | Phase 2 |
| `src/cli/commands/merge.ts` | Replace SeedsClient | Phase 2 |
| `src/cli/commands/init.ts` | Replace sd init with br init | Phase 3 |
| `src/cli/commands/status.ts` | Replace sd CLI calls | Phase 3 |
| `src/cli/commands/doctor.ts` | Replace sd binary check | Phase 3 |
| `src/cli/commands/sling.ts` | Deprecate `--sd-only` | Phase 3 |
| `src/orchestrator/pagerank.ts` | Delete or archive | Phase 4 |
| `src/lib/seeds.ts` | Archive or delete | Phase 4 |

## Appendix B: br vs sd Command Mapping

| seeds (sd) command | br equivalent | Notes |
|-------------------|---------------|-------|
| `sd init` | `br init` | |
| `sd create --title "X" --type task --priority P2` | `br create --title "X" --type task --priority 2` | Priority is numeric in br |
| `sd list --status open --json` | `br list --status=open --json` | |
| `sd list --limit 0 --json` | `br list --json` (no limit by default in br) | Confirm br default limit |
| `sd ready --json` | `br ready --json` | |
| `sd show <id> --json` | `br show <id> --json` | |
| `sd update <id> --claim` | `br update <id> --claim` | Verify atomicity |
| `sd update <id> --status open` | `br update <id> --status open` | |
| `sd update <id> --notes "..."` | `br update <id> --description "NOTE: ..."` | br has no notes field |
| `sd close <id> --reason "..."` | `br close <id> --reason "..."` | |
| `sd dep add <child> <parent>` | `br dep add <child> <parent>` | Same syntax |
| `sd graph` | bv --robot-insights (read-only) | No direct equivalent |
| `sd blocked --json` | Derived: `br list --status=open` minus `br ready` | No direct equivalent |
| `sd compact` | `br sync --flush-only` | Different semantics but closest analog |
