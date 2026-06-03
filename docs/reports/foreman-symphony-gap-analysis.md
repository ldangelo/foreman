# Foreman vs Symphony Specification Gap Analysis

**Spec Reference:** Symphony Service Specification v1 (language-agnostic)
**Analysis Date:** 2026-06-02
**Foreman Branch:** main

## Executive Summary

Foreman and Symphony share the same high-level goal: orchestrating coding agents to get project work done from issue trackers. However, they take fundamentally different architectural approaches:

- **Symphony** is a dedicated workflow orchestrator that polls Linear, manages per-issue workspaces, and runs Codex sessions with JSON-RPC protocol.
- **Foreman** is a multi-agent orchestration system with VCS-aware workflows, supporting multiple trackers (GitHub, Jira) and VCS backends (Git, Jujutsu).

### Architectural Difference

| Aspect | Symphony | Foreman |
|--------|----------|---------|
| Primary focus | Linear polling + Codex session runner | Multi-agent VCS workflows |
| Tracker support | Linear only | GitHub, Jira |
| VCS backend | Not specified | Git, Jujutsu |
| Agent protocol | Codex app-server (JSON-RPC) | Foreman's own agent protocol |
| Config format | WORKFLOW.md (Markdown + YAML) | YAML (.yaml files) |
| State persistence | In-memory only | PostgreSQL/Postgres |

## Detailed Gap Analysis

---

### 1. Orchestrator State & Scheduling

**Spec Sections:** 7. Orchestration State Machine, 8. Polling, Scheduling, Reconciliation

#### Implemented Well
- ✅ Issue polling on fixed cadence with bounded concurrency (`JiraIssuesPoller`)
- ✅ In-memory state with DB persistence (running seeds, debounce state)
- ✅ Per-issue workspace management via `WorktreeManager`
- ✅ Exponential backoff for stuck issues (`STUCK_RETRY_CONFIG`)
- ✅ Global concurrency control via `maxAgents`

#### Partial Implementation
- ⚠️ Retry queue is per-seed, not centralized (no unified `retry_attempts` map)
- ⚠️ No per-state concurrency limits (`max_concurrent_agents_by_state`)

#### Missing
- ❌ **Reconciliation:** No systematic stop of runs when issue state changes to terminal/non-active
- ❌ **State machine:** No structured orchestrator state (Unclaimed/Claimed/Running/RetryQueued/Released)
- ❌ **Stall detection:** No `codex.stall_timeout_ms` implementation
- ❌ **Continuation retry:** No 1s fixed delay after clean worker exit to re-check issue state

---

### 2. Workspace Management

**Spec Sections:** 9. Workspace Management and Safety

#### Implemented Well
- ✅ Per-issue workspace creation and reuse (`createWorkspace` in git/jj backends)
- ✅ Workspace path normalization and workspace root enforcement
- ✅ Workspace cleanup for terminal issues (`archiveWorktreeReports` + `removeWorkspace`)

#### Missing
- ❌ **Workspace lifecycle hooks:** No `after_create`, `before_run`, `after_run`, `before_remove`
- ❌ **Hook timeout handling:** No `hooks.timeout_ms`
- ❌ **Workspace key sanitization:** Only `[A-Za-z0-9._-]` allowed in directory names
- ❌ **Safety invariant validation:** No `cwd == workspace_path` check before agent launch

---

### 3. Issue Tracker Integration

**Spec Sections:** 11. Issue Tracker Integration Contract

#### Implemented Well
- ✅ Jira candidate issue fetching with state filtering
- ✅ Issue state fetching for individual issues
- ✅ Normalized `Issue` type with id, identifier, title, state, labels
- ✅ Rate-limit backoff on API errors

#### Partial Implementation
- ⚠️ No bulk fetch by IDs (reconciliation uses one-by-one `show()` calls)
- ⚠️ Priority mapping incomplete (not standardized to integer)

#### Missing
- ❌ **Startup cleanup:** No fetch terminal-state issues on startup for workspace cleanup
- ❌ **Blocked-by resolution:** No dependency/blocker tracking
- ❌ **Write operations:** `update`/`close` are stubs
- ❌ **Pagination:** No handling for large candidate sets

---

### 4. Workflow/Config System

**Spec Sections:** 5. Workflow Specification, 6. Configuration Specification

#### Implemented Well
- ✅ Typed config getters with validation
- ✅ Config validation before dispatch
- ✅ YAML workflow configuration
- ✅ Prompt template rendering with `{{key}}` substitution

#### Partial Implementation
- ⚠️ Workflow uses `.yaml` files, not `WORKFLOW.md` (no markdown + YAML front matter)

#### Missing
- ❌ **WORKFLOW.md parsing:** No YAML front matter + markdown body separation
- ❌ **Env var indirection:** No `$VAR_NAME` syntax in config
- ❌ **Dynamic reload:** No watching `WORKFLOW.md` for changes
- ❌ **Strict template engine:** No enforcement of unknown variables failing
- ❌ **Attempt metadata:** No `attempt` passed to template for retry/continuation guidance

