# TRD-2026-009: Agent Guardrails and Observability

| Field | Value |
|---|---|
| Document ID | TRD-2026-009 |
| PRD Reference | PRD-2026-009 |
| Version | 1.0 |
| Status | Draft |
| Date | 2026-04-19 |
| Design Readiness Score | 4.5 |

---

## Architecture Decision

### Approach: Extend Existing Abstractions + New Modules

The implementation adds guardrails and observability via three new modules, new config fields, and targeted modifications to existing components. No new services or processes are required.

**Key architectural decisions:**

1. **`isAncestor` already exists in GitBackend** (via `merge-base --is-ancestor`). The PRD FR-5 section incorrectly stated it was missing. No interface update needed.
2. **New event types are string literals** — `store.logEvent()` accepts any `EventType`, and the SQLite schema (`details TEXT`) stores arbitrary JSON. No store migration required for new event types.
3. **Guardrail integration via Pi SDK tool hooks** — The Pi SDK accepts a `tools` array with factory functions that can wrap tool execution. We inject directory-verification logic before each tool call.
4. **Phase tracking via `PhaseRecord[]` accumulation** — The existing `PhaseRecord` interface in `session-log.ts` is extended to capture the full activity data needed for `ACTIVITY_LOG.json`.
5. **VCS-backend-agnostic stale detection** — Uses only `getHeadId`, `fetch`, `resolveRef`, and `rebase` — all existing methods on `VcsBackend`.

**Alternatives considered:**
- **WebSocket live view**: PRD explicitly excludes real-time streaming UI. Heartbeat events are written to SQLite for polling-based dashboards.
- **Agent self-correction**: Guardrail enforces constraints but does not direct agent behavior. The agent receives directory corrections but decides what to do with them.
- **Pre-tool hook as a custom Pi SDK tool**: More complex to register and invoke. Tool-factories are the correct integration point.

---

## Master Task List

### Sprint 1: Configuration + VCS Foundation

#### TRD-009-001: Add guardrail + observability config to ProjectConfig [2h]
[satisfies FR-1 config, FR-3 config]

**Validates PRD ACs:** (config layer — no direct AC validation)

Add guardrails and observability sections to `ProjectConfig` in `src/lib/project-config.ts`. Extend the interface, validation, and schema.

**Config shape:**
```typescript
export interface ProjectConfig {
  // ... existing fields
  guardrails?: {
    directory?: {
      mode?: "auto-correct" | "veto" | "disabled";
      allowedPaths?: string[];
    };
  };
  observability?: {
    heartbeat?: {
      enabled?: boolean;
      intervalSeconds?: number;
    };
    activityLog?: {
      enabled?: boolean;
      includeGitDiffStat?: boolean;
    };
  };
  staleWorktree?: {
    autoRebase?: boolean;
    failOnConflict?: boolean;
  };
}
```

**Implementation ACs:**
- Given a `.foreman/config.yaml` with `guardrails.directory.mode: veto`, when `loadProjectConfig()` is called, then the returned config includes `guardrails.directory.mode === "veto"`.
- Given a config with `observability.heartbeat.intervalSeconds: 30`, when parsed, then the value is 30 seconds.
- Given a config with unknown guardrail keys, when parsed, then unknown keys are silently ignored (forward-compatible).
- Given no guardrails or observability section, when parsed, then all fields default to sensible values (auto-correct, enabled: true, 60s interval).

[depends: none]

---

#### TRD-009-001-TEST: Test project config guardrail/observability parsing [2h]
[verifies TRD-009-001]

Write vitest tests:
- `guardrails.directory.mode: auto-correct / veto / disabled` — all accepted
- `guardrails.directory.mode: invalid` — throws ProjectConfigError
- `observability.heartbeat.enabled: false` — parsed as false
- `observability.heartbeat.intervalSeconds: 0` — disables heartbeat
- `staleWorktree.autoRebase: true` — parsed as true
- Missing section — all fields default to sensible values
- Unknown keys — silently ignored

---

#### TRD-009-002: Verify VcsBackend isAncestor coverage [1h]
[satisfies FR-5: stale worktree detection]

**Validates PRD ACs:** AC-5 (stale worktree auto-rebase)

Verify `isAncestor()` exists in both backends and works correctly. The GitBackend already has it (line 419+). Verify JujutsuBackend implementation is correct.

**Implementation ACs:**
- Given a GitBackend at commit `abc` that is an ancestor of `def`, when `isAncestor(path, "abc", "def")` is called, then it returns `true`.
- Given a JujutsuBackend, when `isAncestor()` is called with an ancestor-descendant pair, then it returns `true`.
- Given a JujutsuBackend, when `isAncestor()` is called with a non-ancestor relationship, then it returns `false`.

[depends: none]

---

### Sprint 2: Guardrails Module (FR-1)

#### TRD-009-003: Create guardrails module [4h]
[satisfies FR-1]

**Validates PRD ACs:** AC-1

Create `src/orchestrator/guardrails.ts` with the directory verification guardrail.

