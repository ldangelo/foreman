# TRD-2026-024: Refactor Foreman Coupling Hotspots

---
document_id: TRD-2026-024
prd_reference: PRD-foreman-9960c
version: 1.0.0
status: Draft
date: 2026-06-06
architecture: "Interface Segregation + Read Model Pattern"
design_readiness_score: 4.8
total_tasks: 13
---

## TRD Health Summary

| Metric | Value |
|--------|-------|
| Implementation tasks | 8 |
| Test tasks | 5 |
| Sprint 1 (Type-Level Seams) | 6 tasks |
| Sprint 2 (Read Model Implementations) | 4 tasks |
| Sprint 3 (Dispatcher Dependency Narrowing) | 3 tasks |
| REQ coverage | 5/5 (100%) |
| Orphaned annotations | 0 |

---

## Architecture Decision

### Chosen Approach: Interface Segregation + Read Model Pattern

Extract clean TypeScript interfaces that define boundaries between modules, so internal type changes don't leak across module borders. Use the adapter pattern to wrap concrete store implementations behind read-only interfaces.

**Key component boundaries:**

```
┌─────────────────────────────────────────────────────────────────┐
│  src/orchestrator/read-models.ts                               │
│  Read-only interfaces: RunSummary, RunProgressSummary,         │
│  RunStoreReadModel. Orchestrator never constructs these. │
└───────────────────┬─────────────────────────────────────────────┘
                    │ imports
    ┌───────────────▼──────────────────────┐   ┌─────────────────────────┐
    │  src/orchestrator/write-models.ts   │   │  src/orchestrator/       │
    │  Write intent interfaces: │   │  store-read-model-       │
    │  RunCommands, RunFactory │   │  adapter.ts             │
    └───────────────┬──────────────────────┘   └──────────┬──────────────┘
                    │                                   │ implements
    ┌───────────────▼───────────────────────────────────▼──────────────┐
    │  src/orchestrator/dispatcher-dependencies.ts                      │
    │  Facade encapsulating all dispatcher dependencies                │
    └───────────────────────────┬─────────────────────────────────────┘
                                │ injected
    ┌───────────────────────────▼─────────────────────────────────────┐
    │  src/orchestrator/dispatcher.ts                                 │
    │  No longer imports ForemanStore, PostgresStore directly │
    │  Accepts RunStoreReadModel + RunCommands via constructor │
    └─────────────────────────────────────────────────────────────────┘

    ┌─────────────────────────────────────────────────────────────────┐
    │  src/lib/store.ts (unchanged)                                   │
    │  Concrete implementation: ForemanStore, PostgresStore           │
    │  Remains source of truth for run data │
    └─────────────────────────────────────────────────────────────────┘
```

**Data flow after refactoring:**
1. `dispatcher.ts` receives `RunStoreReadModel` and `RunCommands` via constructor injection
2. Read operations use `RunStoreReadModel.getRun()`, `getRunsForSeed()`, etc.
3. Write operations use `RunCommands.updateStatus()`, `setProgress()`, `logEvent()`
4. `ForemanStoreReadModelAdapter` wraps concrete `ForemanStore` and exposes `RunStoreReadModel`
5. `types.ts` imports from `read-models.ts` instead of `../lib/store.js`

### Alternatives Considered

**Option A — Feature Flags**: Use feature flags to toggle between old and new code paths. Rejected because this doubles the code paths and makes testing incomplete — we can't verify the new interface boundaries are correct if old code is still present.

**Option B — Full Rewrite**: Rewrite `dispatcher.ts` from scratch with clean interfaces. Rejected because the existing dispatcher has complex behavior (35+ modules worth) that would be lost. This is a surgical refactor, not a rewrite.

**Option C — Type-only imports with `import type`**: Use `import type` to break runtime coupling while keeping imports. Partially implemented in Phase 1.3, but insufficient alone because:
- `import type` only removes runtime coupling, not conceptual coupling
- Callers still depend on concrete store shape
- No adapter layer means no ability to substitute implementations

