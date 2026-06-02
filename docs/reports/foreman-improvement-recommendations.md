# Foreman Improvement Recommendations (Based on Symphony Gap Analysis)

**Based on:** `docs/reports/foreman-symphony-gap-analysis.md`
**Date:** 2026-06-02

## Overview

These recommendations are **additive improvements** that don't require architectural changes to Foreman. They're ordered by impact (high to low) and include estimated complexity.

---

## Priority 1: High Impact, Moderate Complexity

### 1. Workspace Lifecycle Hooks

**Gap:** Symphony requires `after_create`, `before_run`, `after_run`, `before_remove` hooks. Foreman has none.

**Current State:** `WorktreeManager` creates/removes worktrees, but no hooks exist.

**Recommendation:**

```typescript
// src/lib/worktree-manager.ts additions

interface WorkspaceHooks {
  afterCreate?: string;   // shell script, runs only on new workspace
  beforeRun?: string;    // runs before agent launch
  afterRun?: string;     // runs after agent completes/fails
  beforeRemove?: string; // runs before workspace deletion
  timeoutMs?: number;    // default: 60000
}

interface WorkspaceContext {
  workspacePath: string;
  issueId: string;
  issueIdentifier: string;
  createdNow: boolean;
}

// Hook execution in createWorkspace:
async function runHook(hook: string, ctx: WorkspaceContext): Promise<void> {
  const timeout = this.config.hooks.timeoutMs ?? 60000;
  await execFileSync('bash', ['-lc', hook], {
    cwd: ctx.workspacePath,
    timeout,
    env: { ...process.env, 
           FOREMAN_WORKSPACE_PATH: ctx.workspacePath,
           FOREMAN_ISSUE_ID: ctx.issueId,
           FOREMAN_ISSUE_IDENTIFIER: ctx.issueIdentifier,
    }
  });
}
```

**Files to modify:** `src/lib/worktree-manager.ts`, `src/orchestrator/dispatcher.ts`

---

### 2. Reconciliation: Stop Runs on Terminal State

**Gap:** Symphony reconciles running issues against tracker state. Foreman doesn't systematically stop when issues become terminal.

**Current State:** Runs continue until completion, even if the underlying issue was closed.

**Recommendation:**

Add a `reconcileRunningIssues()` method to the dispatch loop:

```typescript
// In Dispatcher or a new ReconciliationService

async reconcileRunningIssues(): Promise<void> {
  const activeRuns = await this.store.getActiveRuns();
  
  for (const run of activeRuns) {
    const externalId = run.seed_id; // or separate field
    
    // Fetch current issue state
    const issue = await this.seeds.getIssueById(externalId);
    
    if (!issue) {
      // Issue deleted - cancel run
      await this.cancelRun(run.id, 'issue_deleted');
      continue;
    }
    
    if (this.isTerminalState(issue.status)) {
      // Issue closed/cancelled - cancel run
      await this.cancelRun(run.id, 'issue_terminal');
      continue;
    }
    
    if (!this.isActiveState(issue.status)) {
      // Issue in weird state - cancel without cleanup
      await this.cancelRun(run.id, 'issue_inactive');
      continue;
    }
  }
}

private isTerminalState(status: string): boolean {
  const terminalStates = ['Closed', 'Cancelled', 'Canceled', 'Done', 'Duplicate'];
  return terminalStates.includes(status);
}
```

**Files to modify:** `src/orchestrator/dispatcher.ts`, `src/lib/store.ts`

---

### 3. Stall Detection

**Gap:** Symphony detects stalls when `elapsed_ms > stall_timeout_ms`. Foreman doesn't implement this.

**Current State:** Stuck agent runs may run indefinitely.

**Recommendation:**

```typescript
// In dispatcher.ts - add to dispatch loop or separate monitor

interface RunningSession {
  runId: string;
  startedAt: Date;
  lastEventAt: Date | null;
  lastEventType: string | null;
}

const STALL_TIMEOUT_MS = 5 * 60 * 1000; // 5 minutes default

async checkForStalls(): Promise<void> {
  const activeRuns = await this.store.getActiveRuns();
  
  for (const run of activeRuns) {
    const session = await this.getSessionForRun(run.id);
    
    const lastEventTime = session.lastEventAt ?? run.started_at;
    const elapsedMs = Date.now() - new Date(lastEventTime).getTime();
    
    if (elapsedMs > STALL_TIMEOUT_MS) {
      console.log(`[stall-detector] Run ${run.id} stalled (${elapsedMs}ms since last event)`);
      await this.terminateRun(run.id, 'stalled');
      await this.scheduleRetry(run.id, 'stall');
    }
  }
}
```