**Interface:**
```typescript
export type DirectoryGuardrailMode = "auto-correct" | "veto" | "disabled";

export interface GuardrailConfig {
  directory?: {
    mode?: DirectoryGuardrailMode;
    allowedPaths?: string[];
  };
  expectedCwd: string;
}

/**
 * Create a pre-tool hook for directory verification.
 * Returns a function that wraps tool calls with cwd validation.
 *
 * @param config - Guardrail configuration (expectedCwd required)
 * @param logEvent - Event logging function (writes to store)
 * @param projectId - Foreman project ID
 * @param runId - Current run ID
 * @returns A pre-tool hook function compatible with Pi SDK
 */
export function createDirectoryGuardrail(
  config: GuardrailConfig,
  logEvent: (eventType: string, details: Record<string, unknown>) => void,
  projectId: string,
  runId: string,
): (toolName: string, args: Record<string, unknown>, currentCwd: string) => {
    allowed: boolean;
    correctedArgs?: Record<string, unknown>;
    correctedCwd?: string;
  };
```

**Behavior:**
- **auto-correct mode**: If `currentCwd !== expectedCwd`, prepend `cd ${expectedCwd} &&` to bash commands, fix edit/write file paths. Log `guardrail-corrected` event.
- **veto mode**: If `currentCwd !== expectedCwd`, return `allowed: false`. Log `guardrail-veto` event with tool name, expected cwd, actual cwd, and ISO timestamp.
- **disabled mode**: Return `allowed: true` immediately — no checks.

**Path correction for edit/write:**
- If `args.path` starts with the wrong worktree prefix, replace it with the correct one.
- Handle relative paths by prepending the correct worktree path.

**Implementation ACs:**
- Given `createDirectoryGuardrail({ expectedCwd: "/worktrees/proj/seed-abc" }, ...)` with mode `"veto"`, when the agent's `pwd` is `/wrong/path` and the agent runs `edit`, then the hook returns `{ allowed: false }` and logs a `guardrail-veto` event.
- Given the same config with mode `"auto-correct"`, when the agent runs `Bash` with args `{ command: "npm test" }`, then the hook returns `{ allowed: true, correctedArgs: { command: "cd /worktrees/proj/seed-abc && npm test" } }`.
- Given mode `"disabled"`, when the hook is called, then it returns `{ allowed: true }` immediately without any checks.
- Guardrail overhead per tool call: <5ms (measured via `performance.now()`).

[depends: TRD-009-001]

---

#### TRD-009-003-TEST: Test directory guardrail [3h]
[verifies TRD-009-003]

Write vitest tests for `src/orchestrator/__tests__/guardrails.test.ts`:

- **Veto mode — wrong cwd**: Returns `allowed: false`, logs `guardrail-veto`
- **Veto mode — correct cwd**: Returns `allowed: true`
- **Auto-correct mode — Bash tool**: Corrects command to `cd expected && cmd`
- **Auto-correct mode — Edit tool**: Corrects file path to expected worktree
- **Auto-correct mode — Write tool**: Corrects file path to expected worktree
- **Disabled mode**: Always returns `allowed: true`, no logging
- **Path correction edge cases**: Relative paths, paths with `..`, already-correct paths
- **Performance**: Overhead <5ms per call (assert with `performance.now()` delta)

---

#### TRD-009-004: Integrate guardrail into Pi SDK Runner [3h]
[satisfies FR-1 integration]

**Validates PRD ACs:** AC-1 (end-to-end)

Modify `src/orchestrator/pi-sdk-runner.ts` to accept `guardrailConfig` and register a pre-tool hook with the Pi SDK session.

**Changes to PiRunOptions:**
```typescript
export interface PiRunOptions {
  // ... existing fields
  guardrailConfig?: GuardrailConfig;
}
```

**Changes to `buildTools()`:**
For each tool factory call, wrap the resulting tool with the guardrail hook. The wrapper intercepts tool calls, runs directory verification, and either corrects arguments or throws a structured error before the tool executes.

**Implementation ACs:**
- Given `PiRunOptions` with `guardrailConfig: { directory: { mode: "veto" }, expectedCwd: "/worktrees/proj/seed-abc" }`, when the agent runs a tool from the wrong directory, then the guardrail intercepts it and the tool call is not executed.
- Given `PiRunOptions` without `guardrailConfig`, when tools are built, then no guardrail is active.
- Given the Pi SDK session is created with guardrail, when `session.prompt()` is called, then the guardrail hook is active for all tool calls.

[depends: TRD-009-003]

---

#### TRD-009-004-TEST: Test guardrail integration in Pi SDK Runner [2h]
[verifies TRD-009-004]

Write vitest tests:
- `runWithPiSdk()` with `guardrailConfig` — guardrail active for tool calls
- `runWithPiSdk()` without `guardrailConfig` — no guardrail overhead
- Guardrail correction propagates to tool execution correctly

---

### Sprint 3: Observability — Phase Events + Heartbeat (FR-2, FR-3)