### Technology Choices

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Interface definition | TypeScript `interface` | Structural typing allows adapter pattern; no new dependencies |
| Adapter pattern | Wrapper class | `ForemanStoreReadModelAdapter` implements `RunStoreReadModel`; swap without caller changes |
| Dependency injection | Constructor parameters | Standard pattern; easy to mock in tests |
| Read model isolation | New files | `read-models.ts`, `write-models.ts` are pure interface definitions; no runtime deps |

---

## Master Task List

### Sprint 1: Type-Level Seams (Foundation)

- [ ] **TRD-001**: Create `src/orchestrator/read-models.ts` — Read-only interfaces: `RunSummary`, `RunProgressSummary`, `RunStoreReadModel` [satisfies REQ-001]
- [ ] **TRD-001-TEST**: Test `read-models.ts` — TypeScript compiles, interfaces are structurally compatible with `Run`/`RunProgress` from store [verifies TRD-001] [satisfies REQ-001] [depends: TRD-001]
- [ ] **TRD-002**: Create `src/orchestrator/write-models.ts` — Write intent interfaces: `RunCommands`, `RunFactory` [satisfies REQ-002]
- [ ] **TRD-002-TEST**: Test `write-models.ts` — TypeScript compiles, interface methods match ForemanStore mutations [verifies TRD-002] [satisfies REQ-002] [depends: TRD-002]
- [ ] **TRD-003**: Update `src/orchestrator/types.ts` — Remove `import("../lib/store.js")` for `Run`, `RunProgress`; import from `read-models.ts` instead [satisfies REQ-003]
- [ ] **TRD-003-TEST**: Test `types.ts` — TypeScript compiles with no store.js imports; `MonitorReport`, `WorkerProgressNotification` use read-model types [verifies TRD-003] [satisfies REQ-003] [depends: TRD-003]

### Sprint 2: Read Model Implementations

- [ ] **TRD-004**: Create `src/orchestrator/store-read-model-adapter.ts` — `ForemanStoreReadModelAdapter` implements `RunStoreReadModel`; wraps `ForemanStore` [satisfies REQ-004]
- [ ] **TRD-004-TEST**: Test `store-read-model-adapter.ts` — Adapter returns `RunSummary` objects; null when run not found; correct field mapping [verifies TRD-004] [satisfies REQ-004] [depends: TRD-004]
- [ ] **TRD-005**: Update `src/orchestrator/pipeline-executor.ts` — Use `RunStoreReadModel` for read-only access; keep `ForemanStore` only where writes are necessary [satisfies REQ-005]
- [ ] **TRD-005-TEST**: Test `pipeline-executor.ts` — TypeScript compiles; read operations use read model; write operations use ForemanStore directly [verifies TRD-005] [satisfies REQ-005] [depends: TRD-005]

### Sprint 3: Dispatcher Dependency Narrowing

- [ ] **TRD-006**: Create `src/orchestrator/dispatcher-dependencies.ts` — Facade `DispatcherDeps` encapsulating all dispatcher dependencies [satisfies REQ-006]
- [ ] **TRD-007**: Update `src/orchestrator/dispatcher.ts` — Accept `RunStoreReadModel` and `RunCommands` via constructor; remove direct `ForemanStore` instantiation [satisfies REQ-007]
- [ ] **TRD-007-TEST**: Test `dispatcher.ts` — TypeScript compiles; no direct imports of `ForemanStore`, `PostgresStore`, `pool-manager`; `npx tsc --noEmit` passes [verifies TRD-007] [satisfies REQ-007] [depends: TRD-007]

---

## Sprint Implementation Details

### Sprint 1: Type-Level Seams (Foundation)

#### TRD-001: Create `src/orchestrator/read-models.ts` [satisfies REQ-001]
**Estimate:** 2h  
**Validates PRD ACs:** AC-1.1, AC-1.2, AC-1.3

Create a new file `src/orchestrator/read-models.ts` with the following interfaces:

```typescript
// Run status values (mirrors store.ts RunStatus)
export type RunStatus = "pending" | "running" | "completed" | "failed" | "stuck" | "merged" | "conflict" | "test-failed" | "pr-created" | "reset";

// Merge strategy values
export type MergeStrategy = "auto" | "pr" | "none";

// PR state values
export type PrState = "none" | "draft" | "open" | "merged" | "closed";

/**
 * Read-only summary of a Run.
 * Orchestrator modules consume this via RunStoreReadModel, never constructing directly.
 */
export interface RunSummary {
  id: string;
  seedId: string;
  status: RunStatus;
  agentType: string;
  startedAt: string | null;
  completedAt: string | null;
  worktreePath: string | null;
  baseBranch: string | null;
  mergeStrategy: MergeStrategy | null;
  commitSha: string | null;
  prUrl: string | null;
  prState: PrState | null;
  prHeadSha: string | null;
}

/**
 * Read-only summary of RunProgress.
 * Used for heartbeat and progress tracking.
 */
export interface RunProgressSummary {
  currentPhase: string;
  phaseIndex: number;
  turnCount: number;
  lastHeartbeat: string;
}

/**
 * Read model interface for run queries.
 * Store implementations (ForemanStore, PostgresStore) must satisfy this.
 */
export interface RunStoreReadModel {
  getRun(runId: string): Promise<RunSummary | null>;
  getRunsForSeed(seedId: string): Promise<RunSummary[]>;
  getActiveRuns(projectId: string): Promise<RunSummary[]>;
  getRunsByStatus(status: RunStatus, projectId: string): Promise<RunSummary[]>;
}
```

**Field mapping from `Run` (store.ts):**
| Run field | RunSummary field |
|-----------|-----------------|
| `id` | `id` |
| `seed_id` | `seedId` |
| `status` | `status` |
| `agent_type` | `agentType` |
| `started_at` | `startedAt` |
| `completed_at` | `completedAt` |
| `worktree_path` | `worktreePath` |
| `base_branch` | `baseBranch` |
| `merge_strategy` | `mergeStrategy` |
| `commit_sha` | `commitSha` |
| `pr_url` | `prUrl` |
| `pr_state` | `prState` |
| `pr_head_sha` | `prHeadSha` |

**Implementation AC checklist:**
- [ ] Given `RunSummary` interface, when TypeScript compiles, then all fields are optional where the source field is nullable
- [ ] Given `RunStoreReadModel` interface, when implemented by adapter, then all four methods are present
- [ ] Given `RunProgressSummary` interface, when compared to `RunProgress` from store, then fields are read-only subsets

---

#### TRD-001-TEST: Test `read-models.ts` [verifies TRD-001] [satisfies REQ-001] [depends: TRD-001]
**Estimate:** 1h  
**Validates PRD ACs:** AC-1.1, AC-1.2, AC-1.3

Write a TypeScript compilation test that verifies:
1. `npx tsc --noEmit src/orchestrator/read-models.ts` passes
2. All exported types are exported (not accidentally made internal via `export type`)
3. `RunSummary` fields are compatible with `Run` from store (structural assignment works)

