# TRD: Migrate Task Management from seeds (sd) to br + bv

**Document ID:** TRD-2026-001
**Source PRD:** PRD-2026-001 v1.1
**Version:** 1.0
**Status:** Draft
**Date:** 2026-03-16
**Author:** Tech Lead (tech-lead-orchestrator)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Architecture](#2-system-architecture)
3. [Key Architectural Decisions](#3-key-architectural-decisions)
4. [Non-Functional Requirements Coverage](#4-non-functional-requirements-coverage)
5. [Master Task List](#5-master-task-list)
6. [Sprint Planning](#6-sprint-planning)
7. [Acceptance Criteria Traceability Matrix](#7-acceptance-criteria-traceability-matrix)
8. [Team Configuration](#8-team-configuration)
9. [Risk Register](#9-risk-register)
10. [Definition of Done](#10-definition-of-done)

---

## 1. Executive Summary

This TRD translates PRD-2026-001 into an executable implementation plan for migrating Foreman's task management from seeds (sd) to br (beads_rust) with bv (beads_viewer) as the always-on dispatch ordering engine. The migration spans 4 sprints across 4 weeks, producing 28 implementation tasks with paired verification tasks, organized into Foundation, Runtime Core, Templates/Init, and Cleanup phases.

The migration preserves all existing Foreman behavior while replacing the task store, eliminating custom PageRank code, and introducing graph-aware triage as the default dispatch strategy.

---

## 2. System Architecture

### 2.1 Component Diagram (Post-Migration)

```
                         foreman CLI
                             |
              +--------------+--------------+
              |              |              |
          run.ts         status.ts      init.ts
          reset.ts       doctor.ts      seed.ts
          monitor.ts     merge.ts       plan.ts
              |              |           sling.ts
              v              v              |
         +----------+  +-----------+       |
         |Dispatcher|  |  CLI      |       |
         |          |  |  Direct   |       |
         +----+-----+  |  br calls |       |
              |         +-----------+       |
     +--------+--------+                   |
     |                  |                   |
     v                  v                   v
+----------+      +---------+        +----------+
|BvClient  |      |BeadsRust|        |BeadsRust |
|src/lib/  |      |Client   |        |Client    |
|bv.ts     |      |src/lib/ |        |(sling)   |
+----+-----+      |beads-   |        +----------+
     |            |rust.ts  |
     |            +----+----+
     |                 |
     v                 v
+----------+     +----------+
|bv binary |     |br binary |
|~/.local/ |     |~/.local/ |
|bin/bv    |     |bin/br    |
+----------+     +----+-----+
     |                 |
     v                 v
+----------------------------+
| .beads/beads.jsonl         |
| (single source of truth)   |
+----------------------------+
```

### 2.2 Data Flow: Dispatch Ordering (Always-On bv)

```
Dispatcher.dispatch()
    |
    |--> brClient.ready()
    |        |
    |        v
    |    br ready --json  -->  BrIssue[]
    |
    |--> bvClient.robotTriage()
    |        |
    |        |--> br sync --flush-only
    |        |        (ensures .beads/beads.jsonl is current)
    |        |
    |        |--> bv --robot-triage --format toon
    |        |        (ranked actionable tasks with scores)
    |        |
    |        |--> Parse toon output --> BvTriageResult | null
    |
    |--> IF bvTriageResult !== null:
    |        Order ready tasks by bv ranking
    |    ELSE:
    |        Fallback: sort by normalizePriority(task.priority) ASC
    |        Log warning: "bv unavailable, using priority-sort fallback"
    |
    |--> Dispatch top N tasks (up to maxAgents slots)
```

### 2.3 Worker Environment PATH Configuration

```
buildWorkerEnv() in dispatcher.ts:
    currentPATH = process.env.PATH
    brDir = join(HOME, ".local", "bin")    // ~/.local/bin
    newPATH = brDir + ":" + currentPATH    // prepend to ensure br/bv found first
    return { ...env, PATH: newPATH }
```

### 2.4 Feature Flag Lifecycle

```
Phase 0 (Sprint 1):  No flag needed. New code is additive only.
Phase 1 (Sprint 2):  FOREMAN_TASK_BACKEND=sd (default) | br
Phase 2+3 (Sprint 3): FOREMAN_TASK_BACKEND=br (new default)
Phase 4 (Sprint 4):  Flag removed. br-only.
```

---

## 3. Key Architectural Decisions

### ADR-001: Shared ITaskClient Interface

Both SeedsClient and BeadsRustClient will implement a shared ITaskClient interface during the transition period (Sprint 2). This enables the feature flag to swap implementations without changing consumer code in Dispatcher, Monitor, and CLI commands.

```typescript
interface ITaskClient {
  ready(): Promise<TaskIssue[]>;
  list(opts?: ListOptions): Promise<TaskIssue[]>;
  show(id: string): Promise<TaskIssueDetail>;
  update(id: string, fields: UpdateFields): Promise<void>;
  close(id: string, reason?: string): Promise<void>;
  create(fields: CreateFields): Promise<string>;
}
```

After Sprint 4, the interface may be retained or collapsed since only BeadsRustClient remains.

### ADR-002: BvClient Safety -- No Bare bv Invocation

BvClient exposes only typed methods (robotNext, robotTriage, robotPlan, robotInsights, robotAlerts). There is no generic exec(args) method. This ensures at the TypeScript compile level that --robot-* flags are always present. The class has a single private execBv(robotFlag, extraArgs) method that prepends --robot- to the flag name.

### ADR-003: Always-On bv Ordering

No configuration flag controls bv ordering. Dispatcher.dispatch() always calls bvClient.robotTriage() first. The method returns null on any failure (binary missing, timeout, parse error), which the dispatcher treats as a signal to use priority-sort fallback. This decision aligns with PRD REQ-005.

### ADR-004: Worker env PATH Prepend

buildWorkerEnv() in dispatcher.ts prepends ~/.local/bin to PATH. This ensures br and bv binaries are discoverable in worker worktree environments without requiring operators to modify their shell profiles.

### ADR-005: Priority Normalization

A single normalizePriority(p: string | number): number utility in src/lib/priority.ts handles all formats:
- "P0" through "P4" --> 0 through 4
- "0" through "4" --> 0 through 4
- 0 through 4 --> pass-through
- Invalid input --> 4 (lowest priority, safe default)

All priority comparisons throughout the codebase go through this utility.

---

## 4. Non-Functional Requirements Coverage

- [ ] **TRD-NF-001**: Binary availability check on startup (2h) [satisfies REQ-NF-001]
  - foreman run, foreman status, foreman reset verify ~/.local/bin/br exists before proceeding
  - Clear error with cargo install beads_rust instructions on missing binary
  - bv absence is warning only (dispatch fallback), not blocking error
  - [depends: TRD-007, TRD-008, TRD-019]

- [ ] **TRD-NF-001-TEST**: Verify binary checks on startup (1h) [verifies TRD-NF-001]
  - Test run/status/reset fail gracefully with missing br binary
  - Test bv absence produces warning but does not block

- [ ] **TRD-NF-002**: Worker binary PATH configuration (1h) [satisfies REQ-NF-002]
  - buildWorkerEnv() prepends ~/.local/bin to PATH
  - [depends: TRD-005]

- [ ] **TRD-NF-002-TEST**: Verify worker PATH includes br directory (1h) [verifies TRD-NF-002]
  - Test buildWorkerEnv() output contains ~/.local/bin before other PATH entries

- [ ] **TRD-NF-003**: Dispatch latency within 3-second budget (1h) [satisfies REQ-NF-003]
  - bv timeout configured at 3 seconds for projects up to 500 issues
  - Timeout triggers automatic priority-sort fallback
  - [depends: TRD-002, TRD-006]

- [ ] **TRD-NF-003-TEST**: Verify dispatch latency and timeout fallback (1h) [verifies TRD-NF-003]
  - Test bv call timeout triggers fallback within budget
  - Test priority-sort completes in under 100ms

- [ ] **TRD-NF-004**: Backwards compatibility for in-flight SQLite runs (1h) [satisfies REQ-NF-004]
  - SQLite seed_id column stores IDs compatible with both sd and br formats
  - Monitor handles "issue not found" as transient during migration
  - [depends: TRD-009]

- [ ] **TRD-NF-004-TEST**: Verify in-flight run compatibility (1h) [verifies TRD-NF-004]
  - Test monitor handles missing issue ID gracefully during migration

- [ ] **TRD-NF-005**: Test coverage targets met (2h) [satisfies REQ-NF-005]
  - Unit tests >= 80% for all new/modified files
  - Integration tests >= 70% for dispatch and migration paths
  - [depends: all TRD-NNN-TEST tasks]

- [ ] **TRD-NF-005-TEST**: Coverage report validation (1h) [verifies TRD-NF-005]
  - Run coverage report, verify thresholds

- [ ] **TRD-NF-006**: TypeScript strict mode compliance (0.5h) [satisfies REQ-NF-006]
  - npx tsc --noEmit passes with zero errors after each sprint
  - No any escape hatches in new or modified code

- [ ] **TRD-NF-006-TEST**: Verify TypeScript compilation (0.5h) [verifies TRD-NF-006]
  - CI gate: npx tsc --noEmit returns exit code 0

- [ ] **TRD-NF-007**: ESM import compliance (0.5h) [satisfies REQ-NF-007]
  - All new imports use .js extensions per project convention

- [ ] **TRD-NF-007-TEST**: Verify ESM imports (0.5h) [verifies TRD-NF-007]
  - Lint check: no imports missing .js extension in new/modified files

---

## 5. Master Task List

### Sprint 1 -- Phase 0: Foundation (No Breaking Changes)

- [x] **TRD-001**: Add ready() method to BeadsRustClient (2h) [satisfies REQ-002]
  - Add ready(): Promise<BrIssue[]> to src/lib/beads-rust.ts
  - Calls br ready --json and parses output
  - Returns all open, unblocked issues

- [x] **TRD-001-TEST**: Unit tests for BeadsRustClient.ready() (1h) [verifies TRD-001]
  - Test ready() returns parsed BrIssue array
  - Test ready() handles empty result
  - Test ready() handles br binary not found
  - Test ready() handles malformed JSON output

- [x] **TRD-002**: Create BvClient in src/lib/bv.ts (4h) [satisfies REQ-003, REQ-004, REQ-024, REQ-025, REQ-026, REQ-027]
  - Create BvClient class with typed robot methods only
  - robotNext(opts?): returns single top-priority task or null
  - robotTriage(opts?): returns ranked list of actionable tasks or null
  - robotPlan(opts?): returns parallel execution tracks or null
  - robotInsights(opts?): returns full metrics or null
  - robotAlerts(opts?): returns stale/blocking/mismatch alerts or null
  - Private execBv(robotFlag, extraArgs) always prepends --robot- and --format toon
  - Always calls br sync --flush-only before any bv invocation
  - Configurable timeout (default 10 seconds)
  - Returns null on: binary not found, timeout, non-zero exit, parse error
  - Binary path: ~/.local/bin/bv

- [x] **TRD-002-TEST**: Unit tests for BvClient (3h) [verifies TRD-002]
  - Test robotTriage() calls br sync before bv
  - Test robotTriage() returns parsed result on success
  - Test robotNext() returns single task on success
  - Test all methods return null when bv binary missing
  - Test timeout triggers null return
  - Test non-zero exit triggers null return
  - Test malformed output triggers null return
  - Test --format toon is always appended
  - Test no public method allows bare bv invocation (compile-time: no exec method exposed)

- [x] **TRD-003**: Create priority.ts with normalizePriority() (1h) [satisfies REQ-020]
  - Create src/lib/priority.ts
  - Export normalizePriority(p: string | number): number
  - Handle "P0"-"P4" string format (strip P prefix, parse int)
  - Handle "0"-"4" numeric string format
  - Handle 0-4 number pass-through
  - Return 4 (lowest) for invalid input
  - Export formatPriorityForBr(p: string | number): string (returns "0"-"4")

- [x] **TRD-003-TEST**: Unit tests for normalizePriority() (1h) [verifies TRD-003]
  - Test "P0" through "P4" return 0 through 4
  - Test "0" through "4" return 0 through 4
  - Test numeric 0 through 4 pass-through
  - Test invalid inputs ("P5", "high", "", null) return 4
  - Test formatPriorityForBr() output

- [x] **TRD-004**: Implement foreman migrate-seeds command (4h) [satisfies REQ-021, REQ-022, REQ-023]
  - Create src/cli/commands/migrate-seeds.ts
  - Register in commander CLI
  - Read .seeds/issues.jsonl line by line
  - For each seed: call br create with mapped fields (type, priority as number, title, description)
  - Track old-seed-ID to new-br-ID mapping
  - After all creates: replay blocks dependency edges via br dep add
  - Seeds with status: in_progress created as status: open in br
  - Seeds with status: closed created then immediately closed via br close
  - Idempotency: skip issues that already exist (match by title)
  - Report: created count, skipped count, failed count
  - Write migration report to docs/seeds-migration-report.md
  - --dry-run flag: report what would happen without creating

- [x] **TRD-004-TEST**: Unit and integration tests for migrate-seeds (3h) [verifies TRD-004]
  - Test reads .seeds/issues.jsonl correctly
  - Test creates br issues with correct field mapping
  - Test priority "P2" maps to numeric 2 in br create
  - Test in_progress seeds created as open in br
  - Test closed seeds created and closed in br
  - Test dependency edges preserved (A blocks B in seeds --> A blocks B in br)
  - Test idempotency: re-run skips existing issues by title
  - Test dry-run produces report without creating issues
  - Test handles missing .seeds/issues.jsonl gracefully
  - Test handles empty .seeds/issues.jsonl

### Sprint 2 -- Phase 1: Runtime Core (Feature-Flagged)

- [x] **TRD-005**: Update Dispatcher to accept BeadsRustClient (4h) [satisfies REQ-001]
  - Define ITaskClient interface in src/lib/task-client.ts
  - Make both SeedsClient and BeadsRustClient implement ITaskClient
  - Change Dispatcher constructor to accept ITaskClient
  - Update selectModel() to use normalizePriority() for priority comparisons
  - Update buildWorkerEnv() to prepend ~/.local/bin to PATH
  - [depends: TRD-001, TRD-003]

- [ ] **TRD-005-TEST**: Unit tests for Dispatcher with ITaskClient (3h) [verifies TRD-005]
  - Test Dispatcher accepts BeadsRustClient via ITaskClient
  - Test Dispatcher accepts SeedsClient via ITaskClient (backward compat)
  - Test selectModel() works with numeric priority format
  - Test selectModel() works with "P0"-"P4" format
  - Test buildWorkerEnv() includes ~/.local/bin in PATH

- [ ] **TRD-006**: Wire BvClient into dispatcher ordering (always-on) (3h) [satisfies REQ-005, REQ-006]
  - Inject BvClient into Dispatcher constructor
  - In dispatch(): call bvClient.robotTriage() for ranked ordering
  - If robotTriage returns non-null: order ready tasks by bv ranking
  - If robotTriage returns null: fallback to normalizePriority() sort
  - Log warning on fallback: "bv unavailable, using priority-sort fallback"
  - Remove import of calculateImpactScores from pagerank.ts
  - [depends: TRD-002, TRD-005]

- [ ] **TRD-006-TEST**: Unit tests for bv-ordered dispatch (3h) [verifies TRD-006]
  - Test dispatch calls robotTriage() before ordering
  - Test tasks dispatched in bv ranked order when available
  - Test fallback to priority sort when robotTriage returns null
  - Test warning logged on fallback
  - Test no import of pagerank.ts calculateImpactScores
  - Test dispatch proceeds normally when bv times out

- [ ] **TRD-007**: Update run.ts to instantiate BeadsRustClient (2h) [satisfies REQ-007]
  - Read FOREMAN_TASK_BACKEND env var (default: "sd" in Sprint 2)
  - If "br": construct BeadsRustClient(projectPath) and BvClient(projectPath)
  - If "sd": construct SeedsClient(projectPath) (existing behavior)
  - Pass client to Dispatcher
  - Verify br binary exists before proceeding (when backend=br)
  - [depends: TRD-005]

- [ ] **TRD-007-TEST**: Unit tests for run.ts client selection (1h) [verifies TRD-007]
  - Test FOREMAN_TASK_BACKEND=br instantiates BeadsRustClient
  - Test FOREMAN_TASK_BACKEND=sd instantiates SeedsClient
  - Test default (unset) instantiates SeedsClient
  - Test missing br binary exits with clear error message

- [ ] **TRD-008**: Update reset.ts to use BeadsRustClient (2h) [satisfies REQ-008]
  - Read FOREMAN_TASK_BACKEND env var
  - Replace seeds.update() with brClient.update() when backend=br
  - Replace seeds.show() with brClient.show() when backend=br
  - Update detectAndFixMismatches() to use ITaskClient
  - [depends: TRD-005]

- [ ] **TRD-008-TEST**: Unit tests for reset.ts with br backend (1h) [verifies TRD-008]
  - Test reset calls brClient.update() when FOREMAN_TASK_BACKEND=br
  - Test reset calls brClient.show() when FOREMAN_TASK_BACKEND=br
  - Test detectAndFixMismatches works with BeadsRustClient

- [ ] **TRD-009**: Update Monitor to use BeadsRustClient (2h) [satisfies REQ-009]
  - Change Monitor constructor to accept ITaskClient
  - Replace seeds.show() with taskClient.show() for completion detection
  - Handle "issue not found" error as transient during migration
  - [depends: TRD-005]

- [ ] **TRD-009-TEST**: Unit tests for Monitor with br backend (2h) [verifies TRD-009]
  - Test Monitor accepts BeadsRustClient via ITaskClient
  - Test checkAll() detects closed status from brClient.show()
  - Test "issue not found" handled gracefully (not marked as failed)
  - Test Monitor marks run as completed when status is closed

- [ ] **TRD-010**: Update agent-worker.ts finalize() (2h) [satisfies REQ-013]
  - Read FOREMAN_TASK_BACKEND env var
  - When backend=br: call ~/.local/bin/br close <seedId> --reason "Completed via pipeline"
  - When backend=sd: existing sd close behavior (backward compat)
  - [depends: TRD-005]

- [ ] **TRD-010-TEST**: Unit tests for finalize() with br backend (1h) [verifies TRD-010]
  - Test finalize calls br close when FOREMAN_TASK_BACKEND=br
  - Test finalize calls sd close when FOREMAN_TASK_BACKEND=sd
  - Test br close uses correct binary path (~/.local/bin/br)
  - Test br close passes --reason flag

- [ ] **TRD-011**: Update agent-worker.ts markStuck() (1h) [satisfies REQ-014]
  - Read FOREMAN_TASK_BACKEND env var
  - When backend=br: call ~/.local/bin/br update <seedId> --status open
  - When backend=sd: existing sd update behavior
  - [depends: TRD-005]

- [ ] **TRD-011-TEST**: Unit tests for markStuck() with br backend (1h) [verifies TRD-011]
  - Test markStuck calls br update when FOREMAN_TASK_BACKEND=br
  - Test markStuck uses correct binary path
  - Test markStuck sets status to open

- [ ] **TRD-012**: Update dispatcher inline prompts (1h) [satisfies REQ-016]
  - Update spawnAgent() prompt string: br close instead of sd close
  - Update resumeAgent() prompt string: br close instead of sd close
  - Conditional on FOREMAN_TASK_BACKEND during transition
  - [depends: TRD-005]

- [ ] **TRD-012-TEST**: Unit tests for dispatcher prompt content (1h) [verifies TRD-012]
  - Test spawnAgent prompt contains "br close" when backend=br
  - Test resumeAgent prompt contains "br close" when backend=br
  - Test no "sd close" in prompts when backend=br

- [x] **TRD-013**: Add FOREMAN_TASK_BACKEND feature flag infrastructure (2h)
  - Create src/lib/feature-flags.ts with getTaskBackend(): "sd" | "br" utility
  - Read from process.env.FOREMAN_TASK_BACKEND
  - Default: "sd" (Sprint 2), changed to "br" in Sprint 3
  - Single source of truth for all modules checking the flag

- [ ] **TRD-013-TEST**: Unit tests for feature flag (1h) [verifies TRD-013]
  - Test returns "sd" when env var unset
  - Test returns "br" when env var set to "br"
  - Test returns "sd" when env var set to "sd"
  - Test handles invalid values (defaults to "sd")

### Sprint 3 -- Phase 2+3: Templates and Init

- [ ] **TRD-014**: Update worker-agent.md template (1h) [satisfies REQ-015]
  - Replace sd update SEED_ID --claim with br update SEED_ID --status in_progress
  - Replace sd close SEED_ID --reason "Completed" with br close SEED_ID --reason "Completed"
  - Replace sd update SEED_ID --notes "Blocked: ..." with br update SEED_ID --description "Blocked: ..."
  - Remove all remaining sd references
  - [depends: TRD-010, TRD-011]

- [ ] **TRD-014-TEST**: Verify worker-agent.md contains no sd references (0.5h) [verifies TRD-014]
  - Test: grep for "sd " in templates/worker-agent.md returns zero matches
  - Test: "br update", "br close" present in template

- [ ] **TRD-015**: Update foreman seed command (2h) [satisfies REQ-017]
  - Replace SeedsClient with BeadsRustClient in src/cli/commands/seed.ts
  - Update create calls to use br field formats (numeric priority)
  - Use normalizePriority() for any user input
  - [depends: TRD-005, TRD-003]

- [ ] **TRD-015-TEST**: Unit tests for foreman seed with br (1h) [verifies TRD-015]
  - Test seed command creates issues via BeadsRustClient
  - Test priority input normalized correctly

- [ ] **TRD-016**: Update foreman plan command (2h) [satisfies REQ-018]
  - Replace SeedsClient with BeadsRustClient in src/cli/commands/plan.ts
  - Update issue creation to use br field formats
  - Update issue closing on completion
  - [depends: TRD-005]

- [ ] **TRD-016-TEST**: Unit tests for foreman plan with br (1h) [verifies TRD-016]
  - Test plan creates issues via BeadsRustClient
  - Test plan closes issues via BeadsRustClient

- [ ] **TRD-017**: Update foreman merge command (2h) [satisfies REQ-019]
  - Replace SeedsClient with BeadsRustClient in src/cli/commands/merge.ts
  - Update task status reads/writes to use br
  - [depends: TRD-005]

- [ ] **TRD-017-TEST**: Unit tests for foreman merge with br (1h) [verifies TRD-017]
  - Test merge uses BeadsRustClient for status reads
  - Test merge uses BeadsRustClient for status writes

- [ ] **TRD-018**: Update foreman init (2h) [satisfies REQ-011]
  - Check for br binary at ~/.local/bin/br instead of sd at ~/.bun/bin/sd
  - Run br init when .beads/ does not exist
  - Print installation instructions for br (cargo install beads_rust)
  - Optionally check for bv and print install instructions if absent
  - [depends: TRD-001]

- [ ] **TRD-018-TEST**: Unit tests for foreman init with br (1h) [verifies TRD-018]
  - Test init checks for ~/.local/bin/br
  - Test init runs br init when .beads/ absent
  - Test init prints install instructions when br missing

- [ ] **TRD-019**: Update foreman status (2h) [satisfies REQ-010]
  - Replace all execFileSync(sdPath, ...) with execFileSync(brPath, ...)
  - Binary path: ~/.local/bin/br instead of ~/.bun/bin/sd
  - Derive blocked count: br list --status=open minus br ready (no direct br blocked)
  - [depends: TRD-001]

- [ ] **TRD-019-TEST**: Unit tests for foreman status with br (1h) [verifies TRD-019]
  - Test status calls br CLI, not sd CLI
  - Test blocked count derived correctly
  - Test output format unchanged

- [ ] **TRD-020**: Update foreman doctor (2h) [satisfies REQ-012]
  - Check ~/.local/bin/br exists and is executable (required -- failure blocks)
  - Check ~/.local/bin/bv exists and is executable (warning only -- does not block)
  - Print cargo install beads_rust for missing br
  - Print cargo install beads_viewer for missing bv
  - Remove sd binary check
  - [depends: TRD-001]

- [ ] **TRD-020-TEST**: Unit tests for foreman doctor with br/bv (1h) [verifies TRD-020]
  - Test doctor passes when br exists
  - Test doctor fails when br missing
  - Test doctor warns (not fails) when bv missing
  - Test correct install instructions printed

- [ ] **TRD-021**: Deprecate --sd-only flag in sling (1h) [satisfies REQ-028]
  - --sd-only prints deprecation warning to stderr
  - --sd-only behaves as no-op (br-only write)
  - Flag retained for backward compatibility
  - [depends: TRD-005]

- [ ] **TRD-021-TEST**: Unit tests for sling --sd-only deprecation (0.5h) [verifies TRD-021]
  - Test --sd-only prints deprecation warning
  - Test --sd-only still writes to br (not sd)

- [ ] **TRD-022**: Make --br-only default behavior in sling (1h) [satisfies REQ-029]
  - When neither --sd-only nor --br-only specified: write to br only
  - --br-only flag retained but is now a no-op (already default)
  - [depends: TRD-021]

- [ ] **TRD-022-TEST**: Unit tests for sling default br behavior (0.5h) [verifies TRD-022]
  - Test default sling writes to br only
  - Test --br-only has same behavior as default

- [ ] **TRD-023**: Set FOREMAN_TASK_BACKEND=br as default (1h)
  - Update getTaskBackend() default from "sd" to "br"
  - Update any documentation referencing the default
  - [depends: TRD-013, TRD-018, TRD-019, TRD-020]

- [ ] **TRD-023-TEST**: Verify default backend is br (0.5h) [verifies TRD-023]
  - Test getTaskBackend() returns "br" when env var unset
  - Test foreman run uses BeadsRustClient by default

### Sprint 4 -- Phase 4: Cleanup

- [ ] **TRD-024**: Remove FOREMAN_TASK_BACKEND feature flag (2h)
  - Remove src/lib/feature-flags.ts or simplify to always return "br"
  - Remove all getTaskBackend() conditionals in run.ts, reset.ts, agent-worker.ts, etc.
  - Hardcode BeadsRustClient instantiation in all CLI commands
  - Remove SeedsClient construction from all CLI commands
  - [depends: TRD-023]

- [ ] **TRD-024-TEST**: Verify no feature flag references remain (1h) [verifies TRD-024]
  - Test: grep for "FOREMAN_TASK_BACKEND" in src/ returns zero matches
  - Test: grep for "getTaskBackend" in src/ returns zero matches (or only in feature-flags.ts if retained as constant)
  - Test all CLI commands work without env var set

- [ ] **TRD-025**: Archive/delete seeds.ts and deprecated aliases (2h)
  - Delete or move src/lib/seeds.ts to src/lib/seeds.deprecated.ts
  - Remove deprecated BeadsClient, Bead, BeadDetail, BeadGraph aliases
  - Remove execSd function
  - Update any remaining imports
  - [depends: TRD-024]

- [ ] **TRD-025-TEST**: Verify no seeds.ts imports remain (0.5h) [verifies TRD-025]
  - Test: grep for "SeedsClient" in src/ returns zero matches (except archived files)
  - Test: grep for "execSd" in src/ returns zero matches
  - Test: grep for "~/.bun/bin/sd" in src/ returns zero matches

- [ ] **TRD-026**: Delete/archive pagerank.ts (1h)
  - Delete or archive src/orchestrator/pagerank.ts
  - Remove calculateImpactScores and priorityBoost exports
  - Verify no remaining imports
  - [depends: TRD-006, TRD-024]

- [ ] **TRD-026-TEST**: Verify no pagerank.ts imports remain (0.5h) [verifies TRD-026]
  - Test: grep for "pagerank" in src/ returns zero matches (except archived)
  - Test: grep for "calculateImpactScores" in src/ returns zero matches

- [ ] **TRD-027**: Update all test mocks to BeadsRustClient (3h)
  - Replace all SeedsClient mocks in test files with BeadsRustClient mocks
  - Update mock return types to match BrIssue / BrIssueDetail
  - Ensure all tests pass with br-only mocks
  - [depends: TRD-024, TRD-025]

- [ ] **TRD-027-TEST**: Verify test suite passes with br-only mocks (1h) [verifies TRD-027]
  - Test: npm test passes with zero failures
  - Test: no SeedsClient mock references in test files

- [ ] **TRD-028**: Final documentation pass (2h)
  - Update CLAUDE.md: replace all sd references with br/bv
  - Update any README or docs referencing seeds commands
  - Verify foreman --help output references br not sd
  - Write migration guide summary in docs/
  - [depends: TRD-024, TRD-025, TRD-026]

- [ ] **TRD-028-TEST**: Verify documentation accuracy (1h) [verifies TRD-028]
  - Test: grep for " sd " in CLAUDE.md returns only historical/comparison references
  - Test: grep for "seeds" in CLAUDE.md returns only historical references
  - Review foreman --help output

---

## 6. Sprint Planning

### Sprint 1 -- Phase 0: Foundation (1 week, ~19h estimated)

**Goal:** Ship additive-only code that does not break existing functionality.

| Task ID | Description | Est. | Dependencies | Status |
|---------|-------------|------|--------------|--------|
| TRD-001 | Add ready() to BeadsRustClient | 2h | none | [ ] |
| TRD-001-TEST | Tests for ready() | 1h | TRD-001 | [ ] |
| TRD-002 | Create BvClient in src/lib/bv.ts | 4h | none | [ ] |
| TRD-002-TEST | Tests for BvClient | 3h | TRD-002 | [ ] |
| TRD-003 | Create priority.ts with normalizePriority() | 1h | none | [ ] |
| TRD-003-TEST | Tests for normalizePriority() | 1h | TRD-003 | [ ] |
| TRD-004 | Implement foreman migrate-seeds command | 4h | TRD-003 | [ ] |
| TRD-004-TEST | Tests for migrate-seeds | 3h | TRD-004 | [ ] |

**Exit Criteria:**
- npm test passes
- npx tsc --noEmit passes
- foreman migrate-seeds --dry-run works against existing .seeds/ data
- No existing code paths modified

### Sprint 2 -- Phase 1: Runtime Core (1 week, ~32h estimated)

**Goal:** Feature-flagged br backend for dispatcher, monitor, agent-worker, and core CLI commands.

| Task ID | Description | Est. | Dependencies | Status |
|---------|-------------|------|--------------|--------|
| TRD-013 | Feature flag infrastructure | 2h | none | [ ] |
| TRD-013-TEST | Tests for feature flag | 1h | TRD-013 | [ ] |
| TRD-005 | Update Dispatcher for ITaskClient | 4h | TRD-001, TRD-003 | [ ] |
| TRD-005-TEST | Tests for Dispatcher with ITaskClient | 3h | TRD-005 | [ ] |
| TRD-006 | Wire BvClient into dispatcher ordering | 3h | TRD-002, TRD-005 | [ ] |
| TRD-006-TEST | Tests for bv-ordered dispatch | 3h | TRD-006 | [ ] |
| TRD-007 | Update run.ts for BeadsRustClient | 2h | TRD-005 | [ ] |
| TRD-007-TEST | Tests for run.ts client selection | 1h | TRD-007 | [ ] |
| TRD-008 | Update reset.ts for BeadsRustClient | 2h | TRD-005 | [ ] |
| TRD-008-TEST | Tests for reset.ts with br | 1h | TRD-008 | [ ] |
| TRD-009 | Update Monitor for BeadsRustClient | 2h | TRD-005 | [ ] |
| TRD-009-TEST | Tests for Monitor with br | 2h | TRD-009 | [ ] |
| TRD-010 | Update agent-worker finalize() | 2h | TRD-005 | [ ] |
| TRD-010-TEST | Tests for finalize() with br | 1h | TRD-010 | [ ] |
| TRD-011 | Update agent-worker markStuck() | 1h | TRD-005 | [ ] |
| TRD-011-TEST | Tests for markStuck() with br | 1h | TRD-011 | [ ] |
| TRD-012 | Update dispatcher inline prompts | 1h | TRD-005 | [ ] |
| TRD-012-TEST | Tests for dispatcher prompts | 1h | TRD-012 | [ ] |

**Exit Criteria:**
- FOREMAN_TASK_BACKEND=br foreman run dispatches tasks using br + bv ordering
- FOREMAN_TASK_BACKEND=sd foreman run still works (no regression)
- npm test passes
- npx tsc --noEmit passes

### Sprint 3 -- Phase 2+3: Templates and Init (1 week, ~22h estimated)

**Goal:** Update all agent-facing content and project setup commands. Set br as default backend.

| Task ID | Description | Est. | Dependencies | Status |
|---------|-------------|------|--------------|--------|
| TRD-014 | Update worker-agent.md template | 1h | TRD-010, TRD-011 | [ ] |
| TRD-014-TEST | Verify no sd in template | 0.5h | TRD-014 | [ ] |
| TRD-015 | Update foreman seed command | 2h | TRD-005, TRD-003 | [ ] |
| TRD-015-TEST | Tests for foreman seed with br | 1h | TRD-015 | [ ] |
| TRD-016 | Update foreman plan command | 2h | TRD-005 | [ ] |
| TRD-016-TEST | Tests for foreman plan with br | 1h | TRD-016 | [ ] |
| TRD-017 | Update foreman merge command | 2h | TRD-005 | [ ] |
| TRD-017-TEST | Tests for foreman merge with br | 1h | TRD-017 | [ ] |
| TRD-018 | Update foreman init | 2h | TRD-001 | [ ] |
| TRD-018-TEST | Tests for foreman init with br | 1h | TRD-018 | [ ] |
| TRD-019 | Update foreman status | 2h | TRD-001 | [ ] |
| TRD-019-TEST | Tests for foreman status with br | 1h | TRD-019 | [ ] |
| TRD-020 | Update foreman doctor | 2h | TRD-001 | [ ] |
| TRD-020-TEST | Tests for foreman doctor with br/bv | 1h | TRD-020 | [ ] |
| TRD-021 | Deprecate --sd-only in sling | 1h | TRD-005 | [ ] |
| TRD-021-TEST | Tests for sling deprecation | 0.5h | TRD-021 | [ ] |
| TRD-022 | Make --br-only default in sling | 1h | TRD-021 | [ ] |
| TRD-022-TEST | Tests for sling default behavior | 0.5h | TRD-022 | [ ] |
| TRD-023 | Set FOREMAN_TASK_BACKEND=br default | 1h | TRD-013, TRD-018-020 | [ ] |
| TRD-023-TEST | Verify default backend is br | 0.5h | TRD-023 | [ ] |

**Exit Criteria:**
- All CLI commands work end-to-end without sd
- foreman doctor passes on a fresh br-initialized project
- foreman init creates .beads/ directory
- Worker template references br commands only
- npm test passes
- npx tsc --noEmit passes

### Sprint 4 -- Phase 4: Cleanup (1 week, ~14h estimated)

**Goal:** Remove all seeds/sd infrastructure, feature flags, and deprecated code.

| Task ID | Description | Est. | Dependencies | Status |
|---------|-------------|------|--------------|--------|
| TRD-024 | Remove feature flag | 2h | TRD-023 | [ ] |
| TRD-024-TEST | Verify no flag references | 1h | TRD-024 | [ ] |
| TRD-025 | Archive/delete seeds.ts | 2h | TRD-024 | [ ] |
| TRD-025-TEST | Verify no seeds imports | 0.5h | TRD-025 | [ ] |
| TRD-026 | Delete/archive pagerank.ts | 1h | TRD-006, TRD-024 | [ ] |
| TRD-026-TEST | Verify no pagerank imports | 0.5h | TRD-026 | [ ] |
| TRD-027 | Update all test mocks to br | 3h | TRD-024, TRD-025 | [ ] |
| TRD-027-TEST | Verify test suite passes | 1h | TRD-027 | [ ] |
| TRD-028 | Final documentation pass | 2h | TRD-024-026 | [ ] |
| TRD-028-TEST | Verify documentation accuracy | 1h | TRD-028 | [ ] |

**Exit Criteria:**
- grep -r "SeedsClient|execSd|~/.bun/bin/sd" src/ returns zero results
- grep -r "pagerank|calculateImpactScores" src/ returns zero results
- grep -r "FOREMAN_TASK_BACKEND" src/ returns zero results
- npm test passes
- npx tsc --noEmit passes
- All documentation updated

---

## 7. Acceptance Criteria Traceability Matrix

| PRD Requirement | Description | Implementation Tasks | Test Tasks |
|-----------------|-------------|---------------------|------------|
| REQ-001 | Replace SeedsClient in dispatcher with BeadsRustClient | TRD-005 | TRD-005-TEST |
| REQ-002 | Add ready() to BeadsRustClient | TRD-001 | TRD-001-TEST |
| REQ-003 | Create BvClient in src/lib/bv.ts | TRD-002 | TRD-002-TEST |
| REQ-004 | BvClient robotNext() and robotTriage() | TRD-002 | TRD-002-TEST |
| REQ-005 | Dispatcher always uses bv ordering | TRD-006 | TRD-006-TEST |
| REQ-006 | Remove pagerank.ts dependency from dispatcher | TRD-006, TRD-026 | TRD-006-TEST, TRD-026-TEST |
| REQ-007 | Update foreman run for BeadsRustClient | TRD-007 | TRD-007-TEST |
| REQ-008 | Update foreman reset for BeadsRustClient | TRD-008 | TRD-008-TEST |
| REQ-009 | Update foreman monitor for BeadsRustClient | TRD-009 | TRD-009-TEST |
| REQ-010 | Update foreman status to query br | TRD-019 | TRD-019-TEST |
| REQ-011 | Update foreman init to initialize br | TRD-018 | TRD-018-TEST |
| REQ-012 | Update foreman doctor for br and bv | TRD-020 | TRD-020-TEST |
| REQ-013 | Update agent worker finalize() for br | TRD-010 | TRD-010-TEST |
| REQ-014 | Update agent worker markStuck() for br | TRD-011 | TRD-011-TEST |
| REQ-015 | Update worker prompt templates for br | TRD-014 | TRD-014-TEST |
| REQ-016 | Update dispatcher inline prompts for br | TRD-012 | TRD-012-TEST |
| REQ-017 | Update foreman seed for br | TRD-015 | TRD-015-TEST |
| REQ-018 | Update foreman plan for br | TRD-016 | TRD-016-TEST |
| REQ-019 | Update foreman merge for br | TRD-017 | TRD-017-TEST |
| REQ-020 | Priority normalization adapter | TRD-003 | TRD-003-TEST |
| REQ-021 | Implement foreman migrate-seeds | TRD-004 | TRD-004-TEST |
| REQ-022 | Migration preserves dependency graph | TRD-004 | TRD-004-TEST |
| REQ-023 | Migration handles in_progress seeds | TRD-004 | TRD-004-TEST |
| REQ-024 | BvClient never calls bare bv | TRD-002 | TRD-002-TEST |
| REQ-025 | BvClient always syncs before bv | TRD-002 | TRD-002-TEST |
| REQ-026 | BvClient configurable timeout | TRD-002 | TRD-002-TEST |
| REQ-027 | bv unavailability does not block dispatch | TRD-002, TRD-006 | TRD-002-TEST, TRD-006-TEST |
| REQ-028 | Deprecate --sd-only in sling | TRD-021 | TRD-021-TEST |
| REQ-029 | --br-only becomes sling default | TRD-022 | TRD-022-TEST |
| REQ-NF-001 | Binary availability check on startup | TRD-NF-001 | TRD-NF-001-TEST |
| REQ-NF-002 | Worker binary PATH configuration | TRD-NF-002 | TRD-NF-002-TEST |
| REQ-NF-003 | No increase in dispatch latency | TRD-NF-003 | TRD-NF-003-TEST |
| REQ-NF-004 | Backwards compatibility for in-flight runs | TRD-NF-004 | TRD-NF-004-TEST |
| REQ-NF-005 | Test coverage targets | TRD-NF-005 | TRD-NF-005-TEST |
| REQ-NF-006 | TypeScript strict mode compliance | TRD-NF-006 | TRD-NF-006-TEST |
| REQ-NF-007 | ESM import compliance | TRD-NF-007 | TRD-NF-007-TEST |

### PRD Acceptance Criteria to TRD Task Mapping

| AC | Description | Verified By |
|----|-------------|-------------|
| AC-001 | Dispatcher uses br for task discovery | TRD-005-TEST, TRD-006-TEST |
| AC-002 | bv ordering is always active | TRD-006-TEST |
| AC-003 | bv unavailability triggers fallback | TRD-002-TEST, TRD-006-TEST |
| AC-004 | Agent worker uses br for task closure | TRD-010-TEST |
| AC-005 | Agent worker uses br for stuck recovery | TRD-011-TEST |
| AC-006 | TASK.md instructs agent to use br | TRD-014-TEST |
| AC-007 | foreman init initializes br | TRD-018-TEST |
| AC-008 | foreman status displays br counts | TRD-019-TEST |
| AC-009 | foreman migrate-seeds is idempotent | TRD-004-TEST |
| AC-010 | migrate-seeds preserves dependency graph | TRD-004-TEST |
| AC-011 | br binary on PATH in worker env | TRD-NF-002-TEST |
| AC-012 | Monitor detects br task completion | TRD-009-TEST |
| AC-013 | foreman reset resets br task status | TRD-008-TEST |
| AC-014 | BvClient enforces sync before triage | TRD-002-TEST |
| AC-015 | BvClient times out gracefully | TRD-002-TEST |
| AC-016 | TypeScript compiles without errors | TRD-NF-006-TEST |
| AC-017 | Existing tests pass | TRD-027-TEST, TRD-NF-005-TEST |
| AC-018 | foreman doctor reports bv status | TRD-020-TEST |

---

## 8. Team Configuration

```yaml
team:
  lead:
    agent: tech-lead-orchestrator
    owns:
      - task-selection
      - architecture-review
      - final-approval
      - sprint-planning
      - quality-gate-orchestration
    responsibilities:
      - Review all PRs before merge
      - Validate TDD compliance (Red-Green-Refactor)
      - Ensure ITaskClient interface design is correct
      - Approve feature flag transitions (sd default -> br default -> flag removal)

  builders:
    - agent: backend-developer
      owns:
        - implementation
      domains:
        - core-library (beads-rust.ts, bv.ts, priority.ts, feature-flags.ts, task-client.ts)
        - orchestrator (dispatcher.ts, agent-worker.ts, monitor.ts)
        - cli-commands (run.ts, reset.ts, status.ts, init.ts, doctor.ts, seed.ts, plan.ts, merge.ts, sling.ts, migrate-seeds.ts)
        - templates (worker-agent.md)
      sprint-assignments:
        sprint-1: [TRD-001, TRD-002, TRD-003, TRD-004]
        sprint-2: [TRD-005, TRD-006, TRD-007, TRD-008, TRD-009, TRD-010, TRD-011, TRD-012, TRD-013]
        sprint-3: [TRD-014, TRD-015, TRD-016, TRD-017, TRD-018, TRD-019, TRD-020, TRD-021, TRD-022, TRD-023]
        sprint-4: [TRD-024, TRD-025, TRD-026, TRD-027, TRD-028]

  reviewer:
    agent: code-reviewer
    owns:
      - code-review
    responsibilities:
      - Review all implementation PRs for quality, security, and TDD compliance
      - Verify ITaskClient interface adherence
      - Check for bare bv invocations (compile-time and runtime)
      - Validate ESM import conventions (.js extensions)
      - Verify TypeScript strict mode (no any escape hatches)
      - Check that br sync --flush-only precedes all bv calls

  qa:
    agent: test-runner
    owns:
      - quality-gate
      - acceptance-criteria
    responsibilities:
      - Execute all TRD-NNN-TEST tasks
      - Verify unit test coverage >= 80%
      - Verify integration test coverage >= 70%
      - Run npx tsc --noEmit after each sprint
      - Validate AC-001 through AC-018
      - Run regression suite after each sprint
```

### Delegation Strategy

| Task Category | Primary Agent | Rationale |
|---------------|--------------|-----------|
| Core library (bv.ts, priority.ts, task-client.ts) | backend-developer | New TypeScript modules, clean-room implementation |
| Orchestrator updates (dispatcher.ts, agent-worker.ts) | backend-developer | Existing module modification, requires domain knowledge |
| CLI command updates | backend-developer | Straightforward client swaps, repetitive pattern |
| Template updates (worker-agent.md) | backend-developer | Text replacement, low complexity |
| Test suite updates | test-runner | Responsible for mock updates and coverage validation |
| Documentation | backend-developer | CLAUDE.md and docs/ updates |
| Feature flag removal and cleanup | backend-developer | Code deletion with verification |

---

## 9. Risk Register

| Risk ID | Description | Probability | Impact | Mitigation | Related Tasks |
|---------|-------------|-------------|--------|------------|---------------|
| RISK-001 | bv TUI blocking agent processes | Low | Critical | BvClient type-level enforcement of --robot-* flags | TRD-002 |
| RISK-002 | Stale bv data from missing sync | Medium | High | BvClient always calls br sync before bv | TRD-002 |
| RISK-003 | br binary unavailable in worktrees | Medium | High | buildWorkerEnv() prepends ~/.local/bin to PATH | TRD-005 |
| RISK-004 | Priority format mismatch | High | Medium | normalizePriority() adapter | TRD-003 |
| RISK-005 | In-flight runs during cutover | Medium | Medium | Run foreman reset before migration; Monitor handles "not found" gracefully | TRD-009 |
| RISK-006 | Missing notes field in br | Low | Low | Map notes to description with prefix | TRD-014 |
| RISK-007 | bv not installed by operators | Medium | Low | Transparent fallback to priority-sort; doctor warns | TRD-002, TRD-020 |
| RISK-008 | SeedGraph type consumers break | Low | Low | Only dispatcher uses graph; replaced by bv | TRD-006, TRD-026 |
| RISK-009 | Feature flag not removed timely | Low | Low | Sprint 4 explicitly dedicated to cleanup | TRD-024 |

---

## 10. Definition of Done

A task is considered complete (checkbox: [x]) when ALL of the following are satisfied:

### Per-Task DoD

1. **Implementation complete**: Code written and compiles (npx tsc --noEmit passes)
2. **TDD followed**: Test written first (RED), minimal implementation (GREEN), refactored (REFACTOR)
3. **Paired test task passes**: The corresponding TRD-NNN-TEST task's test cases all pass
4. **No regressions**: npm test passes with all existing tests
5. **ESM compliant**: All new imports use .js extensions
6. **TypeScript strict**: No any escape hatches
7. **Code reviewed**: Approved by code-reviewer agent

### Per-Sprint DoD

1. All sprint tasks have checkbox [x]
2. npm test passes
3. npx tsc --noEmit passes
4. Unit test coverage >= 80% for new/modified files
5. Integration test coverage >= 70% for affected paths
6. Sprint exit criteria (defined in Section 6) satisfied
7. PR created and merged to feature branch

### Project DoD (after Sprint 4)

1. All 28 implementation tasks and 28 test tasks completed
2. grep -r "SeedsClient|execSd|~/.bun/bin/sd" src/ returns zero results
3. grep -r "FOREMAN_TASK_BACKEND" src/ returns zero results
4. All 18 PRD Acceptance Criteria (AC-001 through AC-018) validated
5. All 7 non-functional requirements (REQ-NF-001 through REQ-NF-007) satisfied
6. CLAUDE.md updated with br/bv references
7. Migration guide documented

---

## Appendix A: Total Effort Summary

| Sprint | Implementation Hours | Test Hours | Total Hours |
|--------|---------------------|------------|-------------|
| Sprint 1 (Foundation) | 11h | 8h | 19h |
| Sprint 2 (Runtime Core) | 21h | 15h | 36h |
| Sprint 3 (Templates/Init) | 18h | 10h | 28h |
| Sprint 4 (Cleanup) | 10h | 5h | 15h |
| Non-Functional Tasks | 8h | 6h | 14h |
| **Total** | **68h** | **44h** | **112h** |

## Appendix B: File Change Inventory

| File | Change | Sprint | Tasks |
|------|--------|--------|-------|
| src/lib/beads-rust.ts | Extend (add ready()) | 1 | TRD-001 |
| src/lib/bv.ts | Create (BvClient) | 1 | TRD-002 |
| src/lib/priority.ts | Create (normalizePriority) | 1 | TRD-003 |
| src/lib/task-client.ts | Create (ITaskClient interface) | 2 | TRD-005 |
| src/lib/feature-flags.ts | Create then remove | 2, 4 | TRD-013, TRD-024 |
| src/cli/commands/migrate-seeds.ts | Create | 1 | TRD-004 |
| src/orchestrator/dispatcher.ts | Replace SeedsClient, add bv ordering, update PATH | 2 | TRD-005, TRD-006, TRD-012 |
| src/orchestrator/agent-worker.ts | Replace sd binary paths | 2 | TRD-010, TRD-011 |
| src/orchestrator/monitor.ts | Replace SeedsClient | 2 | TRD-009 |
| src/cli/commands/run.ts | Replace SeedsClient instantiation | 2 | TRD-007 |
| src/cli/commands/reset.ts | Replace SeedsClient | 2 | TRD-008 |
| templates/worker-agent.md | Replace sd commands with br | 3 | TRD-014 |
| src/cli/commands/seed.ts | Replace SeedsClient | 3 | TRD-015 |
| src/cli/commands/plan.ts | Replace SeedsClient | 3 | TRD-016 |
| src/cli/commands/merge.ts | Replace SeedsClient | 3 | TRD-017 |
| src/cli/commands/init.ts | Replace sd init with br init | 3 | TRD-018 |
| src/cli/commands/status.ts | Replace sd CLI calls | 3 | TRD-019 |
| src/cli/commands/doctor.ts | Replace sd check, add bv check | 3 | TRD-020 |
| src/cli/commands/sling.ts | Deprecate --sd-only, default --br-only | 3 | TRD-021, TRD-022 |
| src/orchestrator/pagerank.ts | Delete or archive | 4 | TRD-026 |
| src/lib/seeds.ts | Archive or delete | 4 | TRD-025 |
| CLAUDE.md | Update sd to br references | 4 | TRD-028 |