#### TRD-009-005: Add phase-start event logging [2h]
[satisfies FR-2]

**Validates PRD ACs:** AC-2

In `src/orchestrator/pipeline-executor.ts`, before each `runPhase()` call, write a `phase-start` event to the store.

**Event schema:**
```typescript
interface PhaseStartEvent {
  event_type: "phase-start";
  seedId: string;
  phase: string;
  worktreePath: string;
  model: string;
  runId: string;
  targetBranch: string;
  timestamp: string; // ISO 8601
}
```

**Implementation ACs:**
- Given a pipeline with phases `fix → test → finalize`, when the `test` phase starts, then `store.logEvent()` is called with `eventType: "phase-start"` before `runPhase()` is invoked.
- Given a `phase-start` event, when the events table is queried, then all required fields (seedId, phase, worktreePath, model, runId, targetBranch) are present.

[depends: none — can be implemented in parallel with TRD-009-003]

---

#### TRD-009-005-TEST: Test phase-start event [1h]
[verifies TRD-009-005]

Write vitest tests:
- Phase-start event written before each non-skipped phase
- Phase-start event not written for skipped phases
- All required fields present in event details

---

#### TRD-009-006: Create heartbeat interval manager [4h]
[satisfies FR-3]

**Validates PRD ACs:** AC-3

Create `src/orchestrator/heartbeat-manager.ts` with a heartbeat interval manager class.

**Interface:**
```typescript
export interface HeartbeatConfig {
  enabled: boolean;
  intervalSeconds: number; // default: 60
}

export interface HeartbeatData {
  seedId: string;
  phase: string;
  turns: number;
  toolCalls: number;
  toolBreakdown: Record<string, number>;
  filesChanged: string[];
  costUsd: number;
  tokensIn: number;
  tokensOut: number;
  lastFileEdited: string | null;
  lastActivity: string; // ISO 8601
}

export class HeartbeatManager {
  constructor(
    config: HeartbeatConfig,
    store: ForemanStore,
    projectId: string,
    runId: string,
    vcsBackend: VcsBackend,
    worktreePath: string,
  );

  /** Start the heartbeat interval. Call when a phase begins. */
  start(currentPhase: string): void;

  /** Update heartbeat data from the current session stats. */
  update(stats: {
    turns: number;
    toolCalls: number;
    toolBreakdown: Record<string, number>;
    costUsd: number;
    tokensIn: number;
    tokensOut: number;
    lastFileEdited?: string | null;
  }): void;

  /** Stop the heartbeat interval. Call when a phase ends. */
  stop(): void;

  /** Check if heartbeat should fire now (exposed for testing). */
  shouldFire(): boolean;
}
```

**Heartbeat event schema** (written via `store.logEvent()`):
```typescript
interface HeartbeatEvent {
  event_type: "heartbeat";
  seedId: string;
  phase: string;
  turns: number;
  toolCalls: number;
  toolBreakdown: Record<string, number>;
  filesChanged: string[];
  costUsd: number;
  tokensIn: number;
  tokensOut: number;
  lastFileEdited: string | null;
  lastActivity: string;
  runId: string;
}
```

**Files changed tracking**: Use `vcs.getHeadId()` + `vcs.getChangedFiles()` to compute files changed since phase start.

**Fail-safe**: If `store.logEvent()` throws, catch the error and log to console — must not kill the agent session. Log a warning with the error message.

**Implementation ACs:**
- Given a `HeartbeatManager` with `intervalSeconds: 60`, when started and 65 seconds elapse, then a `heartbeat` event is written to the store.
- Given a `HeartbeatManager` with `enabled: false`, when started, then no heartbeat fires.
- Given a `HeartbeatManager` where `store.logEvent()` throws, when the heartbeat fires, then the error is logged and the manager continues — the session is not killed.
- Given files changed in the worktree, when a heartbeat fires, then `filesChanged` contains the modified file paths.

[depends: TRD-009-002]

---

#### TRD-009-006-TEST: Test heartbeat manager [3h]
[verifies TRD-009-006]

Write vitest tests:
- Heartbeat fires at configured interval
- Heartbeat does not fire when disabled
- Files changed tracked correctly via VCS
- `stop()` prevents further heartbeats
- Store write failure is non-fatal (session continues)
- Multiple start/stop cycles work correctly

---

#### TRD-009-007: Integrate heartbeat into pipeline executor [3h]
[satisfies FR-3 integration]

**Validates PRD ACs:** AC-3

Wire `HeartbeatManager` into `pipeline-executor.ts`:
1. Initialize heartbeat manager in `runPhaseSequence()` using config from `ProjectConfig`
2. Call `heartbeatManager.start(phaseName)` at the start of each phase
3. Call `heartbeatManager.update()` with session stats on each tool call
4. Call `heartbeatManager.stop()` at the end of each phase

**Read config from `ProjectConfig.observability.heartbeat`** — if not set, default to `enabled: true, intervalSeconds: 60`.