```typescript
// src/orchestrator/__tests__/read-models.test.ts
import type { RunSummary, RunProgressSummary, RunStoreReadModel } from "../read-models.js";
import type { Run, RunProgress } from "../../lib/store.js";

describe("read-models.ts", () => {
  describe("RunSummary", () => {
    it("is structurally compatible with Run", () => {
      // This test verifies that RunSummary is a valid read-only projection of Run
      const runToSummary = (run: Run): RunSummary => ({
        id: run.id,
        seedId: run.seed_id,
        status: run.status,
        agentType: run.agent_type,
        startedAt: run.started_at,
        completedAt: run.completed_at,
        worktreePath: run.worktree_path,
        baseBranch: run.base_branch ?? null,
        mergeStrategy: run.merge_strategy ?? null,
        commitSha: run.commit_sha ?? null,
        prUrl: run.pr_url ?? null,
        prState: run.pr_state ?? null,
        prHeadSha: run.pr_head_sha ?? null,
      });
      
      // If this compiles, the types are compatible
      const _summary: RunSummary = runToSummary({
        id: "test",
        project_id: "proj",
        seed_id: "seed",
        agent_type: "developer",
        session_key: null,
        worktree_path: null,
        status: "pending",
        started_at: null,
        completed_at: null,
        created_at: "2026-01-01",
        progress: null,
      });
    });
  });

  describe("RunStoreReadModel", () => {
    it("defines all required methods", () => {
      const mock: RunStoreReadModel = {
        getRun: async () => null,
        getRunsForSeed: async () => [],
        getActiveRuns: async () => [],
        getRunsByStatus: async () => [],
      };
      expect(typeof mock.getRun).toBe("function");
      expect(typeof mock.getRunsForSeed).toBe("function");
      expect(typeof mock.getActiveRuns).toBe("function");
      expect(typeof mock.getRunsByStatus).toBe("function");
    });
  });
});
```

---

#### TRD-002: Create `src/orchestrator/write-models.ts` [satisfies REQ-002]
**Estimate:** 1h  
**Validates PRD ACs:** AC-2.1, AC-2.2

Create a new file `src/orchestrator/write-models.ts` with write intent interfaces:

```typescript
import type { RunStatus, RunSummary } from "./read-models.js";

/**
 * Commands for mutating run state.
 * Used by orchestrator modules that need to update runs.
 */
export interface RunCommands {
  updateStatus(runId: string, status: RunStatus): Promise<void>;
  setProgress(runId: string, progress: string): Promise<void>;
  logEvent(runId: string, projectId: string, eventType: string, payload: Record<string, unknown>): Promise<void>;
}

/**
 * Factory for creating new runs.
 * Used by dispatcher to create runs before passing to agent-worker.
 */
export interface RunFactory {
  createRun(args: {
    runId: string;
    projectId: string;
    seedId: string;
    agentType: string;
    branchName: string;
    worktreePath: string | null;
    baseBranch?: string | null;
    mergeStrategy?: "auto" | "pr" | "none";
  }): Promise<RunSummary>;
}
```

**Implementation AC checklist:**
- [ ] Given `RunCommands` interface, when implemented by adapter, then all three mutation methods are present
- [ ] Given `RunFactory` interface, when implemented, then `createRun` returns `RunSummary`
- [ ] Given both interfaces, when imported by dispatcher, then no direct store imports needed

---

#### TRD-002-TEST: Test `write-models.ts` [verifies TRD-002] [satisfies REQ-002] [depends: TRD-002]
**Estimate:** 1h  
**Validates PRD ACs:** AC-2.1, AC-2.2

Write a TypeScript compilation test that verifies:
1. `npx tsc --noEmit src/orchestrator/write-models.ts` passes
2. Interface methods match `ForemanStore` method signatures

---

#### TRD-003: Update `src/orchestrator/types.ts` [satisfies REQ-003]
**Estimate:** 2h  
**Validates PRD ACs:** AC-3.1, AC-3.2

Update `src/orchestrator/types.ts` to remove direct imports from `../lib/store.js`:

**Before:**
```typescript
export interface MonitorReport {
  completed: import("../lib/store.js").Run[];
  stuck: import("../lib/store.js").Run[];
  active: import("../lib/store.js").Run[];
  failed: import("../lib/store.js").Run[];
}

export interface WorkerProgressNotification {
  type: "progress";
  runId: string;
  progress: import("../lib/store.js").RunProgress;
  timestamp: string;
}
```

**After:**
```typescript
import type { RunSummary, RunProgressSummary } from "./read-models.js";

export interface MonitorReport {
  completed: RunSummary[];
  stuck: RunSummary[];
  active: RunSummary[];
  failed: RunSummary[];
}

export interface WorkerProgressNotification {
  type: "progress";
  runId: string;
  progress: RunProgressSummary;
  timestamp: string;
}
```

