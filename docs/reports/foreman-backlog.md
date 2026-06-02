# Foreman Backlog

**Created:** 2026-06-02
**Source:** Gap analyses vs Symphony and Sandcastle specifications

---

## Overview

This backlog captures improvements identified through competitive analysis against:
- [Symphony Service Specification](./foreman-symphony-gap-analysis.md)
- [Sandcastle (mattpocock/sandcastle)](./foreman-sandcastle-gap-analysis.md)

Items are prioritized by impact and estimated complexity.

---

## Priority 1: High Impact

### Backlog-001: Lifecycle Hooks
**Source:** Symphony 9.4, Sandcastle hooks system
**Status:** Not Started

**Description:**
Implement workspace lifecycle hooks for pre/post-run customization.

**Proposed API:**
```typescript
interface WorkspaceHooks {
  afterCreate?: string;   // One-time setup when workspace created
  beforeRun?: string;     // Run before agent launch
  afterRun?: string;      // Run after agent completes (success or failure)
  beforeRemove?: string;  // Run before workspace cleanup
  timeoutMs?: number;      // Default: 60000
}
```

**Environment variables:**
- `FOREMAN_WORKSPACE_PATH`
- `FOREMAN_ISSUE_ID`
- `FOREMAN_ISSUE_IDENTIFIER`
- `FOREMAN_ATTEMPT`

**Use cases:**
- Clone additional repos (`after_create`)
- Sync dependencies before run (`before_run`)
- Archive test results (`after_run`)
- Clean up external resources (`before_remove`)

**Effort:** Medium
**Dependencies:** None

---

### Backlog-002: Reconciliation - Stop Runs on Terminal State
**Source:** Symphony 8.5
**Status:** Not Started

**Description:**
Systematically stop agent runs when the underlying issue transitions to a terminal or inactive state.

**Current behavior:** Runs continue until completion even if the issue is closed.

**Proposed behavior:**
```typescript
// In dispatch loop
async reconcileRunningIssues(): Promise<void> {
  const activeRuns = await this.store.getActiveRuns();
  
  for (const run of activeRuns) {
    const issue = await this.seeds.getIssueById(run.seed_id);
    
    if (!issue || this.isTerminalState(issue.status)) {
      await this.cancelRun(run.id, 'issue_terminal');
      await this.archiveWorkspace(run.worktreePath);
    }
  }
}
```

**Effort:** Medium
**Dependencies:** Backlog-001 (hooks for cleanup)

---

### Backlog-003: Stall Detection
**Source:** Symphony 8.5
**Status:** Not Started

**Description:**
Detect and terminate agent sessions that have been idle for too long.

**Current behavior:** Stuck agents may run indefinitely.

**Proposed behavior:**
```typescript
const STALL_TIMEOUT_MS = 5 * 60 * 1000; // 5 minutes default

async checkForStalls(): Promise<void> {
  for (const run of await this.store.getActiveRuns()) {
    const lastEvent = run.lastEventAt ?? run.startedAt;
    
    if (Date.now() - lastEvent > STALL_TIMEOUT_MS) {
      await this.terminateRun(run.id, 'stalled');
      await this.scheduleRetry(run.id, 'stall');
    }
  }
}
```

**Effort:** Low
**Dependencies:** None

---

## Priority 2: Medium Impact

### Backlog-004: Structured Output Extraction
**Source:** Sandcastle structured output
**Status:** Not Started

**Description:**
Extract typed JSON payloads from agent output using schema validation.

**Proposed API:**
```typescript
import { z } from 'zod';

const result = await foreman.run({
  agent: 'claude',
  prompt: 'Analyze the code and output JSON inside <result> tags',
  output: {
    tag: 'result',
    schema: z.object({
      summary: z.string(),
      score: z.number(),
    }),
  },
});

console.log(result.output.summary); // typed
```

**Benefits:**
- Reliable downstream processing
- Agent can output complex data structures
- Schema validation catches errors early

**Effort:** Medium
**Dependencies:** None

---