**Implementation ACs:**
- Given a pipeline executor with heartbeat enabled (default config), when a phase runs for >60s, then heartbeat events are visible in the events table.
- Given a pipeline executor with heartbeat disabled (`enabled: false`), when phases run, then no heartbeat events are written.

[depends: TRD-009-005, TRD-009-006]

---

### Sprint 4: Self-Documenting Commits (FR-4)

#### TRD-009-008: Extend PhaseRecord for activity log [3h]
[satisfies FR-4]

**Validates PRD ACs:** AC-4

Extend the existing `PhaseRecord` interface in `src/orchestrator/session-log.ts` to capture the full activity data needed for `ACTIVITY_LOG.json`.

**Extended PhaseRecord fields:**
```typescript
export interface PhaseRecord {
  name: string;
  skipped: boolean;
  success?: boolean;
  costUsd?: number;
  turns?: number;
  error?: string;
  // New fields
  startedAt: string; // ISO 8601
  completedAt?: string; // ISO 8601
  durationSeconds?: number;
  toolCalls?: number;
  toolBreakdown?: Record<string, number>;
  filesChanged?: string[];
  editsByFile?: Record<string, number>;
  commandsRun?: string[];
  verdict?: "pass" | "fail" | "skipped" | "unknown";
  model?: string;
}
```

**`ActivityLog` interface** (add to `session-log.ts`):
```typescript
export interface ActivityLog {
  seedId: string;
  runId: string;
  phases: PhaseRecord[];
  totalCostUsd: number;
  totalTurns: number;
  totalToolCalls: number;
  filesChangedTotal: string[];
  commits: CommitInfo[];
  warnings: string[];
  retryLoops: number;
  generatedAt: string;
}

export interface CommitInfo {
  hash: string;
  message: string;
  timestamp: string;
}
```

**Helper functions:**
- `computeFilesChangedTotal(phases: PhaseRecord[]): string[]` — deduplicated union of all files changed
- `countRetries(phases: PhaseRecord[]): number` — count how many times developer phase was retried
- `detectWarnings(phases: PhaseRecord[]): string[]` — detect guardrail vetoes, retry loops, stale worktree warnings

**Implementation ACs:**
- Given a completed pipeline with phases `explorer → developer → qa`, when `ActivityLog` is generated, then `totalCostUsd` equals the sum of all phase costs.
- Given phases with `editsByFile` tracking, when `computeFilesChangedTotal()` is called, then the result deduplicates files across phases.
- Given a developer retry, when `countRetries()` is called, then the count is correct.

[depends: TRD-009-005, TRD-009-007]

---

#### TRD-009-009: Generate ACTIVITY_LOG.json [3h]
[satisfies FR-4]

**Validates PRD ACs:** AC-4

Create `src/orchestrator/activity-logger.ts` with the `generateActivityLog()` function.

```typescript
export async function generateActivityLog(opts: {
  worktreePath: string;
  runId: string;
  seedId: string;
  phases: PhaseRecord[];
  vcsBackend: VcsBackend;
  targetBranch: string;
}): Promise<void>
```

**Steps:**
1. Compute `totalCostUsd`, `totalTurns`, `totalToolCalls` from phases
2. Compute `filesChangedTotal` as deduplicated union
3. Get commit history via `vcs.diff()` between `origin/<targetBranch>` and HEAD
4. Detect warnings via `detectWarnings()`
5. Write `ACTIVITY_LOG.json` to `worktreePath/ACTIVITY_LOG.json`

**File format**: JSON (pretty-printed with 2-space indent)

**Commit history** (for git): Use `vcs.diff()` output to show files changed, then use `vcs.getHeadId()` to get the final commit hash.

**Implementation ACs:**
- Given a completed pipeline, when `generateActivityLog()` is called, then `ACTIVITY_LOG.json` is written to the worktree root.
- Given a completed pipeline, when `git show HEAD:ACTIVITY_LOG.json` is run, then valid JSON is returned containing all phases, costs, and files.
- Given `includeGitDiffStat: true` in config, when generated, then `ACTIVITY_LOG.json` includes a `gitDiffStat` field with `git diff --stat` output.

[depends: TRD-009-008]

---

#### TRD-009-010: Update finalize to write ACTIVITY_LOG.json before commit [2h]
[satisfies FR-4]

**Validates PRD ACs:** AC-4 (finalize integration)

Modify `src/orchestrator/agent-worker-finalize.ts` to call `generateActivityLog()` before staging files. Pass `phaseRecords` from the pipeline context.

**Changes:**
1. Accept `phaseRecords: PhaseRecord[]` in `FinalizeConfig`
2. Before `vcs.stageAll(worktreePath)`, call `generateActivityLog()`
3. `ACTIVITY_LOG.json` will be picked up by `git add -A` automatically

**Implementation ACs:**
- Given a completed pipeline, when `finalize()` is called, then `ACTIVITY_LOG.json` is staged and committed with the code changes.
- Given a finalize with no prior phases (empty phaseRecords), when finalize commits, then `ACTIVITY_LOG.json` contains `phases: []` and `totalCostUsd: 0`.