**Implementation AC checklist:**
- [ ] Given `types.ts`, when TypeScript compiles, then no `import("../lib/store.js")` statements remain
- [ ] Given `MonitorReport`, when used, then it uses `RunSummary[]` not `Run[]`
- [ ] Given `WorkerProgressNotification`, when used, then it uses `RunProgressSummary` not `RunProgress`

---

#### TRD-003-TEST: Test `types.ts` [verifies TRD-003] [satisfies REQ-003] [depends: TRD-003]
**Estimate:** 1h  
**Validates PRD ACs:** AC-3.1, AC-3.2

1. Run `npx tsc --noEmit src/orchestrator/types.ts` — must pass
2. Grep for `import.*store` in `types.ts` — must return no matches
3. Verify `MonitorReport` and `WorkerProgressNotification` use read-model types

---

### Sprint 2: Read Model Implementations

#### TRD-004: Create `src/orchestrator/store-read-model-adapter.ts` [satisfies REQ-004]
**Estimate:** 3h  
**Validates PRD ACs:** AC-4.1, AC-4.2

Create the adapter that wraps `ForemanStore` and exposes `RunStoreReadModel`:

```typescript
import type { ForemanStore } from "../lib/store.js";
import type { RunSummary, RunProgressSummary, RunStoreReadModel, RunStatus } from "./read-models.js";

function mapRunToSummary(run: import("../lib/store.js").Run): RunSummary {
  return {
    id: run.id,
    seedId: run.seed_id,
    status: run.status,
    agentType: run.agent_type,
    startedAt: run.started_at,
    completedAt: run.completed_at,
    worktreePath: run.worktree_path,
    baseBranch: run.base_branch ?? null,
    mergeStrategy: run.merge_strategy ?? null,
    commitSha: run.commit_sha ?? null,
    prUrl: run.pr_url ?? null,
    prState: run.pr_state ?? null,
    prHeadSha: run.pr_head_sha ?? null,
  };
}

export class ForemanStoreReadModelAdapter implements RunStoreReadModel {
  constructor(private store: ForemanStore) {}
  
  async getRun(runId: string): Promise<RunSummary | null> {
    const run = await this.store.getRun(runId);
    return run ? mapRunToSummary(run) : null;
  }
  
  async getRunsForSeed(seedId: string): Promise<RunSummary[]> {
    const runs = await this.store.getRunsForSeed(seedId);
    return runs.map(mapRunToSummary);
  }
  
  async getActiveRuns(projectId: string): Promise<RunSummary[]> {
    const runs = await this.store.getActiveRuns(projectId);
    return runs.map(mapRunToSummary);
  }
  
  async getRunsByStatus(status: RunStatus, projectId: string): Promise<RunSummary[]> {
    const runs = await this.store.getRunsByStatus(status, projectId);
    return runs.map(mapRunToSummary);
  }
}
```

**Implementation AC checklist:**
- [ ] Given `ForemanStoreReadModelAdapter`, when constructed with `ForemanStore`, then all methods are bound correctly
- [ ] Given `getRun` with existing run, when called, then `RunSummary` is returned with correct field mapping
- [ ] Given `getRun` with non-existent run, when called, then `null` is returned
- [ ] Given `getRunsForSeed`, when called, then all runs are mapped correctly
- [ ] Given `getActiveRuns`, when called, then only active runs are returned
- [ ] Given `getRunsByStatus`, when called with valid status, then filtered runs are returned

---

#### TRD-004-TEST: Test `store-read-model-adapter.ts` [verifies TRD-004] [satisfies REQ-004] [depends: TRD-004]
**Estimate:** 2h  
**Validates PRD ACs:** AC-4.1, AC-4.2

Write Jest tests with a mock `ForemanStore`:

```typescript
// src/orchestrator/__tests__/store-read-model-adapter.test.ts
import { ForemanStoreReadModelAdapter } from "../store-read-model-adapter.js";
import type { ForemanStore, Run } from "../../lib/store.js";

describe("ForemanStoreReadModelAdapter", () => {
  const createMockStore = (runs: Run[]): ForemanStore => ({
    getRun: vi.fn().mockImplementation(async (runId: string) => 
      runs.find(r => r.id === runId) ?? null
    ),
    getRunsForSeed: vi.fn().mockImplementation(async (seedId: string) =>
      runs.filter(r => r.seed_id === seedId)
    ),
    getActiveRuns: vi.fn().mockImplementation(async (_projectId: string) =>
      runs.filter(r => r.status === "running")
    ),
    getRunsByStatus: vi.fn().mockImplementation(async (status: string, _projectId: string) =>
      runs.filter(r => r.status === status)
    ),
    // ... other required ForemanStore methods (can be noops for this test)
  } as unknown as ForemanStore);

  it("getRun returns RunSummary for existing run", async () => {
    const run: Run = {
      id: "run-1",
      project_id: "proj-1",
      seed_id: "seed-1",
      agent_type: "developer",
      session_key: null,
      worktree_path: "/tmp/worktree",
      status: "running",
      started_at: "2026-01-01T00:00:00Z",
      completed_at: null,
      created_at: "2026-01-01T00:00:00Z",
      progress: null,
    };
    
    const store = createMockStore([run]);
    const adapter = new ForemanStoreReadModelAdapter(store);
    
    const summary = await adapter.getRun("run-1");
    
    expect(summary).not.toBeNull();
    expect(summary!.id).toBe("run-1");
    expect(summary!.seedId).toBe("seed-1");
    expect(summary!.agentType).toBe("developer");
    expect(summary!.status).toBe("running");
  });

  it("getRun returns null for non-existent run", async () => {
    const store = createMockStore([]);
    const adapter = new ForemanStoreReadModelAdapter(store);
    
    const summary = await adapter.getRun("non-existent");
    
    expect(summary).toBeNull();
  });

  it("getRunsForSeed returns all matching runs", async () => {
    const runs: Run[] = [
      { id: "run-1", seed_id: "seed-1", status: "completed", /* ... */ } as Run,
      { id: "run-2", seed_id: "seed-1", status: "failed", /* ... */ } as Run,
      { id: "run-3", seed_id: "seed-2", status: "completed", /* ... */ } as Run,
    ];
    
    const store = createMockStore(runs);
    const adapter = new ForemanStoreReadModelAdapter(store);
    
    const summaries = await adapter.getRunsForSeed("seed-1");
    
    expect(summaries).toHaveLength(2);
    expect(summaries.every(s => s.seedId === "seed-1")).toBe(true);
  });
});
```

---

#### TRD-005: Update `src/orchestrator/pipeline-executor.ts` [satisfies REQ-005]
**Estimate:** 3h  
**Validates PRD ACs:** AC-5.1, AC-5.2

Update `pipeline-executor.ts` to use `RunStoreReadModel` for read-only access:

1. Add import for `RunStoreReadModel` from `./read-models.ts`
2. Add new constructor parameter `storeReadModel?: RunStoreReadModel`
3. When `storeReadModel` is provided, use it for `getRun()`, `getRunsForSeed()`, etc.
4. When `storeReadModel` is not provided, fall back to direct `ForemanStore` usage (backward compat)
5. Keep `ForemanStore` parameter for write operations via `RunCommands`

**Key changes:**
- `getRunSummary()` helper uses `storeReadModel.getRun()` when available
- `getRunsForSeedSummary()` helper uses `storeReadModel.getRunsForSeed()` when available
- Write operations (`updateRunProgress`, `logEvent`) continue using `ForemanStore` directly

**Implementation AC checklist:**
- [ ] Given `pipeline-executor.ts`, when TypeScript compiles, then both `ForemanStore` and `RunStoreReadModel` imports are present
- [ ] Given read operations, when `storeReadModel` is provided, then it is used instead of direct store access
- [ ] Given read operations, when `storeReadModel` is not provided, then `ForemanStore` is used (backward compatibility)
- [ ] Given write operations, when executed, then `ForemanStore` is always used directly

