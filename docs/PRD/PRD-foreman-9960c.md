# PRD: Refactor Foreman Coupling Hotspots

## 1. Context & Problem Statement

Analysis of `src/orchestrator/dispatcher.ts`, `src/orchestrator/pipeline-executor.ts`, and related modules reveals three primary coupling hotspots that make the codebase difficult to test, extend, and reason about:

1. **`dispatcher.ts`**: 94KB, imports 35+ modules directly — tight coupling to lib, db, vcs, config, beads, and workflow subsystems
2. **Type-level leakage**: `src/orchestrator/types.ts` imports `Run`, `RunProgress`, `ForemanStore` from `../lib/store.js`, creating cross-module type dependencies that force changes in one module to ripple into the other
3. **Read-model缺口**: The dispatcher reads `Run`/`RunProgress` objects directly from the store rather than through abstracted read-model interfaces, making it difficult to substitute implementations or add caching

**Goal**: Reduce coupling at each layer while preserving all behavior. Changes must be surgical and behavior-preserving.

---

## 2. Three-Phase Refactoring Plan

### Phase 1: Type-Level Seams (Foundation)

**Objective**: Extract clean TypeScript interfaces that define boundaries between modules, so internal type changes don't leak across module borders.

#### 1.1 Create `src/orchestrator/read-models.ts`

Define **read-only interfaces** for all data that orchestrator modules consume from the store:

```typescript
// Read model interfaces — orchestrator never constructs these, only reads
export interface RunSummary {
  id: string;
  taskId: string;
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

export interface RunProgressSummary {
  currentPhase: string;
  phaseIndex: number;
  turnCount: number;
  lastHeartbeat: string;
}

export type RunStatus = "pending" | "running" | "completed" | "failed" | "stuck" | "merged" | "conflict" | "test-failed" | "pr-created" | "reset";
export type MergeStrategy = "auto" | "pr" | "none";
export type PrState = "none" | "draft" | "open" | "merged" | "closed";

// Read model interface — store implementations must satisfy this
export interface RunStoreReadModel {
  getRun(runId: string): Promise<RunSummary | null>;
  getRunsForTask(taskId: string): Promise<RunSummary[]>;
  getActiveRuns(projectId: string): Promise<RunSummary[]>;
  getRunsByStatus(status: RunStatus, projectId: string): Promise<RunSummary[]>;
}
```

#### 1.2 Create `src/orchestrator/write-models.ts`

Define **write intent interfaces** for mutations the orchestrator performs:

```typescript
export interface RunCommands {
  updateStatus(runId: string, status: RunStatus): Promise<void>;
  setProgress(runId: string, progress: string): Promise<void>;
  logEvent(runId: string, projectId: string, eventType: string, payload: Record<string, unknown>): Promise<void>;
}

export interface RunFactory {
  createRun(args: {
    runId: string;
    projectId: string;
    taskId: string;
    agentType: string;
    branchName: string;
    worktreePath: string | null;
    baseBranch?: string | null;
    mergeStrategy?: MergeStrategy;
  }): Promise<RunSummary>;
}
```

#### 1.3 Update `src/orchestrator/types.ts`

- Remove direct imports of `Run`, `RunProgress`, `ForemanStore` from `../lib/store.js`
- Import from `read-models.ts` and `write-models.ts` instead
- Keep `ModelSelection`, `AgentRole`, `DispatchResult` etc. that are truly internal to orchestrator

**Before**:
```typescript
import type { ForemanStore, RunProgress } from "../lib/store.js";
```

**After**:
```typescript
import type { RunSummary, RunProgressSummary, RunStoreReadModel } from "./read-models.js";
```

#### 1.4 Update `src/orchestrator/pipeline-executor.ts`

- Replace `ForemanStore` usage with `RunStoreReadModel` where only reads occur
- Keep `ForemanStore` only where writes are necessary (via `RunCommands`)

#### 1.5 Update `src/orchestrator/agent-worker.ts`

- Same pattern: use `RunStoreReadModel` for read-only access
- Use `RunCommands` for mutations

---

### Phase 2: Read Model Implementations

**Objective**: Provide store-agnostic read model implementations so callers don't depend on concrete store types.

#### 2.1 Create `src/orchestrator/store-read-model-adapter.ts`

Adapter that wraps `ForemanStore` and exposes `RunStoreReadModel`:

```typescript
export class ForemanStoreReadModelAdapter implements RunStoreReadModel {
  constructor(private store: ForemanStore) {}
  
  async getRun(runId: string): Promise<RunSummary | null> {
    const run = await this.store.getRun(runId);
    return run ? mapRunToSummary(run) : null;
  }
  
  async getRunsForTask(taskId: string): Promise<RunSummary[]> {
    const runs = await this.store.getRunsForTask(taskId);
    return runs.map(mapRunToSummary);
  }
  // ...
}
```

#### 2.2 Update `dispatcher.ts`

- Accept `RunStoreReadModel` and `RunCommands` via constructor injection or function parameters
- Remove direct `ForemanStore` instantiation
- Remove imports of concrete store types; use interfaces only

---

### Phase 3: Dispatcher Dependency Narrowing

**Objective**: Reduce `dispatcher.ts` imports from 35+ to a stable set of interface-only dependencies.

#### 3.1 Create `src/orchestrator/dispatcher-dependencies.ts`

Facade that encapsulates all dispatcher dependencies:

```typescript
export interface DispatcherDeps {
  taskClient: ITaskClient;
  storeReadModel: RunStoreReadModel;
  runCommands: RunCommands;
  runFactory: RunFactory;
  vcsBackend: VcsBackend;
  projectConfig: ProjectConfig;
  workflowConfig: WorkflowConfig;
  // ... rest of minimal interface surface
}
```

#### 3.2 Update `dispatcher.ts`

**Before** (representative imports):
```typescript
import { PostgresStore } from "../lib/postgres-store.js";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import { initPool } from "../lib/db/pool-manager.js";
import { PIPELINE_TIMEOUTS, getDefaultModel } from "../lib/config.js";
import { loadProjectConfig, resolveVcsConfig } from "../lib/project-config.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";
// ... 30+ more imports
```

**After**:
```typescript
import type { DispatcherDeps } from "./dispatcher-dependencies.js";
// Dependencies injected via constructor or context
```

#### 3.3 Update `agent-worker.ts`

- Accept `DispatcherDeps` and pass to `Dispatcher` constructor
- `Dispatcher` no longer imports concrete lib modules directly

---

## 3. Files to Change

| File | Change |
|------|--------|
| `src/orchestrator/read-models.ts` | **NEW** — Read model interfaces |
| `src/orchestrator/write-models.ts` | **NEW** — Write intent interfaces |
| `src/orchestrator/store-read-model-adapter.ts` | **NEW** — ForemanStore → read model adapter |
| `src/orchestrator/dispatcher-dependencies.ts` | **NEW** — Dependency facade |
| `src/orchestrator/types.ts` | Remove store imports, use read-model types |
| `src/orchestrator/pipeline-executor.ts` | Use `RunStoreReadModel` for reads |
| `src/orchestrator/agent-worker.ts` | Use read models, remove direct store deps |
| `src/orchestrator/dispatcher.ts` | Accept injected deps, remove direct lib imports |
| `src/lib/store.ts` | Keep concrete impl; read models defined in orchestrator |

---

## 4. Files NOT to Change (Preserve Behavior)

- `src/lib/postgres-store.ts` — concrete implementation unchanged
- `src/lib/db/postgres-adapter.ts` — concrete implementation unchanged
- `src/lib/db/pool-manager.ts` — concrete implementation unchanged
- `src/lib/beads-rust.ts` — unchanged
- `src/lib/vcs/*.ts` — unchanged

---

## 5. Verification Criteria

1. **Type check passes**: `npx tsc --noEmit` succeeds with no errors
2. **All tests pass**: `npm test` passes before and after changes
3. **No new runtime behavior**: All existing functionality preserved
4. **Interface segregation verified**: `dispatcher.ts` imports only:
   - Types from `read-models.ts`, `write-models.ts`, `dispatcher-dependencies.ts`
   - Pure utility functions (no store, db, or config classes)
5. **Adapter pattern verified**: `ForemanStoreReadModelAdapter` implements `RunStoreReadModel` correctly

---

## 6. Risk & Constraints

- **Backward compatibility**: Store schema unchanged; adapters map existing fields
- **No feature changes**: This is a pure refactor — no new features or behavior
- **Minimal surface area**: Each new file has a single responsibility
- **Testing strategy**: Existing tests should pass without modification; adapter tested via integration tests