[depends: TRD-009-009]

---

#### TRD-009-011: Add git diff --stat to FINALIZE_REPORT.md [2h]
[satisfies FR-4]

**Validates PRD ACs:** AC-7

Update the finalize report generation to include:
1. `git diff --stat` output showing files changed (from `origin/<branch>` to HEAD)
2. Phase-by-phase summary table (name, status, cost, turns, verdict)
3. Total cost + turns

**Implementation ACs:**
- Given a completed pipeline, when `FINALIZE_REPORT.md` is generated, then it includes `git diff --stat` output.
- Given a phase with `verdict: "fail"`, when the summary table is generated, then the row shows "FAIL" status.
- Given total cost of `$1.50` and 50 turns, when the report is generated, then the totals section shows these values.

[depends: TRD-009-008]

---

### Sprint 5: Stale Worktree Handling (FR-5, FR-6)

#### TRD-009-012: Create stale worktree check module [3h]
[satisfies FR-5]

**Validates PRD ACs:** AC-5

Create `src/orchestrator/stale-worktree-check.ts`:

```typescript
export interface StaleWorktreeCheckResult {
  /** True if the worktree was already up-to-date. */
  rebased: boolean;
  /** True if an auto-rebase was performed. */
  autoRebasePerformed: boolean;
  /** Error message if rebase failed. */
  error?: string;
}

/**
 * Check if a worktree is stale (behind its target branch) and optionally auto-rebase.
 *
 * @param vcs - VCS backend instance
 * @param worktreePath - Absolute path to the worktree
 * @param targetBranch - Target branch name (e.g. "dev")
 * @param store - ForemanStore for event logging
 * @param projectId - Foreman project ID
 * @param runId - Current run ID
 * @param seedId - Seed identifier
 * @param opts - Options: autoRebase (default: true), failOnConflict (default: true)
 * @returns StaleWorktreeCheckResult
 */
export async function checkAndRebaseStaleWorktree(
  vcs: VcsBackend,
  worktreePath: string,
  targetBranch: string,
  store: ForemanStore,
  projectId: string,
  runId: string,
  seedId: string,
  opts?: { autoRebase?: boolean; failOnConflict?: boolean },
): Promise<StaleWorktreeCheckResult>
```

**Logic:**
1. Get local HEAD via `vcs.getHeadId(worktreePath)`
2. Fetch origin via `vcs.fetch(worktreePath)`
3. Resolve `origin/<targetBranch>` via `vcs.resolveRef(worktreePath, origin/<targetBranch>)`
4. If `localHead !== originHead`:
   - If `opts.autoRebase !== false`: attempt `vcs.rebase(worktreePath, origin/<targetBranch>)`
   - On rebase success: log `worktree-rebased` event, return `{ rebased: true, autoRebasePerformed: true }`
   - On rebase failure: log `worktree-rebase-failed` event, return `{ rebased: false, error: <message> }` (if `opts.failOnConflict !== false`, throw the error)
5. If `localHead === originHead`: return `{ rebased: true, autoRebasePerformed: false }`

**Fresh worktree handling**: If `vcs.branchExists()` for the worktree's branch returns `false` (no prior commits), skip the rebase check entirely — no error.

**Implementation ACs:**
- Given a worktree at commit `abc123` where `origin/dev` is now at `def456`, when `checkAndRebaseStaleWorktree()` is called, then the worktree is rebased and a `worktree-rebased` event is logged.
- Given a worktree that is already up-to-date with `origin/dev`, when `checkAndRebaseStaleWorktree()` is called, then no rebase is attempted and `{ rebased: true, autoRebasePerformed: false }` is returned.
- Given a rebase conflict, when it occurs, then a `worktree-rebase-failed` event is logged and an error is thrown if `failOnConflict: true`.
- Given a fresh worktree (no commits), when `checkAndRebaseStaleWorktree()` is called, then no rebase is attempted.

[depends: TRD-009-002]

---

#### TRD-009-012-TEST: Test stale worktree check [2h]
[verifies TRD-009-012]

Write vitest tests:
- Stale worktree → auto-rebase succeeds
- Stale worktree → rebase fails with conflicts
- Already-up-to-date worktree → no rebase
- Fresh worktree → skip rebase check
- Event logging: `worktree-rebased` written on success
- Event logging: `worktree-rebase-failed` written on conflict

---

#### TRD-009-013: Integrate stale worktree check into dispatcher [3h]
[satisfies FR-5 integration]

**Validates PRD ACs:** AC-5

In `src/orchestrator/dispatcher.ts`, before spawning a worker for an existing worktree, call `checkAndRebaseStaleWorktree()`.

**Integration point**: In the dispatcher's worker spawn logic — after creating or selecting the worktree, but before spawning the Pi SDK session — add a call to `checkAndRebaseStaleWorktree()`.