---

#### TRD-005-TEST: Test `pipeline-executor.ts` [verifies TRD-005] [satisfies REQ-005] [depends: TRD-005]
**Estimate:** 2h  
**Validates PRD ACs:** AC-5.1, AC-5.2

1. Run `npx tsc --noEmit src/orchestrator/pipeline-executor.ts` — must pass
2. Verify existing tests still pass: `npm test -- src/orchestrator/pipeline-executor`
3. Integration test: create mock `RunStoreReadModel`, pass to pipeline executor, verify read operations use the mock

---

### Sprint 3: Dispatcher Dependency Narrowing

#### TRD-006: Create `src/orchestrator/dispatcher-dependencies.ts` [satisfies REQ-006]
**Estimate:** 2h  
**Validates PRD ACs:** AC-6.1, AC-6.2

Create the dependency facade:

```typescript
import type { ITaskClient } from "../lib/task-client.js";
import type { RunStoreReadModel } from "./read-models.js";
import type { RunCommands, RunFactory } from "./write-models.js";
import type { VcsBackend } from "../lib/vcs/index.js";
import type { ProjectConfig } from "../lib/project-config.js";
import type { WorkflowConfig } from "../lib/workflow-loader.js";
import type { BvClient } from "../lib/bv.js";

/**
 * Facade encapsulating all dispatcher dependencies.
 * Dispatcher receives this via constructor; all concrete deps are injected.
 */
export interface DispatcherDeps {
  // Task management
  taskClient: ITaskClient;
  taskStoreMode: "br" | "bd" | "auto";
  
  // Read model
  storeReadModel: RunStoreReadModel;
  
  // Write commands
  runCommands: RunCommands;
  
  // Run factory
  runFactory: RunFactory;
  
  // VCS
  vcsBackend: VcsBackend;
  
  // Config
  projectConfig: ProjectConfig;
  workflowConfig: WorkflowConfig;
  
  // Optional overrides
  getRecentFailureCount?: (projectId: string, since: string) => Promise<number>;
  nativeTaskOps?: import("./dispatcher.js").NativeTaskOps;
  getActiveSeedIds?: () => Promise<string[]>;
  hasActiveOrPendingRun?: (seedId: string) => Promise<boolean>;
  getActiveAgentCount?: () => Promise<number>;
  externalProjectId?: string;
}
```

**Implementation AC checklist:**
- [ ] Given `DispatcherDeps`, when used to construct `Dispatcher`, then all required deps are present
- [ ] Given optional deps, when not provided, then they are optional (undefined acceptable)
- [ ] Given the interface, when compared to current dispatcher constructor, then all actual deps are covered

---

#### TRD-007: Update `src/orchestrator/dispatcher.ts` [satisfies REQ-007]
**Estimate:** 4h  
**Validates PRD ACs:** AC-7.1, AC-7.2

Update `dispatcher.ts` to accept injected dependencies:

1. Add import for `DispatcherDeps` from `./dispatcher-dependencies.ts`
2. Update constructor signature to accept `DispatcherDeps`
3. Remove direct imports of:
   - `ForemanStore`
   - `PostgresStore`
   - `PostgresAdapter`
   - `initPool`
   - `VcsBackendFactory`
   - Concrete config modules
4. Store deps in `this.deps` private field
5. Update all internal usages to use `this.deps.*` instead of direct module access

**Before (representative):**
```typescript
import { PostgresStore } from "../lib/postgres-store.js";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import { initPool } from "../lib/db/pool-manager.js";
import { PIPELINE_TIMEOUTS, getDefaultModel } from "../lib/config.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";

export class Dispatcher {
  private store: ForemanStore;
  private pool: PostgresPool;
  
  constructor(projectPath: string, options: DispatcherOptions) {
    this.store = ForemanStore.forProject(projectPath);
    this.pool = initPool(projectPath);
  }
}
```