### Backlog-005: Dynamic Command Expansion in Prompts
**Source:** Sandcastle `` !`command` ``
**Status:** Not Started

**Description:**
Allow prompts to execute shell commands and inject output.

**Proposed usage:**
```markdown
# In prompt template
## Issue Context

!`gh issue view {{ISSUE_NUMBER}} --json body,comments -q .`

## Recent Changes

!`git log --oneline -5`

## Current Branch Status

!`git status --short`
```

**Implementation:**
- Parse `` !`command` `` patterns in prompt
- Execute in workspace context
- Inject stdout into prompt
- Fail run if any command fails (or warn option)

**Effort:** Medium
**Dependencies:** None

---

### Backlog-006: Per-State Concurrency Limits
**Source:** Symphony 8.3
**Status:** Not Started

**Description:**
Support concurrency limits per issue state (e.g., max 2 "In Review" at once).

**Proposed config:**
```yaml
concurrency:
  global: 10
  byState:
    in_progress: 5
    review: 2
    qa: 3
```

**Effort:** Low
**Dependencies:** None

---

### Backlog-007: Dynamic Config Reload
**Source:** Symphony 6.2
**Status:** Not Started

**Description:**
Watch workflow files and reload configuration without restart.

**Current behavior:** Config changes require daemon restart.

**Proposed behavior:**
- File watcher on workflow YAML
- Debounced reload (500ms)
- Apply to next dispatch cycle
- Log on reload, continue with old config on failure

**Effort:** Medium
**Dependencies:** None

---

### Backlog-008: Init Wizard
**Source:** Sandcastle `sandcastle init`
**Status:** Not Started

**Description:**
Interactive setup command to initialize foreman projects.

**Proposed CLI:**
```bash
foreman init

# Steps:
# 1. Select VCS backend (git, jujutsu)
# 2. Configure issue tracker (jira, github, beads)
# 3. Select workflow template (plan-implement, parallel-review, etc.)
# 4. Authenticate to services
# 5. Generate initial config files
```

**Benefits:**
- Faster onboarding
- Fewer configuration errors
- Discoverability of features

**Effort:** Low
**Dependencies:** Template system for workflows

---

### Backlog-009: Startup Terminal Workspace Cleanup
**Source:** Symphony 8.6
**Status:** Not Started

**Description:**
Clean up workspaces for issues that are already in terminal state when daemon starts.

**Proposed behavior:**
```typescript
async startup(): Promise<void> {
  // ... existing startup ...
  
  // New: Cleanup terminal issue workspaces
  const terminalIssues = await this.seeds.getIssuesByStates([
    'Closed', 'Cancelled', 'Done', 'Duplicate'
  ]);
  
  for (const issue of terminalIssues) {
    await this.worktreeManager.removeIfExists(issue.identifier);
  }
}
```

**Effort:** Low
**Dependencies:** None

---

### Backlog-010: Structured Logging with Issue Context
**Source:** Symphony 13.1, Sandcastle observability
**Status:** Not Started

**Description:**
Standardize logging with consistent context fields.

**Proposed format:**
```json
{
  "level": "info",
  "timestamp": "2026-06-02T10:30:00.000Z",
  "message": "Dispatching task",
  "issueId": "ABC-123",
  "issueIdentifier": "ABC-123",
  "sessionId": "thread-abc-turn-1",
  "runId": "run-456",
  "attempt": 1
}
```

**Effort:** Low
**Dependencies:** None

---

## Priority 3: Lower Impact / Future

### Backlog-011: Container Sandboxing (Optional)
**Source:** Sandcastle Docker/Podman providers
**Status:** Not Started

**Description:**
Optional container isolation for untrusted workflows.

**Considerations:**
- Adds complexity
- Different use case than current worktree model
- Could integrate with Sandcastle as provider
- Not needed for trusted environments

**Effort:** High
**Dependencies:** Significant design work

---

### Backlog-012: Stream Event Callbacks
**Source:** Sandcastle `onAgentStreamEvent`
**Status:** Not Started

**Description:**
Allow custom observability by forwarding agent stream events.