**Config**: Read `staleWorktree.autoRebase` from `ProjectConfig`. Default to `true`.

**Implementation ACs:**
- Given a stale worktree, when the dispatcher spawns a worker, then the worktree is rebased before the worker starts.
- Given `staleWorktree.autoRebase: false` in config, when the dispatcher spawns a worker, then no rebase is attempted and a warning is logged.

[depends: TRD-009-012]

---

#### TRD-009-014: Add rebase-before-finalize check [3h]
[satisfies FR-6]

**Validates PRD ACs:** AC-6

In `src/orchestrator/agent-worker-finalize.ts`, at the start of `finalize()`, add a pre-finalize rebase check.

**New function in `agent-worker-finalize.ts`:**
```typescript
async function preFinalizeRebaseCheck(
  vcs: VcsBackend,
  worktreePath: string,
  targetBranch: string,
  store: ForemanStore,
  projectId: string,
  runId: string,
  seedId: string,
): Promise<void>
```

**Logic:**
1. `await vcs.fetch(worktreePath)`
2. Get `localHead = await vcs.getHeadId(worktreePath)`
3. Get `remoteHead = await vcs.resolveRef(worktreePath, origin/<targetBranch>)`
4. If `localHead !== remoteHead`:
   - Log info: `Target branch ${targetBranch} has moved. Auto-rebasing...`
   - Attempt `vcs.rebase(worktreePath, origin/<targetBranch>)`
   - On success: log `worktree-rebased` event
   - On failure: throw `Error("Rebase failed before finalize: ${result.error}")`

**Call site**: At the very start of the `finalize()` function, before the type-check.

**Implementation ACs:**
- Given a finalize phase where `origin/dev` has moved since the test phase, when finalize starts, then the worktree is rebased before any commit is made.
- Given a rebase conflict during pre-finalize rebase, when it occurs, then a `worktree-rebase-failed` event is logged and finalize throws a clear error message.
- After auto-rebase, the finalize phase proceeds normally with Target Integration marked SUCCESS.

[depends: TRD-009-010]

---

#### TRD-009-014-TEST: Test pre-finalize rebase check [2h]
[verifies TRD-009-014]

Write vitest tests:
- Origin target branch unchanged → no rebase attempted
- Origin target branch moved → rebase attempted and succeeds
- Rebase conflict during pre-finalize → throws clear error, `worktree-rebase-failed` event logged
- Finalize report shows rebase status correctly

---

### Sprint 6: End-to-End Integration + Testing

#### TRD-009-015: End-to-end pipeline test with all guardrails enabled [4h]
[satisfies all ACs]

**Validates PRD ACs:** AC-1, AC-2, AC-3, AC-4, AC-5, AC-6, AC-7

Write an integration test in `src/orchestrator/__tests__/pipeline-executor.test.ts` that:
1. Spins up a real git worktree with a test project
2. Dispatches a seed with all guardrails enabled (via config)
3. Runs the full pipeline through `pipeline-executor`
4. Verifies all acceptance criteria

**Test structure**:
```typescript
describe("guardrails and observability e2e", () => {
  it("AC-1: guardrail intercepts wrong-directory edit", async () => { ... });
  it("AC-2: phase-start event written before agent spawns", async () => { ... });
  it("AC-3: heartbeat fires every 60s during active phase", async () => { ... });
  it("AC-4: ACTIVITY_LOG.json committed with code", async () => { ... });
  it("AC-5: stale worktree auto-rebased on retry", async () => { ... });
  it("AC-6: rebase-before-finalize prevents drift failures", async () => { ... });
  it("AC-7: FINALIZE_REPORT.md contains diff stat", async () => { ... });
});
```

**Setup**: Use a temporary directory with a minimal git repo. Create a seed that makes a simple file edit.

**Note**: Full e2e tests may require mocking the Pi SDK session to avoid LLM costs during testing.

[depends: TRD-009-001 through TRD-009-014]

---

## System Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│ ProjectConfig (project-config.ts)                           │
│  guardrails, observability, staleWorktree                   │
└──────────────────────┬──────────────────────────────────────┘
                       │ (passed to pipeline executor)
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ PipelineExecutor (pipeline-executor.ts)                     │
│  ├─ Phase-start event logging (TRD-009-005)                 │
│  ├─ HeartbeatManager wiring (TRD-009-007)                   │
│  └─ Stale worktree check → dispatcher (TRD-009-013)        │
└──────────────────────┬──────────────────────────────────────┘
                       │
          ┌────────────┴────────────┐
          ▼                         ▼
┌──────────────────────┐  ┌──────────────────────────────┐
│ HeartbeatManager     │  │ PiSdkRunner (pi-sdk-runner.ts)│
│ (heartbeat-manager.ts)   │  ├─ GuardrailConfig support  │
│  ├─ interval timer   │  │  └─ Pre-tool hook for       │
│  ├─ store.logEvent() │  │     directory verification   │
│  └─ filesChanged via │  │     (TRD-009-004)           │
│     VcsBackend       │  └──────────────────────────────┘
└──────────────────────┘
          │
          ▼