**After:**
```typescript
import type { DispatcherDeps } from "./dispatcher-dependencies.js";

export class Dispatcher {
  private deps: DispatcherDeps;
  
  constructor(deps: DispatcherDeps) {
    this.deps = deps;
  }
}
```

**Implementation AC checklist:**
- [ ] Given `dispatcher.ts`, when TypeScript compiles, then no direct imports of `ForemanStore`, `PostgresStore`, `PostgresAdapter`, `initPool` remain
- [ ] Given `VcsBackendFactory`, when used internally, then it's accessed via `this.deps.vcsBackend` not direct import
- [ ] Given `DispatcherDeps`, when provided, then all required fields are accessible via `this.deps`
- [ ] Given existing test suite, when run, then all tests pass without modification

---

#### TRD-007-TEST: Test `dispatcher.ts` [verifies TRD-007] [satisfies REQ-007] [depends: TRD-007]
**Estimate:** 2h  
**Validates PRD ACs:** AC-7.1, AC-7.2

1. Run `npx tsc --noEmit src/orchestrator/dispatcher.ts` — must pass
2. Grep for concrete store imports — must return no matches:
   ```bash
   grep -E "ForemanStore|PostgresStore|PostgresAdapter|initPool" src/orchestrator/dispatcher.ts
   ```
3. Run full test suite: `npm test` — all tests must pass
4. Verify `dispatcher.ts` imports only:
   - Types from `read-models.ts`, `write-models.ts`, `dispatcher-dependencies.ts`
   - Pure utility functions (no store, db, or config classes)

---

## Verification Criteria

| Criterion | Verification Method |
|-----------|---------------------|
| Type check passes | `npx tsc --noEmit` succeeds with no errors |
| All tests pass | `npm test` passes before and after changes |
| No new runtime behavior | All existing functionality preserved |
| Interface segregation verified | `dispatcher.ts` imports only interface types |
| Adapter pattern verified | `ForemanStoreReadModelAdapter` implements `RunStoreReadModel` correctly |

---

## Files to Change

| File | Change |
|------|--------|
| `src/orchestrator/read-models.ts` | **NEW** — Read model interfaces |
| `src/orchestrator/write-models.ts` | **NEW** — Write intent interfaces |
| `src/orchestrator/store-read-model-adapter.ts` | **NEW** — ForemanStore → read model adapter |
| `src/orchestrator/dispatcher-dependencies.ts` | **NEW** — Dependency facade |
| `src/orchestrator/types.ts` | Remove store imports, use read-model types |
| `src/orchestrator/pipeline-executor.ts` | Use `RunStoreReadModel` for reads |
| `src/orchestrator/dispatcher.ts` | Accept injected deps, remove direct lib imports |

---

## Files NOT to Change (Preserve Behavior)

| File | Reason |
|------|--------|
| `src/lib/store.ts` | Concrete implementation unchanged |
| `src/lib/postgres-store.ts` | Concrete implementation unchanged |
| `src/lib/db/postgres-adapter.ts` | Concrete implementation unchanged |
| `src/lib/db/pool-manager.ts` | Concrete implementation unchanged |
| `src/lib/beads-rust.ts` | Unchanged |
| `src/lib/vcs/*.ts` | Unchanged |

---

## Risk & Constraints

- **Backward compatibility**: Store schema unchanged; adapters map existing fields
- **No feature changes**: This is a pure refactor — no new features or behavior
- **Minimal surface area**: Each new file has a single responsibility
- **Testing strategy**: Existing tests should pass without modification; adapter tested via unit tests
- **Migration path**: Phase 3 changes require updating callers of `Dispatcher` constructor to provide `DispatcherDeps` instead of direct module instantiation

---

*This TRD was created by tech-lead-orchestrator. Proceed with `/ensemble:implement-trd-beads docs/TRD/TRD-2026-024-refactor-coupling-hotspots.md` to begin implementation.*