**Files to modify:** `src/orchestrator/dispatcher.ts`, `src/lib/store.ts`

---

## Priority 2: Medium Impact, Lower Complexity

### 4. Structured Logging with Issue Context

**Gap:** Symphony requires `issue_id`, `issue_identifier`, `session_id` in all relevant logs.

**Current State:** Logs are ad-hoc, no consistent context fields.

**Recommendation:**

```typescript
// src/lib/logger.ts - new structured logger

interface LogContext {
  issueId?: string;
  issueIdentifier?: string;
  sessionId?: string;
  runId?: string;
  [key: string]: unknown;
}

class ForemanLogger {
  private context: LogContext = {};
  
  withContext(ctx: Partial<LogContext>): ForemanLogger {
    const child = new ForemanLogger();
    child.context = { ...this.context, ...ctx };
    return child;
  }
  
  info(message: string, data?: Record<string, unknown>): void {
    console.log(JSON.stringify({
      level: 'info',
      timestamp: new Date().toISOString(),
      message,
      ...this.context,
      ...data,
    }));
  }
  
  error(message: string, error?: Error, data?: Record<string, unknown>): void {
    console.error(JSON.stringify({
      level: 'error',
      timestamp: new Date().toISOString(),
      message,
      error: error?.message,
      stack: error?.stack,
      ...this.context,
      ...data,
    }));
  }
}

// Usage throughout codebase:
// const log = logger.withContext({ issueId, issueIdentifier });
// log.info('Dispatching task', { attempt: 1 });
```

**Files to create/modify:** `src/lib/logger.ts`, integrate into existing modules

---

### 5. Per-State Concurrency Limits

**Gap:** Symphony supports `max_concurrent_agents_by_state`. Foreman only has global `maxAgents`.

**Current State:** All states share the same concurrency pool.

**Recommendation:**

```typescript
// In Dispatcher.dispatch()

interface ConcurrencyConfig {
  global: number;
  byState?: Record<string, number>;  // e.g., { "in progress": 3, "review": 2 }
}

async dispatch(opts?: { concurrency?: ConcurrencyConfig }): Promise<DispatchResult> {
  const concurrency = opts?.concurrency ?? { global: 5 };
  const stateLimits = concurrency.byState ?? {};
  
  // Count running by state
  const runningByState = new Map<string, number>();
  for (const run of activeRuns) {
    const state = await this.getSeedState(run.seed_id);
    runningByState.set(state, (runningByState.get(state) ?? 0) + 1);
  }
  
  // Check per-state limit before global
  const stateLimit = stateLimits[normalizeState(seed.status)] ?? concurrency.global;
  const stateRunning = runningByState.get(seed.status) ?? 0;
  
  if (stateRunning >= stateLimit) {
    skipped.push({ seedId: seed.id, reason: `State limit reached (${stateLimit})` });
    continue;
  }
}
```

**Files to modify:** `src/orchestrator/dispatcher.ts`, `src/lib/config.ts`

---

### 6. Dynamic Config Reload

**Gap:** Symphony watches `WORKFLOW.md` for changes. Foreman requires restart.

**Current State:** Config changes require service restart.

**Recommendation:**

```typescript
// src/lib/config-watcher.ts - new file

import { watch } from 'fs';

class ConfigWatcher {
  private watchers: Map<string, fs.FSWatcher> = new Map();
  private listeners: Map<string, Set<() => void>> = new Map();
  
  watch(filePath: string, callback: () => void): void {
    if (!this.listeners.has(filePath)) {
      this.listeners.set(filePath, new Set());
      
      const watcher = watch(filePath, () => {
        // Debounce: wait 500ms for multiple changes
        setTimeout(() => {
          const handlers = this.listeners.get(filePath);
          handlers?.forEach(h => h());
        }, 500);
      });
      
      this.watchers.set(filePath, watcher);
    }
    
    this.listeners.get(filePath)!.add(callback);
  }
  
  // In Dispatcher:
  async start(): Promise<void> {
    this.configWatcher.watch(workflowPath, async () => {
      console.log('[config] Workflow file changed, reloading...');
      try {
        const newConfig = await loadWorkflowConfig(workflowPath);
        this.workflowConfig = newConfig;
        // Config changes apply to next dispatch cycle
      } catch (err) {
        console.error('[config] Failed to reload, using previous config:', err);
      }
    });
  }
}
```