┌──────────────────────┐
│ GuardrailsModule     │
│ (guardrails.ts)      │
│  ├─ createDirectoryGuardrail()  │
│  ├─ mode: auto-correct | veto | disabled  │
│  └─ Pre-tool hook for Pi SDK    │
└──────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ AgentWorkerFinalize (agent-worker-finalize.ts)              │
│  ├─ preFinalizeRebaseCheck() (TRD-009-014)                 │
│  ├─ generateActivityLog() (TRD-009-009)                   │
│  ├─ ACTIVITY_LOG.json generation                          │
│  └─ FINALIZE_REPORT.md with git diff --stat (TRD-009-011)  │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ ActivityLogger (activity-logger.ts)                          │
│  ├─ generateActivityLog()                                  │
│  ├─ PhaseRecord accumulation                               │
│  └─ ACTIVITY_LOG.json serialization                        │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ StaleWorktreeCheck (stale-worktree-check.ts)                │
│  ├─ checkAndRebaseStaleWorktree()                          │
│  ├─ Uses VcsBackend: getHeadId, fetch, resolveRef, rebase │
│  └─ Logs worktree-rebased / worktree-rebase-failed events │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ ForemanStore (store.ts)                                      │
│  ├─ logEvent() → writes events to SQLite                   │
│  └─ New event types: phase-start, heartbeat, guardrail-*   │
│                     worktree-rebased, worktree-rebase-failed│
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ VcsBackend (interface.ts, git-backend.ts, jujutsu-backend.ts)│
│  ├─ getHeadId() ─ already exists in both backends          │
│  ├─ fetch() ─ already exists                              │
│  ├─ resolveRef() ─ already exists                         │
│  ├─ rebase() ─ already exists                             │
│  └─ isAncestor() ─ already exists in both backends        │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

**Guardrail (FR-1):**
```
Agent tool call → Pi SDK tool wrapper → Guardrail pre-tool hook
                                             │
                    ┌────────────────────────┴────────────────────────┐
                    │ currentCwd === expectedCwd?                       │
              Yes ─┘                                              No ─┘
        allowed: true                                    ┌───────────────┴───────────────┐
                                                       mode: "auto-correct"    mode: "veto"
                                                          │                          │
                                               prepend "cd expected &&"        logEvent("guardrail-veto", ...)
                                               allowed: true              allowed: false
```

**Heartbeat (FR-3):**
```
Phase starts → HeartbeatManager.start() → setInterval(60s)
                                              │
                                    ┌─────────▼─────────┐
                                    │ interval fires    │
                                    │ → store.logEvent  │
                                    │   ("heartbeat",   │
                                    │    {...data})     │
                                    └─────────┬─────────┘
Phase ends  ← HeartbeatManager.stop() ──────────┘
```

**ACTIVITY_LOG.json (FR-4):**
```
Pipeline completes → generateActivityLog()
                              │
                    ┌─────────┼─────────────────────────────┐
                    │                                          │
            Collect PhaseRecords           vcs.diff() for files
            (cost, turns, toolCalls,       (commits, diff stat)
            toolBreakdown, filesChanged)
                              │
                    └─────────┴─────────────┐
                                         │
                                   writeFile(
                        worktreePath/ACTIVITY_LOG.json
                      )
                              │
                    git add -A (finalize) → committed
```

---

## File Inventory

| File | Status | TRD |
|---|---|---|
| `src/lib/project-config.ts` | Modify | TRD-009-001 |
| `src/lib/vcs/git-backend.ts` | No changes needed (isAncestor exists) | TRD-009-002 |
| `src/lib/vcs/jujutsu-backend.ts` | No changes needed (isAncestor exists) | TRD-009-002 |
| `src/orchestrator/guardrails.ts` | **New** | TRD-009-003 |
| `src/orchestrator/__tests__/guardrails.test.ts` | **New** | TRD-009-003-TEST |
| `src/orchestrator/pi-sdk-runner.ts` | Modify | TRD-009-004 |
| `src/orchestrator/pipeline-executor.ts` | Modify | TRD-009-005, TRD-009-007 |
| `src/orchestrator/heartbeat-manager.ts` | **New** | TRD-009-006 |
| `src/orchestrator/activity-logger.ts` | **New** | TRD-009-009 |
| `src/orchestrator/stale-worktree-check.ts` | **New** | TRD-009-012 |
| `src/orchestrator/session-log.ts` | Modify (extend PhaseRecord) | TRD-009-008 |
| `src/orchestrator/agent-worker-finalize.ts` | Modify | TRD-009-010, TRD-009-011, TRD-009-014 |
| `src/orchestrator/dispatcher.ts` | Modify | TRD-009-013 |
| `src/orchestrator/__tests__/pipeline-executor.test.ts` | Modify (add e2e tests) | TRD-009-015 |

---

## Sprint Planning