**Proposed API:**
```typescript
await foreman.run({
  agent: 'claude',
  prompt: 'Fix the bug',
  onStreamEvent: (event) => {
    // event: { type: 'text' | 'toolCall', iteration, timestamp, ... }
    myLogger.info(event);
    metrics.record(event);
  },
});
```

**Effort:** Medium
**Dependencies:** Agent protocol support

---

### Backlog-013: Continuation Retry (1s delay after clean exit)
**Source:** Symphony 8.4
**Status:** Not Started

**Description:**
After a clean agent exit, re-check issue state before considering done.

**Current behavior:** Successful run = done.

**Proposed behavior:**
```typescript
async onRunCompleted(runId: string, success: boolean): Promise<void> {
  if (success) {
    const issue = await this.seeds.getIssueById(run.seed_id);
    
    if (issue && this.isActiveState(issue.status)) {
      // Schedule quick re-check in 1 second
      setTimeout(() => this.continuationCheck(runId, issue), 1000);
    }
  }
}
```

**Effort:** Medium
**Dependencies:** Reconciliation (Backlog-002)

---

## Not Applicable / Out of Scope

| Item | Reason |
|------|--------|
| Codex app-server protocol | Different agent model |
| WORKFLOW.md format | Breaking change, low value vs YAML |
| Env var indirection ($VAR) | Can add later if needed |
| Session resume (Sandcastle style) | Foreman uses persistent state differently |
| Merge-to-head branch strategy | Foreman already has rebase strategies |

---

## GitHub Issues

| ID | Issue | GitHub |
|----|-------|--------|
| 001 | Lifecycle Hooks | [#179](https://github.com/ldangelo/foreman/issues/179) |
| 002 | Reconciliation | [#180](https://github.com/ldangelo/foreman/issues/180) |
| 003 | Stall Detection | [#181](https://github.com/ldangelo/foreman/issues/181) |
| 004 | Structured Output | [#182](https://github.com/ldangelo/foreman/issues/182) |
| 005 | Dynamic Command Expansion | [#183](https://github.com/ldangelo/foreman/issues/183) |
| 006 | Per-State Concurrency | [#184](https://github.com/ldangelo/foreman/issues/184) |
| 007 | Dynamic Config Reload | [#185](https://github.com/ldangelo/foreman/issues/185) |
| 008 | Init Wizard | [#186](https://github.com/ldangelo/foreman/issues/186) |
| 009 | Startup Cleanup | [#187](https://github.com/ldangelo/foreman/issues/187) |
| 010 | Structured Logging | [#188](https://github.com/ldangelo/foreman/issues/188) |
| 011 | Container Sandboxing | [#189](https://github.com/ldangelo/foreman/issues/189) |
| 012 | Stream Event Callbacks | [#190](https://github.com/ldangelo/foreman/issues/190) |
| 013 | Continuation Retry | [#191](https://github.com/ldangelo/foreman/issues/191) |

---

## Priority Summary

| ID | Item | Impact | Effort | Priority |
|----|------|--------|--------|----------|
| 001 | Lifecycle Hooks | High | Medium | **P1** |
| 002 | Reconciliation | High | Medium | **P1** |
| 003 | Stall Detection | High | Low | **P1** |
| 004 | Structured Output | Medium | Medium | P2 |
| 005 | Dynamic Command Expansion | Medium | Medium | P2 |
| 006 | Per-State Concurrency | Medium | Low | P2 |
| 007 | Dynamic Config Reload | Medium | Medium | P2 |
| 008 | Init Wizard | Medium | Low | P2 |
| 009 | Startup Cleanup | Low | Low | P2 |
| 010 | Structured Logging | Medium | Low | P2 |
| 011 | Container Sandboxing | Low | High | P3 |
| 012 | Stream Event Callbacks | Low | Medium | P3 |
| 013 | Continuation Retry | Low | Medium | P3 |

---

## Changelog

| Date | Change |
|------|--------|
| 2026-06-02 | Initial backlog created from Symphony and Sandcastle gap analyses |
| 2026-06-02 | Added GitHub issues #179-#191 for all backlog items |