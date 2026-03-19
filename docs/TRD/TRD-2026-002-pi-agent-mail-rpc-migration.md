# TRD-2026-002: Pi + Agent Mail + RPC Migration

**Document ID:** TRD-2026-002
**Version:** 1.0
**Status:** Draft
**Date:** 2026-03-19
**PRD Reference:** PRD-2026-002 v1.2
**Author:** Tech Lead (AI-assisted)

---

## Version History

| Version | Date       | Author    | Changes       |
|---------|------------|-----------|---------------|
| 1.0     | 2026-03-19 | Tech Lead | Initial draft |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Architecture](#2-system-architecture)
3. [Data Architecture](#3-data-architecture)
4. [Master Task List](#4-master-task-list)
5. [Sprint Planning](#5-sprint-planning)
6. [Quality Requirements](#6-quality-requirements)
7. [Acceptance Criteria Traceability](#7-acceptance-criteria-traceability)
8. [Technical Decisions](#8-technical-decisions)

---

## 1. Executive Summary

This TRD translates PRD-2026-002 into an implementable plan for migrating Foreman's agent runtime from Claude SDK `query()` + tmux/detached spawn to Pi RPC-controlled sessions with Agent Mail messaging. The migration spans 4 phases over 8 weeks, producing 68 implementation tasks plus their paired test tasks.

**Key architectural changes:**
- New `PiRpcSpawnStrategy` that communicates with Pi via JSONL over stdin/stdout
- Three Pi extensions (`foreman-tool-gate`, `foreman-budget`, `foreman-audit`) packaged as a separate npm workspace
- Agent Mail client for inter-phase messaging, file reservations, and audit trail
- Pi Merge Agent daemon for automated branch merging (follows SentinelAgent pattern)
- Graceful fallback to `DetachedSpawnStrategy` when Pi is not installed

**Current architecture touchpoints (from codebase analysis):**

| Component | File | Impact |
|-----------|------|--------|
| Spawn strategy selection | `src/orchestrator/dispatcher.ts:808-829` | Add PiRpcSpawnStrategy to selection chain |
| SDK query() calls | `src/orchestrator/agent-worker.ts:17` | Replace with Pi RPC session management |
| Tool restrictions | `src/orchestrator/roles.ts:99-102` | Move enforcement to foreman-tool-gate extension |
| Budget enforcement | `src/orchestrator/roles.ts:164-201` | Move to foreman-budget extension |
| Model selection | `src/orchestrator/roles.ts:112-137` | Relax ModelSelection type for Pi multi-provider |
| Notifications | `src/orchestrator/notification-server.ts`, `notification-bus.ts` | Deprecate; replace with Agent Mail |
| Messages table | `src/lib/store.ts:242-261` | Superseded by Agent Mail; keep for fallback |
| Merge | `src/orchestrator/refinery.ts:366-583` | Extract reusable functions for merge daemon |
| Sentinel pattern | `src/orchestrator/sentinel.ts:42-282` | Follow for merge agent daemon design |

---

## 2. System Architecture

### 2.1 Component Diagram

```
Foreman CLI (commander)
  |
  |-- Dispatcher
  |     |
  |     |-- spawnWorkerProcess() -- strategy selection:
  |     |     1. Pi available?  -> PiRpcSpawnStrategy [NEW]
  |     |     2. Pi spawn fail? -> DetachedSpawnStrategy (fallback)
  |     |     3. Pi absent?     -> DetachedSpawnStrategy (direct)
  |     |
  |     |-- PiRpcSpawnStrategy [NEW]
  |     |     |-> spawn('pi', ['--mode', 'rpc', '--extensions', 'foreman-ext'])
  |     |     |-> JSONL stdin:  { cmd: "prompt" | "set_model" | "set_context" | ... }
  |     |     |-> JSONL stdout: { event: "tool_call" | "turn_end" | "agent_end" | ... }
  |     |     |-> Session lifecycle: reuse | resume (switch_session) | fork
  |     |
  |     |-- DetachedSpawnStrategy (existing, unchanged)
  |     |-- TmuxSpawnStrategy (existing, deprecated)
  |
  |-- Agent Mail Client [NEW]
  |     |-> HTTP client to mcp_agent_mail FastMCP server (port 8765)
  |     |-> register_agent, send_message, fetch_inbox, file_reservation_paths
  |     |-> Fire-and-forget: failures silently ignored, disk-file fallback
  |
  |-- Pi Merge Agent Daemon [NEW]
  |     |-> Follows SentinelAgent pattern (timer-based loop, start/stop, PID in SQLite)
  |     |-> Polls Agent Mail for "branch-ready" messages
  |     |-> Drives T1-T4 merge tiers via extracted Refinery functions
  |     |-> Lock file (~/.foreman/merge.lock) yields to manual foreman merge
  |
  |-- ForemanStore (SQLite) -- existing, extended with merge_agent_configs table
  |-- NotificationServer/Bus -- existing, marked @deprecated
  |
packages/foreman-pi-extensions/ [NEW]
  |-- foreman-tool-gate.ts   -- hooks tool_call, blocks per-phase disallowed tools
  |-- foreman-budget.ts      -- hooks turn_end, enforces turn/token limits
  |-- foreman-audit.ts       -- hooks all events, writes audit trail
```

### 2.2 Data Flow: Pi RPC Pipeline

```
Foreman Dispatcher
  |
  |-- 1. createWorktree(projectPath, seedId)
  |-- 2. workerAgentMd(seed, worktreePath) -> TASK.md
  |-- 3. store.createRun(projectId, seedId, model, worktreePath)
  |-- 4. PiRpcSpawnStrategy.spawn(config)
  |       |
  |       |-- spawn('pi', ['--mode', 'rpc', '--extensions', extensionPath])
  |       |     cwd: worktreePath
  |       |     env: FOREMAN_PHASE, FOREMAN_ALLOWED_TOOLS, FOREMAN_MAX_TURNS,
  |       |          FOREMAN_MAX_TOKENS, FOREMAN_RUN_ID, FOREMAN_SEED_ID,
  |       |          FOREMAN_BASH_BLOCKLIST
  |       |
  |       |-- stdin << { cmd: "prompt", text: explorerPrompt(...) }
  |       |-- stdin << { cmd: "set_model", model: "claude-haiku-4-5-20251001" }
  |       |
  |       |-- stdout >> { event: "tool_call", toolName: "Read", ... }
  |       |     |-> foreman-tool-gate: allowed? -> proceed
  |       |     |-> foreman-audit: log to JSONL / Agent Mail
  |       |
  |       |-- stdout >> { event: "turn_end", turnNumber: 30, ... }
  |       |     |-> foreman-budget: limit reached? -> terminate
  |       |     |-> foreman-audit: log usage
  |       |
  |       |-- stdout >> { event: "agent_end", ... }
  |       |     |-> Update RunProgress in SQLite
  |       |     |-> Phase transition: set new env vars, send new prompt
  |       |     |-> OR: fork session for Dev<->QA retry
  |       |
  |       |-- Phase transitions (configurable via FOREMAN_PI_SESSION_STRATEGY):
  |       |     reuse:  same Pi process, set_model + set_context
  |       |     resume: new Pi process, switch_session
  |       |     fork:   same Pi process, fork command (preferred for Dev<->QA)
  |       |
  |       |-- On complete: git add/commit/push, br close, enqueue merge
  |
  |-- 5. Agent Mail sends (fire-and-forget):
  |       |-> register_agent("{role}-{seedId}")
  |       |-> send_message(report content, to: next-phase inbox)
  |       |-> send_message("branch-ready", to: "merge-agent")
  |
  |-- 6. Pi Merge Agent (daemon):
        |-> fetch_inbox("merge-agent")
        |-> For each branch-ready: Refinery.mergeOne(branch)
        |-> T1/T2: programmatic merge
        |-> T3/T4: spawn Pi RPC for AI conflict resolution
        |-> Result: merged | pr-created | failed
```

### 2.3 Fallback Behavior

When Pi is not installed or PiRpcSpawnStrategy.spawn() fails:

```
spawnWorkerProcess(config)
  |-- isPiAvailable() -> false
  |     |-> DetachedSpawnStrategy.spawn(config)
  |           |-> existing behavior: tsx agent-worker.ts <configPath>
  |           |-> SDK query() calls per phase
  |           |-> All SQLite updates, br operations, notifications preserved
  |
  |-- isPiAvailable() -> true, but spawn fails
        |-> log warning
        |-> DetachedSpawnStrategy.spawn(config) -- identical fallback
```

---

## 3. Data Architecture

### 3.1 New SQLite Tables

```sql
-- Merge Agent daemon configuration (follows sentinel_configs pattern)
CREATE TABLE IF NOT EXISTS merge_agent_configs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL UNIQUE,
  poll_interval_seconds INTEGER DEFAULT 10,
  max_retries INTEGER DEFAULT 2,
  enabled INTEGER DEFAULT 1,
  pid INTEGER DEFAULT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (project_id) REFERENCES projects(id)
);

-- Audit entries (Phase 1: local JSONL fallback index; Phase 3: Agent Mail primary)
CREATE TABLE IF NOT EXISTS audit_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  seed_id TEXT NOT NULL,
  phase TEXT NOT NULL,
  event_type TEXT NOT NULL,
  tool_name TEXT,
  details TEXT,
  blocked INTEGER DEFAULT 0,
  block_reason TEXT,
  timestamp TEXT NOT NULL,
  FOREIGN KEY (run_id) REFERENCES runs(id)
);
CREATE INDEX IF NOT EXISTS idx_audit_run ON audit_entries (run_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_audit_seed ON audit_entries (seed_id, phase);
```

### 3.2 Modified Types

```typescript
// types.ts -- extend RuntimeSelection
type RuntimeSelection = "claude-code" | "pi-rpc";

// roles.ts -- extend RoleConfig
interface RoleConfig {
  // ... existing fields ...
  maxTurns: number;    // NEW: turn limit for foreman-budget
  maxTokens: number;   // NEW: token limit for foreman-budget
}

// types.ts -- relax ModelSelection
type ModelSelection = string;  // Was: "claude-opus-4-6" | "claude-sonnet-4-6" | "claude-haiku-4-5-20251001"
// Defaults remain Anthropic model strings; Pi resolves provider from identifier
```

### 3.3 Extension Environment Variables

| Variable | Set By | Read By | Example |
|----------|--------|---------|---------|
| `FOREMAN_PHASE` | Dispatcher/PiRpcSpawnStrategy | foreman-tool-gate, foreman-audit | `explorer` |
| `FOREMAN_ALLOWED_TOOLS` | Dispatcher (from ROLE_CONFIGS) | foreman-tool-gate | `Read,Grep,Glob,Write` |
| `FOREMAN_MAX_TURNS` | Dispatcher (from ROLE_CONFIGS) | foreman-budget | `30` |
| `FOREMAN_MAX_TOKENS` | Dispatcher (from ROLE_CONFIGS) | foreman-budget | `100000` |
| `FOREMAN_RUN_ID` | Dispatcher | foreman-audit | `uuid` |
| `FOREMAN_SEED_ID` | Dispatcher | foreman-audit | `bd-1234` |
| `FOREMAN_BASH_BLOCKLIST` | Operator (optional) | foreman-tool-gate | `rm -rf /,git push --force` |
| `FOREMAN_PI_SESSION_STRATEGY` | Operator (optional) | PiRpcSpawnStrategy | `reuse\|resume\|fork` |
| `FOREMAN_SPAWN_STRATEGY` | Operator (optional) | spawnWorkerProcess | `pi-rpc\|tmux\|detached` |

### 3.4 Agent Mail Message Schema

```typescript
// Phase handoff message
interface PhaseHandoffMessage {
  type: "phase-report";
  runId: string;
  seedId: string;
  fromPhase: AgentRole;
  toPhase: AgentRole;
  subject: string;       // e.g. "Explorer Report"
  body: string;          // Report content (GFM markdown)
  metadata: {
    verdict?: Verdict;   // For QA/Reviewer reports
    retryCount?: number; // For Dev<->QA retries
  };
}

// Branch-ready message
interface BranchReadyMessage {
  type: "branch-ready";
  runId: string;
  seedId: string;
  branchName: string;
  commitHash: string;
}

// Audit entry message
interface AuditEntryMessage {
  type: "audit-entry";
  runId: string;
  seedId: string;
  phase: string;
  eventType: string;
  toolName?: string;
  details: Record<string, unknown>;
  blocked?: boolean;
  blockReason?: string;
  timestamp: string;
}
```

---

## 4. Master Task List

### Phase 1: Pi Extension Package (P0) -- Week 1-2

#### TRD-001: Extension Package Scaffolding (2h) [satisfies REQ-013] [satisfies ARCH]
Set up the npm workspace package at `packages/foreman-pi-extensions/` with package.json, tsconfig.json, vitest config, and ESM output configuration.

**Validates PRD ACs:** AC-013-1, AC-013-2
**Implementation AC:**
- [ ] Given the project root, when `npm install` is run, then the workspace package at `packages/foreman-pi-extensions/` is recognized and its dependencies are installed
- [ ] Given the extension package, when `npm run build` is run from the package directory, then it produces ESM-compatible `.js` output under `dist/`
- [ ] Given tsconfig.json in the extension package, when TypeScript compiles, then strict mode is enabled with no `any` escape hatches
- [ ] Given the extension package, when vitest is configured, then test files in `__tests__/` are discovered and runnable

#### TRD-001-TEST: Extension Package Scaffolding Tests (1h) [verifies TRD-001] [satisfies REQ-013] [depends: TRD-001]
Verify workspace build, ESM output, and strict mode compilation.

**Validates PRD ACs:** AC-013-1, AC-013-2
**Implementation AC:**
- [ ] Given the workspace setup, when `npm run build` is run from project root, then the extension package compiles without errors
- [ ] Given the built output, when a test imports from the package, then ESM imports resolve correctly

---

#### TRD-002: Pi Extension Type Definitions (2h) [satisfies ARCH]
Create TypeScript type definitions for the Pi extension API based on pi-mono reference: `ToolCallEvent`, `TurnEndEvent`, `ExtensionContext`, `ExtensionResult` (with `{ block: true, reason: string }`), and the extension registration interface.

**Validates PRD ACs:** (none directly -- infrastructure for AC-003-*, AC-004-*, AC-005-*)
**Implementation AC:**
- [ ] Given the Pi extension API from pi-mono, when types are defined, then `ToolCallEvent` includes `toolName: string` and `input: { command?: string; [key: string]: unknown }`
- [ ] Given the `tool_call` hook, when the return type is defined, then it includes `{ block: true; reason: string } | undefined`
- [ ] Given `ExtensionContext`, when defined, then it includes `getContextUsage(): { totalTokens: number; inputTokens: number; outputTokens: number }`

[depends: TRD-001]

---

#### TRD-003: foreman-tool-gate Extension (4h) [satisfies REQ-003] [satisfies REQ-018]
Implement the `foreman-tool-gate` Pi extension that hooks `tool_call` events and blocks tools not in the phase's allowed list. Extends pi-mono `permission-gate.ts` and `protected-paths.ts` patterns. Reads `FOREMAN_ALLOWED_TOOLS` and `FOREMAN_BASH_BLOCKLIST` from env vars. Protects `.beads/` directory. Blocks `git push --force`.

**Validates PRD ACs:** AC-003-1, AC-003-2, AC-003-3, AC-003-4, AC-003-5, AC-003-6, AC-018-1, AC-018-2
**Implementation AC:**
- [ ] Given `FOREMAN_PHASE=explorer` and `FOREMAN_ALLOWED_TOOLS=Read,Grep,Glob`, when Pi invokes `Bash`, then the extension returns `{ block: true, reason: "Tool Bash not allowed in explorer phase" }`
- [ ] Given `FOREMAN_PHASE=explorer`, when Pi invokes `Read`, then the extension returns `undefined` (allow)
- [ ] Given `FOREMAN_PHASE=developer` and `FOREMAN_ALLOWED_TOOLS=Read,Write,Edit,Bash,Grep,Glob`, when Pi invokes `Write`, then the extension allows the call
- [ ] Given `FOREMAN_BASH_BLOCKLIST=rm -rf /,git push --force,chmod 777`, when Pi invokes `Bash` with command `git push --force origin main`, then the extension blocks with reason identifying the matched pattern
- [ ] Given the default blocklist, when Pi invokes `Bash` with command `npm test`, then the extension allows the call
- [ ] Given any tool call is blocked, when the block occurs, then an audit callback is invoked with tool name, phase, and denial reason
- [ ] Given a tool call with a canonical name `Bash`, when an alias is attempted, then the extension checks against the canonical name
- [ ] Given any phase, when Pi invokes `Write` targeting `.beads/` directory, then the extension blocks the call

[depends: TRD-002]

#### TRD-003-TEST: foreman-tool-gate Tests (3h) [verifies TRD-003] [satisfies REQ-003] [satisfies REQ-018] [depends: TRD-003]
Unit tests for all tool-gate scenarios: phase-based blocking, bash blocklist, canonical name enforcement, .beads/ protection.

**Validates PRD ACs:** AC-003-1, AC-003-2, AC-003-3, AC-003-4, AC-003-5, AC-003-6, AC-018-1, AC-018-2
**Implementation AC:**
- [ ] Given test fixtures for Explorer phase config, when tool_call events are simulated for Bash/Write/Edit, then all are blocked
- [ ] Given test fixtures for Explorer phase config, when tool_call events are simulated for Read/Grep/Glob, then all are allowed
- [ ] Given test fixtures for Developer phase config, when tool_call events are simulated for all developer tools, then all are allowed
- [ ] Given a Bash command matching the blocklist, when the tool_call hook fires, then the block reason includes the matched pattern
- [ ] Given a Bash command not in the blocklist, when the tool_call hook fires, then the call is allowed
- [ ] Given a custom `FOREMAN_BASH_BLOCKLIST` value, when loaded, then the custom patterns are used instead of defaults
- [ ] Given coverage measurement, when tests complete, then coverage for tool-gate.ts is at least 80%

---

#### TRD-004: foreman-budget Extension (3h) [satisfies REQ-004] [satisfies REQ-019]
Implement the `foreman-budget` Pi extension that hooks `turn_end` events and enforces hard turn and token limits. Reads `FOREMAN_MAX_TURNS` and `FOREMAN_MAX_TOKENS` from env vars. Returns `{ block: true }` when limits are exceeded to terminate the session.

**Validates PRD ACs:** AC-004-1, AC-004-2, AC-004-3, AC-004-4, AC-004-5, AC-019-1, AC-019-2, AC-019-3
**Implementation AC:**
- [ ] Given `FOREMAN_MAX_TURNS=30`, when the 30th turn completes and `turn_end` fires, then the extension returns `{ block: true, reason: "Turn limit reached: 30" }`
- [ ] Given `FOREMAN_MAX_TOKENS=100000`, when `ctx.getContextUsage().totalTokens >= 100000`, then the extension returns `{ block: true, reason: "Token limit reached" }`
- [ ] Given a budget termination, when the extension fires, then an audit callback is invoked with current turn count, token usage, and configured limits
- [ ] Given env vars not set, when the extension loads, then it uses defaults (80 turns, 500000 tokens)
- [ ] Given usage reporting from `ctx.getContextUsage()`, when tracked internally, then the extension cross-checks its own counter against Pi's reported values

[depends: TRD-002]

#### TRD-004-TEST: foreman-budget Tests (2h) [verifies TRD-004] [satisfies REQ-004] [satisfies REQ-019] [depends: TRD-004]
Unit tests for budget enforcement: turn limits, token limits, cross-check, defaults.

**Validates PRD ACs:** AC-004-1, AC-004-2, AC-004-3, AC-004-4, AC-004-5, AC-019-1, AC-019-2, AC-019-3
**Implementation AC:**
- [ ] Given a mock turn_end event at turn 30 with maxTurns=30, when the hook fires, then block is returned
- [ ] Given a mock turn_end event at turn 29 with maxTurns=30, when the hook fires, then no block
- [ ] Given a mock context with totalTokens=100001 and maxTokens=100000, when the hook fires, then block is returned
- [ ] Given coverage measurement, when tests complete, then coverage for budget-enforcer.ts is at least 80%

---

#### TRD-005: foreman-audit Extension (4h) [satisfies REQ-005] [satisfies REQ-020]
Implement the `foreman-audit` Pi extension that hooks all Pi events (`tool_call`, `turn_end`, `agent_start`, `agent_end`, `before_provider_request`, `session_shutdown`, `session_fork`) and writes structured audit entries. Phase 1: writes to local JSONL at `~/.foreman/audit/{runId}.jsonl`. Phase 3: streams to Agent Mail inbox.

**Validates PRD ACs:** AC-005-1, AC-005-2, AC-005-3, AC-005-4, AC-005-5, AC-020-1, AC-020-4
**Implementation AC:**
- [ ] Given any Pi event, when the hook fires, then a structured JSONL line is appended to `~/.foreman/audit/{FOREMAN_RUN_ID}.jsonl`
- [ ] Given an audit entry, when written, then it includes: timestamp, runId (from `FOREMAN_RUN_ID`), seedId (from `FOREMAN_SEED_ID`), phase (from `FOREMAN_PHASE`), event type, tool name (if applicable), and event-specific details
- [ ] Given a tool_call event that was blocked by foreman-tool-gate, when the audit hook fires, then the entry includes `blocked: true` and the `blockReason`
- [ ] Given a complete pipeline run, when all phases complete, then the JSONL file contains a contiguous record from explorer start to finalize completion
- [ ] Given the `session_shutdown` hook, when Pi shuts down, then the audit extension flushes any buffered entries and writes a final shutdown entry

[depends: TRD-002]

#### TRD-005-TEST: foreman-audit Tests (2h) [verifies TRD-005] [satisfies REQ-005] [satisfies REQ-020] [depends: TRD-005]
Unit tests for audit logging: all event types, structured format, blocked events, contiguity.

**Validates PRD ACs:** AC-005-1, AC-005-2, AC-005-4, AC-005-5, AC-020-1, AC-020-4
**Implementation AC:**
- [ ] Given mock events for each type (tool_call, turn_end, agent_start, agent_end), when hooks fire, then JSONL entries are written with correct structure
- [ ] Given a blocked tool_call, when the audit hook receives the block info, then the entry includes blockReason
- [ ] Given a simulated multi-phase run, when all phase events fire, then entries are contiguous and ordered by timestamp
- [ ] Given coverage measurement, when tests complete, then coverage for audit-logger.ts is at least 80%

---

#### TRD-006: Extension Index and Registration (2h) [satisfies REQ-013] [satisfies ARCH]
Create the `packages/foreman-pi-extensions/src/index.ts` that exports all three extensions in the format Pi expects for loading. Ensure the package exports are correct for ESM consumers.

**Validates PRD ACs:** AC-013-1, AC-013-2
**Implementation AC:**
- [ ] Given the index module, when imported, then it exports `toolGate`, `budget`, and `audit` extension objects
- [ ] Given Pi's extension loading mechanism, when the package path is provided via `--extensions`, then Pi discovers and loads all three extensions
- [ ] Given the package.json exports field, when another package imports from `@foreman/pi-extensions`, then the ESM exports resolve correctly

[depends: TRD-003, TRD-004, TRD-005]

#### TRD-006-TEST: Extension Registration Tests (1h) [verifies TRD-006] [satisfies REQ-013] [depends: TRD-006]
Verify extension exports and loading interface.

**Validates PRD ACs:** AC-013-1
**Implementation AC:**
- [ ] Given the index module, when imported, then all three extensions have valid `name` and `events` properties

---

#### TRD-007: Phase 1 Audit JSONL Reader for CLI (3h) [satisfies REQ-022]
Implement local JSONL audit reader that powers `foreman audit` in Phase 1 (before Agent Mail). Supports filtering by seed, phase, event-type, and time range. Supports basic grep-based full-text search over JSONL files.

**Validates PRD ACs:** AC-022-1, AC-022-3, AC-022-4, AC-022-5
**Implementation AC:**
- [ ] Given audit JSONL files in `~/.foreman/audit/`, when `readAuditEntries(seedId)` is called, then it finds the run ID for the seed and reads the corresponding JSONL file
- [ ] Given the `--phase` filter, when applied, then only entries matching the phase are returned
- [ ] Given the `--event-type` filter, when applied, then only entries matching the event type are returned
- [ ] Given `--since` and `--until` timestamps, when applied, then only entries within the range are returned
- [ ] Given `--search` text, when applied, then JSONL lines containing the search text are returned

[depends: TRD-005]

#### TRD-007-TEST: Audit JSONL Reader Tests (2h) [verifies TRD-007] [satisfies REQ-022] [depends: TRD-007]
Unit tests for JSONL reader: filtering, searching, time ranges.

**Validates PRD ACs:** AC-022-1, AC-022-3, AC-022-4, AC-022-5
**Implementation AC:**
- [ ] Given a fixture JSONL file with mixed events, when filtered by phase=explorer, then only explorer entries are returned
- [ ] Given a fixture JSONL file, when searched for "Bash rm", then matching entries are returned with context

---

#### TRD-008: `foreman audit` CLI Command (Phase 1 -- Local JSONL) (3h) [satisfies REQ-016] [satisfies REQ-022]
Implement the `foreman audit` CLI command that reads local JSONL audit files. Flags: `--seed`, `--search`, `--phase`, `--event-type`, `--since`, `--until`. Outputs chronological list of events with formatted display.

**Validates PRD ACs:** AC-016-2, AC-022-1, AC-022-2, AC-022-3, AC-022-4, AC-022-5
**Implementation AC:**
- [ ] Given `foreman audit --seed bd-1234`, when invoked, then it displays a chronological list of all audit events for that seed's most recent run
- [ ] Given `foreman audit --search "Bash rm"`, when invoked, then it performs text search across all audit JSONL files
- [ ] Given `foreman audit --seed bd-1234 --phase explorer`, when invoked, then only explorer phase events are displayed
- [ ] Given `foreman audit --seed bd-1234 --event-type tool_call`, when invoked, then only tool_call events are displayed
- [ ] Given `foreman audit --since 2026-03-19T00:00:00Z --until 2026-03-19T23:59:59Z`, when invoked, then only events in range are returned

[depends: TRD-007]

#### TRD-008-TEST: `foreman audit` CLI Tests (2h) [verifies TRD-008] [satisfies REQ-022] [depends: TRD-008]
Integration tests for the audit CLI command with fixture JSONL files.

**Validates PRD ACs:** AC-022-1, AC-022-2, AC-022-3, AC-022-4, AC-022-5
**Implementation AC:**
- [ ] Given fixture JSONL files, when the CLI is invoked with various filter combinations, then output matches expected entries

---

#### TRD-009: Extension Integration Test Harness (3h) [satisfies REQ-013] [satisfies INFRA]
Create a test harness that simulates Pi extension events for integration testing without requiring the Pi binary. Provides mock `ToolCallEvent`, `TurnEndEvent`, and `ExtensionContext` objects.

**Validates PRD ACs:** AC-013-3, AC-015-4
**Implementation AC:**
- [ ] Given the test harness, when an extension is loaded, then tool_call and turn_end events can be dispatched and responses collected
- [ ] Given the audit extension under test, when 100 tool_call events are dispatched, then average overhead per event is under 50ms
- [ ] Given the test harness, when all extension tests are run together, then aggregate coverage is at least 80%

[depends: TRD-003, TRD-004, TRD-005, TRD-006]

---

### Phase 2: PiRpcSpawnStrategy + Dispatcher Integration (P1) -- Week 3-4

#### TRD-010: Pi Binary Detection (2h) [satisfies REQ-002]
Implement `isPiAvailable()` function that checks for the `pi` binary on PATH. Cache the result for the process lifetime. Add `FOREMAN_SPAWN_STRATEGY` env var override (`pi-rpc` | `tmux` | `detached`).

**Validates PRD ACs:** AC-002-1, AC-002-2
**Implementation AC:**
- [ ] Given `pi` is on PATH, when `isPiAvailable()` is called, then it returns `true`
- [ ] Given `pi` is NOT on PATH, when `isPiAvailable()` is called, then it returns `false`
- [ ] Given `FOREMAN_SPAWN_STRATEGY=detached`, when `spawnWorkerProcess()` is called, then `DetachedSpawnStrategy` is used regardless of Pi availability
- [ ] Given the result is cached, when `isPiAvailable()` is called multiple times, then `which pi` is only executed once

[depends: none]

#### TRD-010-TEST: Pi Binary Detection Tests (1h) [verifies TRD-010] [satisfies REQ-002] [depends: TRD-010]
Unit tests with mocked execFileSync for PATH detection and env var override.

**Validates PRD ACs:** AC-002-1, AC-002-2
**Implementation AC:**
- [ ] Given a mocked `which pi` that succeeds, when `isPiAvailable()` is called, then true is returned
- [ ] Given a mocked `which pi` that fails, when `isPiAvailable()` is called, then false is returned
- [ ] Given `FOREMAN_SPAWN_STRATEGY=detached`, when strategy selection runs, then Pi detection is skipped

---

#### TRD-011: JSONL RPC Protocol Layer (4h) [satisfies REQ-001] [satisfies ARCH]
Implement the JSONL-over-stdin/stdout protocol layer: `PiRpcClient` class with methods for sending commands and parsing event streams. Handles backpressure on stdin writes, async readline parsing on stdout, and watchdog timer for pipe deadlock detection.

**Validates PRD ACs:** AC-001-2, AC-001-3, AC-001-4
**Implementation AC:**
- [ ] Given a `PiRpcClient`, when `sendCommand({ cmd: "prompt", text: "..." })` is called, then a JSONL line is written to the child process stdin
- [ ] Given stdout events from Pi, when JSONL lines arrive, then they are parsed and emitted as typed events (`ToolCallEvent`, `TurnEndEvent`, `AgentEndEvent`, etc.)
- [ ] Given `sendCommand({ cmd: "set_model", model: "claude-sonnet-4-6" })`, when sent, then Pi receives the model change command
- [ ] Given `sendCommand({ cmd: "set_context", files: [...] })`, when sent, then Pi receives the context update
- [ ] Given stdin write backpressure, when the write buffer is full, then the client waits for drain before writing more
- [ ] Given no stdout activity for 60 seconds, when the watchdog fires, then a timeout error is emitted

[depends: TRD-002]

#### TRD-011-TEST: JSONL RPC Protocol Tests (3h) [verifies TRD-011] [satisfies REQ-001] [depends: TRD-011]
Unit tests with mock child process streams for command sending, event parsing, backpressure, and watchdog.

**Validates PRD ACs:** AC-001-2, AC-001-3, AC-001-4
**Implementation AC:**
- [ ] Given a mock stdin stream, when commands are sent, then JSONL lines appear on the stream
- [ ] Given a mock stdout stream with JSONL events, when parsed, then typed event objects are emitted
- [ ] Given a simulated pipe break, when detected, then an error event is emitted within 5 seconds

---

#### TRD-012: PiRpcSpawnStrategy (6h) [satisfies REQ-001] [satisfies REQ-002] [satisfies REQ-011]
Implement `PiRpcSpawnStrategy` class that implements the `SpawnStrategy` interface. Spawns `pi --mode rpc --extensions <path>` as a child process, sends initialization sequence (extensions config, phase metadata, system prompt, initial prompt), and manages the session lifecycle. Handles process exit detection and status updates.

**Validates PRD ACs:** AC-001-1, AC-001-5, AC-002-2, AC-002-3, AC-011-1, AC-011-2, AC-011-3, AC-011-4, AC-015-1
**Implementation AC:**
- [ ] Given Pi is available, when `spawn(config)` is called, then a `pi --mode rpc` child process is started with the extension package path
- [ ] Given the Pi process is started, when initialization completes, then the first prompt is sent within 2 seconds of process creation
- [ ] Given a running Pi session, when `agent_end` event is received, then Foreman updates `RunProgress` with final statistics (turns, tokens, cost)
- [ ] Given the Pi process crashes, when stdin/stdout pipe breaks, then Foreman detects it within 5 seconds, marks run as "stuck", and stores session ID for resume
- [ ] Given operator cancellation, when Foreman closes stdin, then Pi performs clean shutdown via `session_shutdown` hook
- [ ] Given `PiRpcSpawnStrategy.spawn()` fails, when the error is caught, then Foreman falls back to `DetachedSpawnStrategy` and logs a warning
- [ ] Given env vars `FOREMAN_PHASE`, `FOREMAN_ALLOWED_TOOLS`, `FOREMAN_MAX_TURNS`, `FOREMAN_MAX_TOKENS`, `FOREMAN_RUN_ID`, `FOREMAN_SEED_ID`, when the Pi process is spawned, then all env vars are set in the child process environment

[depends: TRD-010, TRD-011, TRD-006]

#### TRD-012-TEST: PiRpcSpawnStrategy Tests (4h) [verifies TRD-012] [satisfies REQ-001] [satisfies REQ-002] [satisfies REQ-011] [depends: TRD-012]
Unit and integration tests for PiRpcSpawnStrategy: spawn, initialization, exit detection, fallback.

**Validates PRD ACs:** AC-001-1, AC-001-5, AC-002-2, AC-002-3, AC-011-1, AC-011-2, AC-011-3, AC-011-4, AC-015-1
**Implementation AC:**
- [ ] Given a mock Pi process, when `spawn()` is called, then the initialization sequence is sent in correct order
- [ ] Given a mock Pi process that exits cleanly, when the exit event fires, then run status is updated to "completed"
- [ ] Given a mock Pi process that crashes, when pipe break is detected, then run status is updated to "stuck" within 5 seconds
- [ ] Given a mock Pi process that fails to spawn, when the error occurs, then DetachedSpawnStrategy is used as fallback

---

#### TRD-013: Dispatcher Strategy Selection Update (3h) [satisfies REQ-002]
Update `spawnWorkerProcess()` in `dispatcher.ts` to use the three-tier strategy: Pi RPC -> Detached (fallback) -> Detached (direct). Deprecate `TmuxSpawnStrategy` with `@deprecated` JSDoc. Add `FOREMAN_SPAWN_STRATEGY` env var override.

**Validates PRD ACs:** AC-002-1, AC-002-2, AC-002-3, AC-002-4
**Implementation AC:**
- [ ] Given Pi is available, when `spawnWorkerProcess()` is called, then `PiRpcSpawnStrategy` is selected first
- [ ] Given Pi is available but spawn fails, when the failure is caught, then `DetachedSpawnStrategy` is used with a warning logged
- [ ] Given Pi is not available, when `spawnWorkerProcess()` is called, then `DetachedSpawnStrategy` is used directly
- [ ] Given `FOREMAN_SPAWN_STRATEGY=tmux`, when `spawnWorkerProcess()` is called, then `TmuxSpawnStrategy` is still used (backward compat)
- [ ] Given fallback to `DetachedSpawnStrategy`, when the agent completes, then all SQLite updates, notification POSTs, and br operations are preserved identically
- [ ] Given `TmuxSpawnStrategy`, when its source is inspected, then `@deprecated` JSDoc is present

[depends: TRD-012, TRD-010]

#### TRD-013-TEST: Dispatcher Strategy Selection Tests (2h) [verifies TRD-013] [satisfies REQ-002] [depends: TRD-013]
Tests for strategy selection chain, env var override, and fallback behavior.

**Validates PRD ACs:** AC-002-1, AC-002-2, AC-002-3, AC-002-4
**Implementation AC:**
- [ ] Given mock Pi available, when strategy selection runs, then PiRpcSpawnStrategy is chosen
- [ ] Given mock Pi unavailable, when strategy selection runs, then DetachedSpawnStrategy is chosen directly
- [ ] Given mock Pi available but spawn fails, when the failure occurs, then DetachedSpawnStrategy is used

---

#### TRD-014: RPC Session Lifecycle Management (4h) [satisfies REQ-011]
Implement session lifecycle logic in PiRpcSpawnStrategy: phase transitions (reuse/resume/fork), configurable via `FOREMAN_PI_SESSION_STRATEGY` env var. Handle `switch_session`, `fork`, and `new_session` RPC commands for multi-phase pipelines.

**Validates PRD ACs:** AC-011-5
**Implementation AC:**
- [ ] Given `FOREMAN_PI_SESSION_STRATEGY=reuse`, when transitioning from Explorer to Developer, then the same Pi process receives `set_model` and `set_context` commands with new phase config
- [ ] Given `FOREMAN_PI_SESSION_STRATEGY=resume`, when transitioning phases, then a new Pi process is spawned with `switch_session` to resume context
- [ ] Given `FOREMAN_PI_SESSION_STRATEGY=fork`, when Dev->QA retry occurs, then the `fork` command is sent to branch from the current session point
- [ ] Given no env var set, when the strategy defaults, then `reuse` is used (simplest, lowest overhead)

[depends: TRD-012]

#### TRD-014-TEST: Session Lifecycle Tests (2h) [verifies TRD-014] [satisfies REQ-011] [depends: TRD-014]
Tests for each session strategy: reuse, resume, fork.

**Validates PRD ACs:** AC-011-5
**Implementation AC:**
- [ ] Given strategy=reuse, when phase transition occurs, then set_model and set_context commands are sent on the existing process
- [ ] Given strategy=fork, when Dev->QA retry occurs, then fork command is sent and a new branch session is created

---

#### TRD-015: Extend ModelSelection Type (2h) [satisfies REQ-009] [satisfies REQ-017]
Relax `ModelSelection` type from a 3-value union to `string` in `types.ts`. Update `VALID_MODELS` validation in `roles.ts` to accept any string (Pi resolves provider). Update `resolveModel()` to pass through arbitrary model strings. Add `maxTurns` and `maxTokens` fields to `RoleConfig`.

**Validates PRD ACs:** AC-009-3, AC-009-4, AC-017-3
**Implementation AC:**
- [ ] Given `ModelSelection` type, when updated, then it accepts any string value (e.g., `gpt-4o-mini`, `gemini-1.5-pro`)
- [ ] Given `FOREMAN_EXPLORER_MODEL=gpt-4o-mini`, when `resolveModel()` is called, then it returns `gpt-4o-mini` without throwing
- [ ] Given `RoleConfig`, when `maxTurns` and `maxTokens` fields are added, then they have default values matching the phase config table from PRD Section 9
- [ ] Given default values, when Explorer config is read, then maxTurns=30 and maxTokens=100000

[depends: none]

#### TRD-015-TEST: ModelSelection and RoleConfig Tests (1h) [verifies TRD-015] [satisfies REQ-009] [satisfies REQ-017] [depends: TRD-015]
Tests for relaxed type, env var passthrough, and new RoleConfig fields.

**Validates PRD ACs:** AC-009-3, AC-009-4, AC-017-3
**Implementation AC:**
- [ ] Given a non-Anthropic model string in env var, when resolveModel is called, then the string passes through
- [ ] Given RoleConfig for each phase, when maxTurns and maxTokens are read, then they match the PRD phase config table

---

#### TRD-016: Per-Phase Model Selection via Pi RPC (3h) [satisfies REQ-009] [satisfies REQ-017]
Implement model selection through Pi RPC `set_model` command at phase start. Map `ROLE_CONFIGS[role].model` to the `set_model` command. Update `RunProgress.costByPhase` and `agentByPhase` with actual model used.

**Validates PRD ACs:** AC-009-1, AC-009-2, AC-009-5, AC-017-1, AC-017-2
**Implementation AC:**
- [ ] Given Explorer phase starting, when Pi RPC is initialized, then `{ cmd: "set_model", model: ROLE_CONFIGS.explorer.model }` is sent
- [ ] Given Developer phase starting, when Pi RPC is initialized, then `{ cmd: "set_model", model: ROLE_CONFIGS.developer.model }` is sent
- [ ] Given `FOREMAN_EXPLORER_MODEL=gpt-4o-mini`, when Explorer phase starts, then that model is sent via set_model
- [ ] Given phase completion, when `agent_end` event is received, then `RunProgress.costByPhase` and `agentByPhase` are updated with the actual model

[depends: TRD-012, TRD-015]

#### TRD-016-TEST: Per-Phase Model Selection Tests (2h) [verifies TRD-016] [satisfies REQ-009] [satisfies REQ-017] [depends: TRD-016]
Tests for model selection commands and cost tracking.

**Validates PRD ACs:** AC-009-1, AC-009-2, AC-009-5, AC-017-1, AC-017-2
**Implementation AC:**
- [ ] Given mock Pi RPC client, when Explorer phase starts, then set_model command contains the configured model
- [ ] Given phase completion, when RunProgress is updated, then costByPhase and agentByPhase contain correct values

---

#### TRD-017: Pi Extension Health Check (2h) [satisfies REQ-018]
Implement an RPC health check that verifies foreman-tool-gate extension is loaded and active before the pipeline starts. If the extension is not active, refuse to start and log an error.

**Validates PRD ACs:** AC-018-3
**Implementation AC:**
- [ ] Given Pi RPC session initialized, when a health check command is sent, then Pi responds with loaded extension list
- [ ] Given foreman-tool-gate is in the loaded list, when validated, then the pipeline proceeds
- [ ] Given foreman-tool-gate is NOT in the loaded list, when validated, then the pipeline refuses to start and logs an error with actionable guidance

[depends: TRD-012]

#### TRD-017-TEST: Extension Health Check Tests (1h) [verifies TRD-017] [satisfies REQ-018] [depends: TRD-017]
Tests for health check pass/fail scenarios.

**Validates PRD ACs:** AC-018-3
**Implementation AC:**
- [ ] Given a mock Pi that reports extensions loaded, when health check runs, then pipeline proceeds
- [ ] Given a mock Pi that reports no extensions, when health check runs, then pipeline refuses with error

---

#### TRD-018: Multi-Model Security Enforcement (2h) [satisfies REQ-021]
Ensure Pi extensions (tool-gate, budget, audit) are model-agnostic. When `set_model` switches to a non-Anthropic model, all enforcement continues. Record model changes in audit trail.

**Validates PRD ACs:** AC-021-1, AC-021-2
**Implementation AC:**
- [ ] Given a non-Anthropic model (e.g., `gpt-4o-mini`), when tool_call events fire, then foreman-tool-gate still enforces phase restrictions
- [ ] Given a `set_model` command, when the model changes, then foreman-audit logs the model change with old and new model identifiers

[depends: TRD-003, TRD-005, TRD-016]

#### TRD-018-TEST: Multi-Model Security Tests (1h) [verifies TRD-018] [satisfies REQ-021] [depends: TRD-018]
Tests verifying enforcement continues across model changes.

**Validates PRD ACs:** AC-021-1, AC-021-2
**Implementation AC:**
- [ ] Given a model change to gpt-4o-mini, when tool_call hook fires, then blocking behavior is unchanged
- [ ] Given a model change, when audit hook fires, then the model change is recorded

---

#### TRD-019: `foreman status` Pi RPC Stats (2h) [satisfies REQ-016]
Update `foreman status` to display Pi RPC-specific information when available: current phase, turn count, token usage, model, and last tool call -- sourced from Pi RPC streaming events stored in `RunProgress`.

**Validates PRD ACs:** AC-016-1
**Implementation AC:**
- [ ] Given a running Pi RPC pipeline, when `foreman status` is invoked, then it displays: current phase, turn count, token usage, model, last tool call
- [ ] Given a running DetachedSpawnStrategy pipeline (fallback), when `foreman status` is invoked, then existing behavior is preserved

[depends: TRD-012]

#### TRD-019-TEST: Status Display Tests (1h) [verifies TRD-019] [satisfies REQ-016] [depends: TRD-019]
Tests for Pi RPC stats display in foreman status.

**Validates PRD ACs:** AC-016-1
**Implementation AC:**
- [ ] Given RunProgress with Pi RPC data, when status is rendered, then all Pi-specific fields are displayed

---

### Phase 3: Agent Mail Integration (P2) -- Week 5-6

#### TRD-020: Agent Mail HTTP Client (4h) [satisfies REQ-006] [satisfies REQ-014]
Implement `AgentMailClient` class in `src/orchestrator/agent-mail-client.ts` with methods: `registerAgent(name)`, `sendMessage(to, subject, body, metadata)`, `fetchInbox(agent, options)`, `fileReservation(paths, lease)`, `releaseReservation(paths)`, `healthCheck()`. All methods are fire-and-forget with configurable timeout (default 500ms). Config stored in `.foreman/agent-mail.json`.

**Validates PRD ACs:** AC-006-1, AC-006-2, AC-006-3, AC-006-4, AC-006-5, AC-014-1, AC-014-2, AC-014-3
**Implementation AC:**
- [ ] Given Agent Mail running on port 8765, when `registerAgent("explorer-bd-1234")` is called, then a POST request is sent to `/register_agent`
- [ ] Given Agent Mail running, when `sendMessage("developer-bd-1234", "Explorer Report", content)` is called, then a POST is sent to `/send_message`
- [ ] Given Agent Mail running, when `fetchInbox("developer-bd-1234")` is called, then a GET request is sent to `/fetch_inbox`
- [ ] Given Agent Mail is NOT running, when any method is called, then it silently returns without throwing (fire-and-forget)
- [ ] Given `foreman init`, when the project is initialized, then `.foreman/agent-mail.json` is created with default config
- [ ] Given `foreman run`, when agents are about to be dispatched, then `healthCheck()` is called and a warning is logged if Agent Mail is unreachable

[depends: none]

#### TRD-020-TEST: Agent Mail Client Tests (3h) [verifies TRD-020] [satisfies REQ-006] [satisfies REQ-014] [depends: TRD-020]
Unit tests with mock HTTP server for all client methods, including failure scenarios.

**Validates PRD ACs:** AC-006-1, AC-006-2, AC-006-3, AC-006-4, AC-006-5, AC-014-1, AC-014-2, AC-014-3
**Implementation AC:**
- [ ] Given a mock HTTP server, when registerAgent is called, then the request body contains the agent name
- [ ] Given a mock server that returns errors, when sendMessage is called, then the error is silently swallowed
- [ ] Given no server running, when any method is called, then no exception propagates

---

#### TRD-021: File Reservation Integration (3h) [satisfies REQ-007]
Integrate Agent Mail file reservation leases into the Developer and QA phases. Developer creates reservations for files identified in EXPLORER_REPORT.md. Reservations are released on phase end (success or failure). QA can query reservation status.

**Validates PRD ACs:** AC-007-1, AC-007-2, AC-007-3, AC-007-4
**Implementation AC:**
- [ ] Given Developer phase starting, when EXPLORER_REPORT.md recommends files, then file reservations are created via Agent Mail
- [ ] Given active reservations by one agent, when another agent attempts overlapping reservation, then the conflict response includes holder identity and expiry
- [ ] Given Developer phase completing, when the phase ends, then all reservations are released
- [ ] Given Developer phase failing, when the phase ends with error, then all reservations are released (cleanup in finally block)
- [ ] Given QA phase starting, when it queries reservation status, then it sees which files were edited

[depends: TRD-020]

#### TRD-021-TEST: File Reservation Tests (2h) [verifies TRD-021] [satisfies REQ-007] [depends: TRD-021]
Tests for reservation create, conflict, release, and query.

**Validates PRD ACs:** AC-007-1, AC-007-2, AC-007-3, AC-007-4
**Implementation AC:**
- [ ] Given a mock Agent Mail, when reservations are created, then the request includes paths and lease duration
- [ ] Given active reservations, when conflicting request arrives, then conflict response is handled gracefully

---

#### TRD-022: Phase Handoff via Agent Mail (4h) [satisfies REQ-010]
Integrate Agent Mail messaging into the pipeline phase handoffs in `agent-worker.ts`. After writing disk files (EXPLORER_REPORT.md, QA_REPORT.md, REVIEW.md), also send the content as Agent Mail messages with structured metadata. All sends are fire-and-forget.

**Validates PRD ACs:** AC-010-1, AC-010-2, AC-010-3, AC-010-4
**Implementation AC:**
- [ ] Given Explorer phase completing, when EXPLORER_REPORT.md is written, then the report content is also sent as Agent Mail message with subject "Explorer Report" to the run's thread
- [ ] Given QA phase completing with FAIL verdict, when Developer is retried, then QA feedback is available as Agent Mail message with subject "QA Feedback - Retry {n}"
- [ ] Given Reviewer phase completing, when REVIEW.md is written, then the review content is sent as Agent Mail message with parseVerdict() result in metadata
- [ ] Given Agent Mail is unavailable, when a phase attempts to send, then the phase continues normally using disk files only

[depends: TRD-020]

#### TRD-022-TEST: Phase Handoff Messaging Tests (2h) [verifies TRD-022] [satisfies REQ-010] [depends: TRD-022]
Tests for Agent Mail sends at each phase transition with failure scenarios.

**Validates PRD ACs:** AC-010-1, AC-010-2, AC-010-3, AC-010-4
**Implementation AC:**
- [ ] Given mock Agent Mail, when Explorer completes, then a message with "Explorer Report" subject is sent
- [ ] Given Agent Mail down, when Explorer completes, then no error and disk file is written normally

---

#### TRD-023: Branch-Ready Signal via Agent Mail (2h) [satisfies REQ-006]
Modify `agent-worker-finalize.ts` to send a "branch-ready" message to the `merge-agent` Agent Mail inbox after successful git push. Message contains: seedId, branchName, runId, commitHash.

**Validates PRD ACs:** AC-006-4
**Implementation AC:**
- [ ] Given Finalize phase completing (git push succeeds), when the branch is ready, then a "branch-ready" message is sent to the `merge-agent` inbox
- [ ] Given the message, when sent, then it contains seedId, branchName, runId, and commitHash
- [ ] Given Agent Mail is down, when the send fails, then the finalize continues normally (fire-and-forget)

[depends: TRD-020]

#### TRD-023-TEST: Branch-Ready Signal Tests (1h) [verifies TRD-023] [satisfies REQ-006] [depends: TRD-023]
Tests for branch-ready message sending and failure handling.

**Validates PRD ACs:** AC-006-4
**Implementation AC:**
- [ ] Given mock Agent Mail, when finalize completes, then branch-ready message is sent with correct fields

---

#### TRD-024: Notification System Deprecation (2h) [satisfies REQ-012]
Mark `NotificationServer` and `NotificationBus` with `@deprecated` JSDoc tags. Add Agent Mail as an alternative notification channel in `agent-worker.ts`. Preserve SQLite polling fallback.

**Validates PRD ACs:** AC-012-1, AC-012-2, AC-012-3, AC-012-4
**Implementation AC:**
- [ ] Given `NotificationServer` class, when its JSDoc is updated, then `@deprecated` tag is present with migration note
- [ ] Given `NotificationBus` class, when its JSDoc is updated, then `@deprecated` tag is present with migration note
- [ ] Given a pipeline run, when a phase completes, then status update is sent to Agent Mail (in addition to HTTP POST)
- [ ] Given Agent Mail is down, when status updates need communication, then SQLite polling fallback continues to work

[depends: TRD-020]

#### TRD-024-TEST: Notification Deprecation Tests (1h) [verifies TRD-024] [satisfies REQ-012] [depends: TRD-024]
Tests verifying deprecated annotations and dual-channel notifications.

**Validates PRD ACs:** AC-012-1, AC-012-3, AC-012-4
**Implementation AC:**
- [ ] Given the source code, when parsed for JSDoc, then @deprecated is present on both classes
- [ ] Given Agent Mail available, when phase completes, then both Agent Mail and HTTP notifications are sent

---

#### TRD-025: Audit Extension Upgrade to Agent Mail (3h) [satisfies REQ-005] [satisfies REQ-020]
Upgrade `foreman-audit` extension to stream audit entries to Agent Mail (in addition to local JSONL). Implement the buffering strategy: when Agent Mail is down, buffer entries locally and flush when recovered (AC-020-3).

**Validates PRD ACs:** AC-005-3, AC-020-2, AC-020-3
**Implementation AC:**
- [ ] Given Agent Mail is available, when audit events fire, then entries are sent to the "audit-log" Agent Mail inbox
- [ ] Given audit messages in Agent Mail, when FTS5 search is performed, then entries are searchable by run ID, phase, tool name
- [ ] Given Agent Mail is down, when audit events fire, then entries are buffered in `~/.foreman/audit-buffer/` and flushed on recovery
- [ ] Given Agent Mail recovers, when the buffer flush runs, then all buffered entries are sent and the buffer is cleared

[depends: TRD-005, TRD-020]

#### TRD-025-TEST: Audit Agent Mail Upgrade Tests (2h) [verifies TRD-025] [satisfies REQ-005] [satisfies REQ-020] [depends: TRD-025]
Tests for Agent Mail streaming, buffering, and flush-on-recovery.

**Validates PRD ACs:** AC-005-3, AC-020-2, AC-020-3
**Implementation AC:**
- [ ] Given mock Agent Mail, when audit events fire, then messages are sent to audit-log inbox
- [ ] Given mock Agent Mail down, when audit events fire, then entries are buffered locally
- [ ] Given mock Agent Mail recovers, when buffer flush runs, then buffered entries are sent

---

#### TRD-026: `foreman audit` CLI Upgrade for Agent Mail (2h) [satisfies REQ-022]
Upgrade the `foreman audit` CLI command to use Agent Mail FTS5 when available, falling back to local JSONL grep when not.

**Validates PRD ACs:** AC-022-2, AC-022-6
**Implementation AC:**
- [ ] Given Agent Mail is available, when `foreman audit --search "Bash rm"` is invoked, then search is delegated to Agent Mail FTS5
- [ ] Given Agent Mail is not available, when `foreman audit --search "Bash rm"` is invoked, then local JSONL grep is used as fallback

[depends: TRD-008, TRD-025]

#### TRD-026-TEST: Audit CLI Agent Mail Tests (1h) [verifies TRD-026] [satisfies REQ-022] [depends: TRD-026]
Tests for Agent Mail FTS5 delegation and fallback.

**Validates PRD ACs:** AC-022-2, AC-022-6
**Implementation AC:**
- [ ] Given mock Agent Mail with FTS5, when search is invoked, then Agent Mail API is called
- [ ] Given Agent Mail down, when search is invoked, then local JSONL is searched

---

#### TRD-027: Agent Mail Performance Validation (2h) [satisfies REQ-015]
Implement performance benchmarks for Agent Mail operations: message send latency (<500ms), audit overhead (<50ms per tool call).

**Validates PRD ACs:** AC-015-2, AC-015-4
**Implementation AC:**
- [ ] Given a running Agent Mail server, when a message is sent, then it is visible to the recipient within 500ms (measured P95)
- [ ] Given the audit extension streaming to Agent Mail, when a tool_call event fires, then audit logging adds no more than 50ms overhead (measured P95)

[depends: TRD-020, TRD-025]

---

### Phase 4: Pi Merge Agent Daemon (P3) -- Week 7-8

#### TRD-028: Merge Agent Daemon Core (6h) [satisfies REQ-008]
Implement `MergeAgentDaemon` class in `src/orchestrator/merge-agent.ts` following the `SentinelAgent` pattern. Timer-based polling loop with `start()`/`stop()`. Polls Agent Mail `merge-agent` inbox for "branch-ready" messages. PID tracking in `merge_agent_configs` SQLite table. Lock file (`~/.foreman/merge.lock`) to yield to manual `foreman merge`.

**Validates PRD ACs:** AC-008-1, AC-008-5, AC-008-6
**Implementation AC:**
- [ ] Given the merge agent is started, when `start()` is called, then a timer-based polling loop begins checking the Agent Mail inbox
- [ ] Given a "branch-ready" message arrives, when the daemon polls, then it dequeues the message and begins merge processing
- [ ] Given `foreman merge` is invoked manually, when the lock file exists, then the daemon skips processing (yields to manual)
- [ ] Given the daemon starts, when stale "branch-ready" messages exist from before startup, then they are acknowledged and processed
- [ ] Given the daemon is running, when `stop()` is called, then the polling loop stops and the PID is cleared from SQLite
- [ ] Given the `merge_agent_configs` table, when the daemon starts, then its PID is stored for monitoring

[depends: TRD-020]

#### TRD-028-TEST: Merge Agent Daemon Core Tests (4h) [verifies TRD-028] [satisfies REQ-008] [depends: TRD-028]
Tests for daemon lifecycle, polling, locking, stale message handling.

**Validates PRD ACs:** AC-008-1, AC-008-5, AC-008-6
**Implementation AC:**
- [ ] Given mock Agent Mail with branch-ready messages, when daemon polls, then messages are dequeued
- [ ] Given a lock file exists, when daemon attempts to process, then it yields
- [ ] Given stale messages, when daemon starts, then they are processed

---

#### TRD-029: Extract Reusable Merge Functions from Refinery (4h) [satisfies REQ-008] [satisfies ARCH]
Refactor `Refinery.mergeCompleted()` to extract single-branch merge logic into a reusable `mergeOne(run, opts)` function callable by both the manual `foreman merge` path and the merge agent daemon. Preserve all existing behavior.

**Validates PRD ACs:** AC-008-2, AC-008-3
**Implementation AC:**
- [ ] Given the extracted `mergeOne()` function, when called with a completed run, then it performs the same merge logic as `mergeCompleted()` for a single branch
- [ ] Given a T1 clean merge, when `mergeOne()` processes it, then rebase + fast-forward + test + close bead happens without spawning Pi
- [ ] Given a T2 report-only conflict, when `mergeOne()` processes it, then report files are auto-resolved and merge completes programmatically
- [ ] Given existing `mergeCompleted()`, when refactored, then it calls `mergeOne()` in a loop (preserving existing behavior exactly)
- [ ] Given existing tests for Refinery, when the refactor is complete, then all existing tests still pass

[depends: none]

#### TRD-029-TEST: Extracted Merge Function Tests (3h) [verifies TRD-029] [satisfies REQ-008] [depends: TRD-029]
Tests for mergeOne: T1 clean, T2 report-only, preserving existing test suite.

**Validates PRD ACs:** AC-008-2, AC-008-3
**Implementation AC:**
- [ ] Given a mock clean-merge branch, when mergeOne is called, then it completes without error
- [ ] Given a mock branch with report-only conflicts, when mergeOne is called, then reports are auto-resolved

---

#### TRD-030: AI-Assisted Conflict Resolution via Pi (4h) [satisfies REQ-008]
Implement T3/T4 conflict resolution by spawning Pi RPC sessions with conflict context. The merge agent sends the conflict diff, affected files, and the original task description to Pi, which resolves the conflicts.

**Validates PRD ACs:** AC-008-4
**Implementation AC:**
- [ ] Given a branch with code conflicts (T3), when the merge agent detects the conflict, then a Pi RPC session is spawned with conflict context
- [ ] Given the Pi session, when it receives the conflict diff and task description, then it resolves the conflicts and commits the resolution
- [ ] Given a T4 complex conflict, when Pi resolution fails, then the branch is escalated to PR creation
- [ ] Given the conflict resolution, when Pi commits, then the resolution is validated by running tests

[depends: TRD-012, TRD-029]

#### TRD-030-TEST: AI Conflict Resolution Tests (3h) [verifies TRD-030] [satisfies REQ-008] [depends: TRD-030]
Tests for Pi-driven conflict resolution at T3/T4 tiers.

**Validates PRD ACs:** AC-008-4
**Implementation AC:**
- [ ] Given a mock Pi session with conflict context, when resolution is attempted, then the session receives correct context
- [ ] Given a failed Pi resolution, when escalation occurs, then PR creation is triggered

---

#### TRD-031: Merge Agent Retry and PR Escalation (3h) [satisfies REQ-008]
Implement retry logic (max 2 attempts) and PR escalation when merge fails. On retry exhaustion, delegate to `Refinery.createPrForConflict()` and send a notification message via Agent Mail.

**Validates PRD ACs:** AC-008-7
**Implementation AC:**
- [ ] Given a failed merge attempt, when retry count < 2, then the merge is retried
- [ ] Given 2 failed merge attempts, when the retry limit is exceeded, then a PR is created via `Refinery.createPrForConflict()`
- [ ] Given PR creation, when it succeeds, then a notification message is sent via Agent Mail
- [ ] Given PR creation, when it fails, then the branch is marked as "conflict" in ForemanStore

[depends: TRD-028, TRD-029]

#### TRD-031-TEST: Retry and Escalation Tests (2h) [verifies TRD-031] [satisfies REQ-008] [depends: TRD-031]
Tests for retry logic and PR creation on exhaustion.

**Validates PRD ACs:** AC-008-7
**Implementation AC:**
- [ ] Given 1 failed attempt, when retry runs, then merge is attempted again
- [ ] Given 2 failed attempts, when retry limit hit, then PR is created

---

#### TRD-032: Merge Agent CLI Commands (3h) [satisfies REQ-008] [satisfies REQ-016]
Implement `foreman merge-agent start`, `foreman merge-agent stop`, `foreman merge-agent status` CLI commands. Add `foreman merge --status` to display daemon state, pending messages, and recent merge results.

**Validates PRD ACs:** AC-016-3
**Implementation AC:**
- [ ] Given `foreman merge-agent start`, when invoked, then the merge agent daemon is started and PID is stored in SQLite
- [ ] Given `foreman merge-agent stop`, when invoked, then the daemon is stopped and PID is cleared
- [ ] Given `foreman merge-agent status`, when invoked, then it displays: running status, PID, uptime
- [ ] Given `foreman merge --status`, when invoked, then it displays: daemon status, pending branch-ready messages count, recent merge results

[depends: TRD-028]

#### TRD-032-TEST: Merge Agent CLI Tests (2h) [verifies TRD-032] [satisfies REQ-008] [satisfies REQ-016] [depends: TRD-032]
Tests for merge-agent CLI commands.

**Validates PRD ACs:** AC-016-3
**Implementation AC:**
- [ ] Given mock store with merge agent config, when start command runs, then daemon PID is recorded
- [ ] Given running daemon, when status command runs, then status info is displayed

---

#### TRD-033: Merge Agent SQLite Schema (2h) [satisfies REQ-008] [satisfies ARCH]
Add `merge_agent_configs` table to `store.ts` following the `sentinel_configs` pattern. Add CRUD methods: `upsertMergeAgentConfig()`, `getMergeAgentConfig()`. Add migration to MIGRATIONS array.

**Validates PRD ACs:** (infrastructure for AC-008-*)
**Implementation AC:**
- [ ] Given the store, when `upsertMergeAgentConfig()` is called, then a config row is created/updated
- [ ] Given the store, when `getMergeAgentConfig()` is called, then the config row is returned
- [ ] Given an existing database, when the migration runs, then `merge_agent_configs` table is created without error

[depends: none]

#### TRD-033-TEST: Merge Agent Schema Tests (1h) [verifies TRD-033] [satisfies REQ-008] [depends: TRD-033]
Tests for CRUD operations on merge_agent_configs.

**Validates PRD ACs:** (infrastructure)
**Implementation AC:**
- [ ] Given a fresh store, when upsert is called, then a config row is created
- [ ] Given an existing config, when upsert is called again, then the row is updated

---

#### TRD-034: Merge Processing Performance (2h) [satisfies REQ-015]
Ensure merge processing begins within 5 seconds of branch-ready message arrival. Measure and log latency from message send to merge start.

**Validates PRD ACs:** AC-015-3
**Implementation AC:**
- [ ] Given a branch-ready message sent to Agent Mail, when the merge agent polls, then merge processing begins within 5 seconds (measured P95)
- [ ] Given merge latency tracking, when each merge starts, then the latency from message timestamp to merge start is logged

[depends: TRD-028]

---

## 5. Sprint Planning

### Sprint 1: Week 1-2 (Phase 1 -- Pi Extensions Package)

| Task ID | Title | Est. | Depends | Priority |
|---------|-------|------|---------|----------|
| TRD-001 | Extension Package Scaffolding | 2h | -- | P0 |
| TRD-001-TEST | Scaffolding Tests | 1h | TRD-001 | P0 |
| TRD-002 | Pi Extension Type Definitions | 2h | TRD-001 | P0 |
| TRD-003 | foreman-tool-gate Extension | 4h | TRD-002 | P0 |
| TRD-003-TEST | tool-gate Tests | 3h | TRD-003 | P0 |
| TRD-004 | foreman-budget Extension | 3h | TRD-002 | P0 |
| TRD-004-TEST | budget Tests | 2h | TRD-004 | P0 |
| TRD-005 | foreman-audit Extension | 4h | TRD-002 | P0 |
| TRD-005-TEST | audit Tests | 2h | TRD-005 | P0 |
| TRD-006 | Extension Index and Registration | 2h | TRD-003, TRD-004, TRD-005 | P0 |
| TRD-006-TEST | Registration Tests | 1h | TRD-006 | P0 |
| TRD-007 | Audit JSONL Reader | 3h | TRD-005 | P0 |
| TRD-007-TEST | JSONL Reader Tests | 2h | TRD-007 | P0 |
| TRD-008 | `foreman audit` CLI (Phase 1) | 3h | TRD-007 | P0 |
| TRD-008-TEST | audit CLI Tests | 2h | TRD-008 | P0 |
| TRD-009 | Integration Test Harness | 3h | TRD-003, TRD-004, TRD-005, TRD-006 | P0 |

**Sprint 1 Total:** 39h (5 working days at ~8h/day)
**Sprint 1 Gate:** All extension unit tests pass, >=80% coverage, `foreman audit` works on local JSONL

---

### Sprint 2: Week 3-4 (Phase 2 -- PiRpcSpawnStrategy)

| Task ID | Title | Est. | Depends | Priority |
|---------|-------|------|---------|----------|
| TRD-010 | Pi Binary Detection | 2h | -- | P1 |
| TRD-010-TEST | Detection Tests | 1h | TRD-010 | P1 |
| TRD-011 | JSONL RPC Protocol Layer | 4h | TRD-002 | P1 |
| TRD-011-TEST | Protocol Tests | 3h | TRD-011 | P1 |
| TRD-012 | PiRpcSpawnStrategy | 6h | TRD-010, TRD-011, TRD-006 | P1 |
| TRD-012-TEST | SpawnStrategy Tests | 4h | TRD-012 | P1 |
| TRD-013 | Dispatcher Strategy Update | 3h | TRD-012, TRD-010 | P1 |
| TRD-013-TEST | Strategy Selection Tests | 2h | TRD-013 | P1 |
| TRD-014 | Session Lifecycle Management | 4h | TRD-012 | P1 |
| TRD-014-TEST | Session Lifecycle Tests | 2h | TRD-014 | P1 |
| TRD-015 | Extend ModelSelection Type | 2h | -- | P1 |
| TRD-015-TEST | ModelSelection Tests | 1h | TRD-015 | P1 |
| TRD-016 | Per-Phase Model Selection | 3h | TRD-012, TRD-015 | P1 |
| TRD-016-TEST | Model Selection Tests | 2h | TRD-016 | P1 |
| TRD-017 | Extension Health Check | 2h | TRD-012 | P1 |
| TRD-017-TEST | Health Check Tests | 1h | TRD-017 | P1 |
| TRD-018 | Multi-Model Security | 2h | TRD-003, TRD-005, TRD-016 | P1 |
| TRD-018-TEST | Multi-Model Tests | 1h | TRD-018 | P1 |
| TRD-019 | Status Pi RPC Stats | 2h | TRD-012 | P1 |
| TRD-019-TEST | Status Display Tests | 1h | TRD-019 | P1 |

**Sprint 2 Total:** 48h (6 working days at ~8h/day)
**Sprint 2 Gate:** E2E test: full pipeline via Pi RPC; fallback test passes; `foreman status` shows Pi stats

---

### Sprint 3: Week 5-6 (Phase 3 -- Agent Mail Integration)

| Task ID | Title | Est. | Depends | Priority |
|---------|-------|------|---------|----------|
| TRD-020 | Agent Mail HTTP Client | 4h | -- | P2 |
| TRD-020-TEST | Client Tests | 3h | TRD-020 | P2 |
| TRD-021 | File Reservation Integration | 3h | TRD-020 | P2 |
| TRD-021-TEST | Reservation Tests | 2h | TRD-021 | P2 |
| TRD-022 | Phase Handoff via Agent Mail | 4h | TRD-020 | P2 |
| TRD-022-TEST | Handoff Tests | 2h | TRD-022 | P2 |
| TRD-023 | Branch-Ready Signal | 2h | TRD-020 | P2 |
| TRD-023-TEST | Branch-Ready Tests | 1h | TRD-023 | P2 |
| TRD-024 | Notification Deprecation | 2h | TRD-020 | P2 |
| TRD-024-TEST | Deprecation Tests | 1h | TRD-024 | P2 |
| TRD-025 | Audit Extension Agent Mail Upgrade | 3h | TRD-005, TRD-020 | P2 |
| TRD-025-TEST | Audit Upgrade Tests | 2h | TRD-025 | P2 |
| TRD-026 | Audit CLI Agent Mail Upgrade | 2h | TRD-008, TRD-025 | P2 |
| TRD-026-TEST | Audit CLI Upgrade Tests | 1h | TRD-026 | P2 |
| TRD-027 | Agent Mail Performance Validation | 2h | TRD-020, TRD-025 | P2 |

**Sprint 3 Total:** 34h (4.25 working days at ~8h/day)
**Sprint 3 Gate:** Messaging works with Agent Mail up; pipeline completes with Agent Mail down; FTS5 search works

---

### Sprint 4: Week 7-8 (Phase 4 -- Pi Merge Agent)

| Task ID | Title | Est. | Depends | Priority |
|---------|-------|------|---------|----------|
| TRD-033 | Merge Agent SQLite Schema | 2h | -- | P3 |
| TRD-033-TEST | Schema Tests | 1h | TRD-033 | P3 |
| TRD-029 | Extract Reusable Merge Functions | 4h | -- | P3 |
| TRD-029-TEST | Merge Function Tests | 3h | TRD-029 | P3 |
| TRD-028 | Merge Agent Daemon Core | 6h | TRD-020 | P3 |
| TRD-028-TEST | Daemon Core Tests | 4h | TRD-028 | P3 |
| TRD-030 | AI-Assisted Conflict Resolution | 4h | TRD-012, TRD-029 | P3 |
| TRD-030-TEST | AI Resolution Tests | 3h | TRD-030 | P3 |
| TRD-031 | Retry and PR Escalation | 3h | TRD-028, TRD-029 | P3 |
| TRD-031-TEST | Retry Tests | 2h | TRD-031 | P3 |
| TRD-032 | Merge Agent CLI Commands | 3h | TRD-028 | P3 |
| TRD-032-TEST | CLI Tests | 2h | TRD-032 | P3 |
| TRD-034 | Merge Processing Performance | 2h | TRD-028 | P3 |

**Sprint 4 Total:** 39h (5 working days at ~8h/day)
**Sprint 4 Gate:** Daemon auto-merges T1/T2; T3/T4 creates PRs; manual merge lock works; `foreman merge --status` works

---

### Dependency Graph (Critical Path)

```
TRD-001 -> TRD-002 -> TRD-003 -> TRD-006 -> TRD-012 -> TRD-013 (Phase 1 -> Phase 2 bridge)
                    -> TRD-004 /
                    -> TRD-005 -> TRD-007 -> TRD-008 (Audit CLI)

TRD-010 ─────────────────────────> TRD-012 -> TRD-014 (Session lifecycle)
TRD-011 ─────────────────────────> TRD-012 -> TRD-016 (Model selection)
TRD-015 ──────────────────────────────────> TRD-016

TRD-020 -> TRD-021 (File reservations)
        -> TRD-022 (Phase handoff)
        -> TRD-023 (Branch-ready)
        -> TRD-024 (Notification deprecation)
        -> TRD-025 -> TRD-026 (Audit upgrade)
        -> TRD-028 -> TRD-031 (Merge daemon)

TRD-029 -> TRD-030 (AI resolution)
        -> TRD-031 (Retry/PR)
```

---

## 6. Quality Requirements

### 6.1 Testing Standards

| Level | Target Coverage | Scope |
|-------|----------------|-------|
| Unit | >= 80% | All extensions, client libraries, CLI commands |
| Integration | >= 70% | Pi RPC lifecycle, Agent Mail client, merge daemon |
| E2E | >= 50% | Full pipeline via Pi RPC, fallback to detached, merge automation |

### 6.2 Security Requirements

- **Tool restriction defense-in-depth:** enforced at Pi extension level, not just Foreman config (REQ-018)
- **Hard budget termination:** session killed, not warned (REQ-019)
- **100% audit coverage:** every tool invocation logged with no gaps (REQ-020)
- **Model-agnostic enforcement:** extensions work regardless of provider (REQ-021)
- **No secrets in audit:** tool arguments sanitized before logging
- **Canonical tool names:** prevent bypass via aliasing (AC-018-2)

### 6.3 Performance Requirements

| Metric | Target | Measurement |
|--------|--------|-------------|
| Pi RPC first prompt | < 2s from process creation | AC-015-1 |
| Agent Mail message visibility | < 500ms (local) | AC-015-2 |
| Merge processing start | < 5s from branch-ready | AC-015-3 |
| Audit overhead per tool call | < 50ms | AC-015-4 |

### 6.4 Backward Compatibility

- `DetachedSpawnStrategy` unchanged -- zero regression when Pi absent
- `TmuxSpawnStrategy` deprecated, not removed -- available via env var override
- All disk-file reports (EXPLORER_REPORT.md, QA_REPORT.md, REVIEW.md) continue to be written
- SQLite polling fallback preserved for `foreman status` / `foreman monitor`
- `NotificationServer` / `NotificationBus` remain in codebase for fallback path

---

## 7. Acceptance Criteria Traceability

| REQ ID | Description | Implementation Tasks | Test Tasks |
|--------|-------------|---------------------|------------|
| REQ-001 | PiRpcSpawnStrategy | TRD-011, TRD-012 | TRD-011-TEST, TRD-012-TEST |
| REQ-002 | Pi Binary Detection & Fallback | TRD-010, TRD-013 | TRD-010-TEST, TRD-013-TEST |
| REQ-003 | foreman-tool-gate Extension | TRD-003 | TRD-003-TEST |
| REQ-004 | foreman-budget Extension | TRD-004 | TRD-004-TEST |
| REQ-005 | foreman-audit Extension | TRD-005, TRD-025 | TRD-005-TEST, TRD-025-TEST |
| REQ-006 | Agent Mail Client Integration | TRD-020, TRD-023 | TRD-020-TEST, TRD-023-TEST |
| REQ-007 | Agent Mail File Reservations | TRD-021 | TRD-021-TEST |
| REQ-008 | Pi Merge Agent Daemon | TRD-028, TRD-029, TRD-030, TRD-031, TRD-032, TRD-033 | TRD-028-TEST, TRD-029-TEST, TRD-030-TEST, TRD-031-TEST, TRD-032-TEST, TRD-033-TEST |
| REQ-009 | Per-Phase Model Selection via Pi | TRD-015, TRD-016 | TRD-015-TEST, TRD-016-TEST |
| REQ-010 | Phase Communication via Agent Mail | TRD-022 | TRD-022-TEST |
| REQ-011 | RPC Session Lifecycle | TRD-012, TRD-014 | TRD-012-TEST, TRD-014-TEST |
| REQ-012 | Notification System Migration | TRD-024 | TRD-024-TEST |
| REQ-013 | Extension Package Structure | TRD-001, TRD-006 | TRD-001-TEST, TRD-006-TEST, TRD-009 |
| REQ-014 | Agent Mail Server Lifecycle | TRD-020 | TRD-020-TEST |
| REQ-015 | Performance Requirements | TRD-012, TRD-027, TRD-034 | TRD-012-TEST, TRD-027, TRD-034 |
| REQ-016 | Observability | TRD-008, TRD-019, TRD-032 | TRD-008-TEST, TRD-019-TEST, TRD-032-TEST |
| REQ-017 | Phase-Specific Pi Configuration | TRD-015, TRD-016 | TRD-015-TEST, TRD-016-TEST |
| REQ-018 | Tool Restriction Enforcement | TRD-003, TRD-017 | TRD-003-TEST, TRD-017-TEST |
| REQ-019 | Hard Budget Enforcement | TRD-004 | TRD-004-TEST |
| REQ-020 | Full Audit Trail | TRD-005, TRD-025 | TRD-005-TEST, TRD-025-TEST |
| REQ-021 | Multi-Model Security | TRD-018 | TRD-018-TEST |
| REQ-022 | Audit Trail CLI | TRD-007, TRD-008, TRD-026 | TRD-007-TEST, TRD-008-TEST, TRD-026-TEST |

---

## 8. Technical Decisions

### TD-001: Extension env vars vs. RPC metadata
**Decision:** Use `process.env.FOREMAN_*` env vars (set before spawning Pi) rather than Pi RPC metadata or `context.getMetadata()` for extension configuration.
**Rationale:** The PRD v1.2 explicitly pins extension examples to env vars. Env vars are simpler, work in all Pi versions, and align with existing Foreman patterns (`FOREMAN_EXPLORER_MODEL`, etc.).

### TD-002: Session strategy default
**Decision:** Default `FOREMAN_PI_SESSION_STRATEGY` to `reuse` (same Pi process, set_model + set_context between phases).
**Rationale:** Lowest overhead, simplest implementation. `fork` is preferred for Dev<->QA retries but adds complexity. Start simple, add fork later.

### TD-003: ModelSelection type relaxation
**Decision:** Change `ModelSelection` from a 3-value union to `string`.
**Rationale:** Pi supports 15+ providers. Maintaining a union of all possible model strings is impractical. Default values remain Anthropic model strings; Pi resolves the provider from the identifier.

### TD-004: Agent Mail as fire-and-forget
**Decision:** All Agent Mail sends are fire-and-forget with 500ms timeout. No retries.
**Rationale:** Agent Mail is supplementary, not critical path. The pipeline must complete identically whether Agent Mail is up or down. Disk files + SQLite are the source of truth.

### TD-005: Merge agent lock file
**Decision:** Use `~/.foreman/merge.lock` (file-based lock) to coordinate between daemon and manual `foreman merge`.
**Rationale:** Simple, cross-process coordination. The daemon checks for the lock before processing; manual merge acquires it. No need for IPC or shared memory.

### TD-006: Audit JSONL in Phase 1, Agent Mail in Phase 3
**Decision:** Phase 1 audit writes to local JSONL at `~/.foreman/audit/{runId}.jsonl`. Phase 3 upgrades to Agent Mail streaming with local JSONL as buffer/fallback.
**Rationale:** PRD explicitly defers AC-020-3 (audit buffer) to Phase 3. Local JSONL provides immediate value without Agent Mail dependency.

### TD-007: TmuxSpawnStrategy deprecation, not removal
**Decision:** Mark `TmuxSpawnStrategy` with `@deprecated` but keep it available via `FOREMAN_SPAWN_STRATEGY=tmux`.
**Rationale:** PRD says "deprecated but not removed". Some operators may prefer tmux for debugging visibility.