### Sprint 1: Configuration + VCS Foundation
- **Duration**: 3h
- **Tasks**: TRD-009-001, TRD-009-001-TEST, TRD-009-002
- **Deliverable**: Config schema for guardrails/observability/staleWorktree; VCS coverage verified

### Sprint 2: Guardrails Module (FR-1)
- **Duration**: 9h
- **Tasks**: TRD-009-003, TRD-009-003-TEST, TRD-009-004, TRD-009-004-TEST
- **Deliverable**: Working directory verification guardrail integrated into Pi SDK Runner

### Sprint 3: Observability — Phase Events + Heartbeat (FR-2, FR-3)
- **Duration**: 10h
- **Tasks**: TRD-009-005, TRD-009-005-TEST, TRD-009-006, TRD-009-006-TEST, TRD-009-007
- **Deliverable**: Phase-start and heartbeat events writing to SQLite every 60s

### Sprint 4: Self-Documenting Commits (FR-4)
- **Duration**: 10h
- **Tasks**: TRD-009-008, TRD-009-009, TRD-009-010, TRD-009-011
- **Deliverable**: ACTIVITY_LOG.json committed with every branch; FINALIZE_REPORT.md includes diff stat

### Sprint 5: Stale Worktree Handling (FR-5, FR-6)
- **Duration**: 10h
- **Tasks**: TRD-009-012, TRD-009-012-TEST, TRD-009-013, TRD-009-014, TRD-009-014-TEST
- **Deliverable**: Auto-rebase on dispatch; rebase-before-finalize check

### Sprint 6: End-to-End Testing
- **Duration**: 4h
- **Tasks**: TRD-009-015
- **Deliverable**: All 7 ACs verified via integration test

**Total estimated effort**: ~46h

---

## Acceptance Criteria

| ID | Criterion | Test Scenario | TRD |
|---|---|---|---|
| AC-1 | Guardrail intercepts wrong-directory edit | Agent in `/wrong/path` attempts `edit` → guardrail vetoes or corrects | TRD-009-003, TRD-009-004 |
| AC-2 | `phase-start` event written before agent spawns | Start `fix` phase → query events → `phase-start` event exists | TRD-009-005 |
| AC-3 | Heartbeat fires every 60s during active phase | Start `fix` phase, wait 65s → query events → `heartbeat` event exists | TRD-009-006, TRD-009-007 |
| AC-4 | `ACTIVITY_LOG.json` committed with code | Complete pipeline → `git show HEAD:ACTIVITY_LOG.json` → valid JSON | TRD-009-009, TRD-009-010 |
| AC-5 | Stale worktree auto-rebased on retry | Worktree behind `origin/dev` → dispatch → rebase → `worktree-rebased` event | TRD-009-012, TRD-009-013 |
| AC-6 | Rebase-before-finalize prevents drift failures | `origin/dev` moves during test → finalize → auto-rebase → SUCCESS | TRD-009-014 |
| AC-7 | `FINALIZE_REPORT.md` contains diff stat | Complete pipeline → `FINALIZE_REPORT.md` → `git diff --stat` output present | TRD-009-011 |

---

## Non-Functional Requirements

| NFR | Requirement | Verification |
|---|---|---|
| NFR-1 | Guardrail overhead <5ms per tool call | Performance test with `performance.now()` delta assertion |
| NFR-2 | Heartbeat flush: non-blocking, async, <100ms | Async test; measure write time |
| NFR-3 | Stale detection: <2 seconds before phase starts | Integration test timing assertion |
| NFR-4 | If heartbeat writing fails → continue (fail-safe) | Error-throwing mock → verify session continues |
| NFR-5 | VCS backend agnostic — all ops via VcsBackend interface | Integration test with both GitBackend and mock backend |

---

## Open Questions

| Question | Decision |
|---|---|
| Guardrail config per-phase or global? | **Global** in ProjectConfig. Per-phase override can be added later. |
| Heartbeat filesChanged: git diff vs. tool call tracking? | **git diff** from origin/target to HEAD. More accurate; tool call tracking may miss non-agent changes. |
| ACTIVITY_LOG.json: machine-readable (JSON) vs. human-readable? | **Both**: ACTIVITY_LOG.json is JSON; FINALIZE_REPORT.md is markdown. Matches PRD decision. |
| Stale worktree rebase: automatic or operator approval? | **Automatic with event logging**. Add `dispatch --no-auto-rebase` if operator wants control. |

---

## Related Documents

- [PRD-2026-009: Agent Guardrails and Observability](../PRD/PRD-2026-009-agent-guardrails-and-observability.md) — Source PRD
- [TRD-2026-004: VCS Backend Abstraction](TRD-2026-004-vcs-backend-abstraction.md) — VcsBackend interface reference
- [Workflow YAML Reference](../workflow-yaml-reference.md) — Configuration reference

---

## Change Log

| Date | Author | Change |
|---|---|---|
| 2026-04-19 | Foreman Pipeline (TRD Agent) | Initial TRD creation from PRD-2026-009 |