---

### 5. Observability & Logging

**Spec Sections:** 13. Logging, Status, and Observability

#### Implemented Well
- ✅ Token/cost tracking in agent events
- ✅ Rate limit telemetry
- ✅ Run status management
- ✅ Human-readable CLI surfaces (status commands)
- ✅ Doctor checks for system health

#### Missing
- ❌ **Structured logging:** No `issue_id`/`issue_identifier` context fields
- ❌ **JSON logs:** No machine-readable log format
- ❌ **Runtime snapshot API:** No unified endpoint returning running/retrying/codex_totals
- ❌ **Session tracking:** No `session_id = thread_id-turn_id` composition

---

### 6. Agent Runner Protocol

**Spec Sections:** 10. Agent Runner Protocol

#### Not Implemented (Different Architecture)
- ❌ **Codex app-server integration:** Foreman uses its own agent protocol
  - No `initialize` → `initialized` handshake
  - No `thread/start` with `approvalPolicy`, `sandbox`, `cwd`
  - No `turn/start` with `threadId`, `input`, `title`, `sandboxPolicy`
- ❌ **Streaming turn processing:** No line-delimited JSON-RPC handling
- ❌ **Turn completion:** No `turn/completed`, `turn/failed`, `turn/cancelled` handling
- ❌ **Approval handling:** No `approval_auto_approved` mechanism
- ❌ **Client-side tools:** No `linear_graphql` extension

**Assessment:** This is an intentional architectural difference, not a gap. Foreman's agent protocol serves its multi-agent VCS workflow model.

---

### 7. Concurrency Control

**Spec Sections:** 8.3 Concurrency Control

#### Implemented Well
- ✅ Global concurrency limit (`maxAgents` in `Dispatcher`)

#### Missing
- ❌ **Per-state concurrency:** No `max_concurrent_agents_by_state` map
- ❌ **SSH host limits:** No `worker.max_concurrent_agents_per_host`

---

### 8. Retry Logic

**Spec Sections:** 8.4 Retry and Backoff

#### Implemented Well
- ✅ Exponential backoff for stuck seeds
- ✅ Max retry backoff capping

#### Missing
- ❌ **Continuation retry:** No 1s fixed delay after clean exit
- ❌ **Retry entry storage:** No `due_at_ms`, `timer_handle` tracking
- ❌ **Retry preflight:** No re-fetch candidates, find by ID, dispatch if eligible

---

## Gap Summary Matrix

| Category | Implemented | Partial | Missing |
|----------|-------------|---------|---------|
| Orchestrator State | 5 | 2 | 4 |
| Workspace Management | 3 | 0 | 4 |
| Issue Tracker | 4 | 2 | 4 |
| Workflow/Config | 4 | 1 | 5 |
| Observability | 5 | 0 | 4 |
| Agent Protocol | 0 | 1 | 8 |
| Concurrency | 1 | 0 | 2 |
| Retry Logic | 2 | 0 | 3 |

---

## Recommendations

### High Priority (Core Symphony Equivalents)

1. **Workspace Lifecycle Hooks**
   - Add `after_create`, `before_run`, `after_run`, `before_remove` hooks to `WorktreeManager`
   - Implement hook timeout handling with configurable `hooks.timeout_ms`

2. **Reconciliation**
   - Add systematic state refresh for running issues
   - Stop runs when issue transitions to terminal/non-active state

3. **Stall Detection**
   - Implement `stall_timeout_ms` based on agent event timestamps
   - Terminate stalled workers and schedule retry

4. **Structured Logging**
   - Add `issue_id`, `issue_identifier` context to all relevant logs
   - Add optional JSON log format for machine consumption

### Medium Priority (Feature Parity)

5. **Dynamic Config Reload**
   - Watch workflow files for changes
   - Re-apply config without restart

6. **Per-State Concurrency Limits**
   - Implement `max_concurrent_agents_by_state` map

7. **Continuation Retry**
   - Add 1s fixed delay after clean worker exit
   - Re-check issue state before scheduling retry

### Low Priority (Architectural Differences)

8. **WORKFLOW.md Format** - Major breaking change, low value vs current YAML
9. **Codex Protocol** - Different agent model, incompatible with Foreman's approach
10. **Env Var Indirection** - Can be added without breaking changes

---

## Conclusion

Foreman and Symphony are parallel solutions to similar problems with different design philosophies. Foreman excels at multi-agent VCS workflows with Git/Jujutsu support, while Symphony focuses on a streamlined Linear+Codex experience.

**Key Insight:** Foreman's architecture is more feature-rich but less aligned with the Symphony spec. The gaps are primarily in:
1. Workspace lifecycle hooks
2. Reconciliation/stop logic
3. Structured observability
4. Per-state concurrency

These are additive features that Foreman could implement without changing its core architecture.