**Files to create:** `src/lib/config-watcher.ts`

---

## Priority 3: Lower Impact, Higher Complexity

### 7. Continuation Retry (1s delay after clean exit)

**Gap:** Symphony schedules a 1s retry after clean worker exit to re-check issue state.

**Current State:** Clean exits don't automatically re-check; requires manual reset.

**Recommendation:**

```typescript
// In dispatcher.ts - add continuation retry after successful run

async onRunCompleted(runId: string, outcome: 'success' | 'failed'): Promise<void> {
  const run = await this.store.getRun(runId);
  
  if (outcome === 'success') {
    // Check if issue is still active - if so, might need continuation
    const issue = await this.seeds.getIssueById(run.seed_id);
    
    if (issue && this.isActiveState(issue.status)) {
      // Schedule quick re-check in 1 second
      setTimeout(() => {
        this.continuationCheck(runId, issue);
      }, 1000);
    }
  }
}

async continuationCheck(runId: string, issue: Issue): Promise<void> {
  // Re-fetch issue state
  const currentIssue = await this.seeds.getIssueById(issue.id);
  
  if (!currentIssue) {
    console.log(`[continuation] Issue ${issue.id} deleted, not resuming`);
    return;
  }
  
  if (!this.isActiveState(currentIssue.status)) {
    console.log(`[continuation] Issue ${issue.id} no longer active (${currentIssue.status}), not resuming`);
    return;
  }
  
  // Issue still active - could auto-continue or notify
  console.log(`[continuation] Issue ${issue.id} still active, consider resuming`);
  // Implementation decision: auto-resume vs manual trigger
}
```

---

### 8. Startup Terminal Workspace Cleanup

**Gap:** Symphony cleans up workspaces for terminal-state issues on startup.

**Current State:** Stale workspaces may accumulate across restarts.

**Recommendation:**

```typescript
// In daemon/index.ts or Dispatcher constructor

async startupTerminalCleanup(): Promise<void> {
  console.log('[startup] Checking for terminal issues to clean up workspaces...');
  
  try {
    const terminalIssues = await this.seeds.getIssuesByStates([
      'Closed', 'Cancelled', 'Canceled', 'Done', 'Duplicate'
    ]);
    
    for (const issue of terminalIssues) {
      const workspace = this.worktreeManager.getWorkspacePath(issue.identifier);
      
      if (existsSync(workspace)) {
        console.log(`[startup] Removing stale workspace for terminal issue ${issue.identifier}`);
        await this.worktreeManager.removeWorkspace(issue.identifier);
      }
    }
    
    console.log(`[startup] Cleaned ${terminalIssues.length} terminal issue workspaces`);
  } catch (err) {
    console.warn('[startup] Terminal cleanup failed, continuing anyway:', err);
  }
}
```

---

## Not Recommended (Architectural Mismatch)

These are intentionally not recommended because they conflict with Foreman's design:

### ❌ Codex App-Server Protocol

Foreman's agent protocol is fundamentally different. Implementing Codex's JSON-RPC would require a parallel system or complete rewrite.

### ❌ WORKFLOW.md Format

Moving from YAML to Markdown+YAML-frontmatter would be a breaking change with low value. Current YAML structure works well.

### ❌ Env Var Indirection ($VAR_NAME)

Can be added later without major changes, but adds complexity. Current env var resolution in `config.ts` is sufficient.

---

## Implementation Priority

| # | Improvement | Impact | Complexity | Recommendation |
|---|-------------|--------|------------|----------------|
| 1 | Workspace Hooks | High | Medium | **Implement** |
| 2 | Reconciliation | High | Medium | **Implement** |
| 3 | Stall Detection | High | Low | **Implement** |
| 4 | Structured Logging | Medium | Low | **Implement** |
| 5 | Per-State Concurrency | Medium | Low | **Implement** |
| 6 | Dynamic Config Reload | Medium | Medium | Consider |
| 7 | Continuation Retry | Low | Medium | Low priority |
| 8 | Startup Cleanup | Low | Low | Nice to have |

---

## Next Steps

1. **Workspace Hooks** is the most impactful missing feature from Symphony
2. **Reconciliation** is critical for operational correctness
3. **Stall Detection** is low-hanging fruit that prevents runaway processes

Recommend starting with these three for the next sprint.