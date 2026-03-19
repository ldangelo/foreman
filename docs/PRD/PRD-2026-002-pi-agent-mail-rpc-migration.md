# PRD-2026-002: Migrate Agent Runtime to Pi + Agent Mail + RPC Control

**Document ID:** PRD-2026-002
**Version:** 1.1
**Status:** Draft (v1.1)
**Date:** 2026-03-19
**Author:** Product Management
**Stakeholders:** Engineering (Foreman maintainers), Agent operators, Security reviewers

---

## Version History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-03-19 | Product Management | Initial draft |
| 1.1 | 2026-03-19 | Product Management | Updated Pi session system (built-in, superior to SDK `persistSession`); updated DCG section to reference existing pi-mono example extensions (`permission-gate.ts`, `sandbox/index.ts`); updated risk register to reflect no capability gaps for session resume or permission controls |

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
9. [Pi Phase Configuration](#9-pi-phase-configuration)
10. [Migration Strategy](#10-migration-strategy)
11. [Security Requirements](#11-security-requirements)
12. [Risks and Mitigations](#12-risks-and-mitigations)
13. [Acceptance Criteria Summary](#13-acceptance-criteria-summary)
14. [Success Metrics](#14-success-metrics)
15. [Release Plan](#15-release-plan)
16. [Open Questions](#16-open-questions)

---

## 1. Executive Summary

Foreman is an AI-powered engineering orchestrator that decomposes work into tasks, dispatches them to Claude agents in isolated git worktrees, and merges results back. Today, agent execution relies on the Anthropic Claude Agent SDK (`@anthropic-ai/claude-agent-sdk`), process spawning via tmux/detached processes, and a custom HTTP notification server for status updates. Inter-agent communication is limited to disk files (EXPLORER_REPORT.md, QA_REPORT.md, etc.) and an unused SQLite messages table.

This PRD proposes migrating the agent runtime to **Pi** (`@mariozechner/pi-coding-agent`), a minimal extensible terminal coding agent with RPC control, 15+ model providers, and a composable extension system. The migration adds **Agent Mail** (`mcp_agent_mail`) for structured inter-agent messaging with file reservation leases, and introduces three custom Pi extensions (`foreman-tool-gate`, `foreman-budget`, `foreman-audit`) that enforce tool restrictions, budget limits, and audit logging at the Pi event level rather than through SDK parameters.

The result is an architecture where Foreman remains the TypeScript orchestrator controlling Pi sessions via JSONL RPC, agents communicate through Agent Mail instead of polling SQLite, and a continuously-running Pi Merge Agent automates branch merging -- eliminating the manual `foreman merge` bottleneck.

A critical fallback requirement ensures that when Pi is not installed, Foreman degrades gracefully to the existing DetachedSpawnStrategy with zero behavior change.

---

## 2. Problem Statement

### 2.1 Fragile Agent Control

Foreman currently spawns agents via two strategies: `TmuxSpawnStrategy` (preferred) and `DetachedSpawnStrategy` (fallback). Both are fire-and-forget -- after spawning a child process, Foreman has no bidirectional communication channel. Liveness detection depends on tmux session existence checks or process polling. The `spawnWorkerProcess()` function in `dispatcher.ts` (lines 808-829) illustrates the cascade: try tmux, if session creation fails fall back to detached, with no RPC protocol to query agent state.

The tmux dependency is particularly fragile. On macOS, tmux is not installed by default. On CI/headless environments, tmux requires special configuration. The `TmuxClient.isAvailable()` check adds latency to every dispatch, and tmux session names are limited to alphanumeric characters, causing issues with seed IDs containing special characters.

### 2.2 Polling Latency

The `NotificationServer` (port-bound HTTP server on loopback) and `NotificationBus` (EventEmitter) provide push notifications, but workers use fire-and-forget HTTP POSTs with a 500ms timeout. When the notification server is unreachable (e.g., `foreman run` has exited), workers fall back to SQLite-based polling via `store.updateRunProgress()` at the `PIPELINE_TIMEOUTS.progressFlushMs` interval (default 2 seconds, configurable). The `foreman status` and `foreman monitor` commands then poll SQLite at `PIPELINE_TIMEOUTS.monitorPollMs` (default 3 seconds).

This creates a minimum 2-5 second delay between an agent completing a phase and the orchestrator becoming aware of it. For the merge workflow, this compounds: branches sit idle until a human runs `foreman merge`.

### 2.3 Manual Merge Bottleneck

`foreman merge` must be run manually after agents complete their work. The `Refinery.mergeCompleted()` method (refinery.ts) performs rebase, auto-resolves report file conflicts, runs tests, and creates PRs for code conflicts -- but only when explicitly invoked. Branches accumulate in "completed" status until a human operator intervenes.

The `SentinelAgent` (sentinel.ts) demonstrates that Foreman already has the daemon pattern (timer-based loop with `start()`/`stop()`) needed for continuous automation, but it is used only for test monitoring, not merge automation.

### 2.4 No Inter-Agent Messaging

The `ForemanStore` has a `messages` table with `sendMessage()`, `getMessages()`, `markMessageRead()` methods (store.ts lines 798-911), but these are never called by the pipeline. Agent phases communicate exclusively through disk files:

- Explorer writes `EXPLORER_REPORT.md` -> Developer reads it
- QA writes `QA_REPORT.md` -> Developer reads it (on retry)
- Reviewer writes `REVIEW.md` -> Pipeline reads verdict

This file-based protocol has no acknowledgment, no threading, no search, and no way for one agent to signal urgency or request clarification from another.

### 2.5 No Audit Trail

Tool calls across pipeline phases are logged to flat files (`~/.foreman/logs/{runId}.log`) via `appendFile()` in `agent-worker.ts`. These logs are unstructured (raw SDK message JSON), not searchable, and not correlated across phases. The `RunProgress` type tracks aggregate counts (`toolCalls`, `toolBreakdown`, `filesChanged`) but not individual tool invocations with arguments and results.

### 2.6 Single Model Provider

The current architecture is locked to Anthropic models through `@anthropic-ai/claude-agent-sdk`. The `ModelSelection` type (`types.ts` line 5) allows only three values: `claude-opus-4-6`, `claude-sonnet-4-6`, and `claude-haiku-4-5-20251001`. Per-phase model selection already exists via `ROLE_CONFIGS` and `FOREMAN_*_MODEL` environment variables, but switching to a non-Anthropic provider (e.g., OpenAI for cost optimization in low-risk phases) requires rewriting the entire agent worker.

---

## 3. Goals and Non-Goals

### 3.1 Goals

1. **Replace tmux/detached process agent control with Pi RPC** -- Foreman spawns `pi --mode rpc` and communicates via JSONL over stdin/stdout, providing bidirectional control, real-time streaming events, and clean session lifecycle management.

2. **Build 3 Pi extensions** that enforce pipeline invariants at the Pi event level:
   - `foreman-tool-gate`: hooks `tool_call` event, blocks disallowed tools per phase (replacing the SDK `disallowedTools` parameter computed by `getDisallowedTools()` in roles.ts)
   - `foreman-budget`: hooks `turn_end` event, enforces hard turn and token limits per phase (replacing the SDK `maxBudgetUsd` parameter)
   - `foreman-audit`: hooks all events, streams structured audit trail to Agent Mail

3. **Integrate Agent Mail** (`mcp_agent_mail`) for inter-agent messaging and file conflict prevention, replacing the unused SQLite messages table and supplementing disk-file communication.

4. **Automate merge via Pi Merge Agent daemon** -- a continuously-running process that listens for "branch-ready" messages on Agent Mail and drives AI-powered conflict resolution, replacing manual `foreman merge` invocation.

5. **Enable per-phase model selection across providers** -- Pi supports 15+ providers (Anthropic, OpenAI, Google, Azure, Bedrock, Mistral, etc.) with mid-session switching via the `set_model` RPC command. This unlocks cost optimization (e.g., GPT-4o-mini for exploration) and capability matching.

6. **Maintain backward compatibility** -- when Pi is not installed, fall back to existing `DetachedSpawnStrategy` with zero behavior change. Users who have not installed Pi experience no regression.

### 3.2 Non-Goals

- **Replacing Foreman's TypeScript codebase with Pi**: Foreman stays as the orchestrator. Pi is the agent runtime controlled by Foreman.
- **Building a generic multi-agent framework**: This migration is Foreman-specific, not a reusable library.
- **Removing SQLite as state store**: SQLite remains for durability (`ForemanStore`). Agent Mail supplements it for messaging and audit.
- **Supporting non-Pi agent runtimes beyond existing fallback**: The only alternative is the existing DetachedSpawnStrategy.
- **Removing disk-file reports**: EXPLORER_REPORT.md, QA_REPORT.md, REVIEW.md continue to be written for backward compatibility. Agent Mail carries the same content as structured messages.
- **Changing the pipeline phase sequence**: Explorer -> Developer <-> QA -> Reviewer -> Finalize remains unchanged.

---

## 4. User Personas

### 4.1 Foreman Operator (Primary)

A DevOps or senior engineer who runs `foreman run` and manages the agent pipeline. Wants reliable agent execution with real-time visibility, automated merging without manual intervention, and a searchable audit trail of all agent actions. Currently frustrated by tmux flakiness on CI, manual merge ceremonies, and opaque agent logs.

### 4.2 Foreman Developer (Secondary)

A contributor building new pipeline features, writing Pi extensions, or adding model providers. Wants a clean extension API with testable components, clear separation between orchestrator logic and agent runtime, and a zero-regression fallback path for development without Pi installed.

### 4.3 Security Reviewer (Stakeholder)

Ensures tool access is properly restricted per phase (Explorer cannot write files via Bash), budget limits are hard-enforced (not advisory), and all agent actions are auditable. Currently relies on the SDK `disallowedTools` parameter, which is only as trustworthy as the SDK's enforcement. Wants enforcement at the agent runtime level (Pi extension) with independent audit logging.

---

## 5. Current State Analysis

### 5.1 Agent Lifecycle (Current)

```
Dispatcher.dispatch()
  |-> createWorktree()
  |-> workerAgentMd() -> TASK.md
  |-> store.createRun()
  |-> spawnWorkerProcess()
        |-> TmuxSpawnStrategy.spawn() OR DetachedSpawnStrategy.spawn()
              |-> child_process.spawn('tsx', ['agent-worker.ts', configPath])
                    |-> agent-worker main()
                          |-> runPipeline() if pipeline=true
                                |-> runPhase('explorer', ...) -> query() -> EXPLORER_REPORT.md
                                |-> runPhase('developer', ...) -> query() -> code changes
                                |-> runPhase('qa', ...) -> query() -> QA_REPORT.md
                                |-> runPhase('reviewer', ...) -> query() -> REVIEW.md
                                |-> finalize: git add/commit/push, br close
                          |-> OR single query() call
```

### 5.2 Key Integration Points

| Component | Current Implementation | File | Lines |
|-----------|----------------------|------|-------|
| Spawn strategies | TmuxSpawnStrategy, DetachedSpawnStrategy | dispatcher.ts | 714-829 |
| SDK query() calls | `import { query } from "@anthropic-ai/claude-agent-sdk"` | agent-worker.ts | 17 |
| Tool restrictions | `getDisallowedTools()` computes complement of allowedTools | roles.ts | 99-102 |
| Budget enforcement | `maxBudgetUsd` SDK parameter per role | roles.ts | 164-201 |
| Phase prompts | `explorerPrompt()`, `developerPrompt()`, `qaPrompt()`, `reviewerPrompt()` | roles.ts | 273-318 |
| Model selection | `ROLE_CONFIGS[role].model` with env var overrides | roles.ts | 125-201 |
| Notifications | NotificationServer (HTTP) + NotificationBus (EventEmitter) | notification-server.ts, notification-bus.ts | all |
| Progress tracking | RunProgress JSON in SQLite `runs.progress` column | store.ts | 72-85 |
| Messages (unused) | SQLite `messages` table with send/receive/read methods | store.ts | 798-911 |
| Merge | Refinery.mergeCompleted() -- manual invocation | refinery.ts | 366-583 |
| Sentinel daemon | SentinelAgent with timer-based start/stop loop | sentinel.ts | 42-282 |

### 5.3 Worker Environment

Workers receive a `WorkerConfig` JSON file containing: `runId`, `projectId`, `seedId`, `seedTitle`, `seedDescription`, `seedComments`, `model`, `worktreePath`, `projectPath`, `prompt`, `env`, `resume`, `pipeline`, `skipExplore`, `skipReview`. The env is sanitized via `buildWorkerEnv()` which strips `CLAUDECODE` and prepends `~/.local/bin` to PATH.

---

## 6. Solution Overview

### 6.0 SDK Feature Coverage

All Claude SDK features used by Foreman are fully covered by Pi equivalents. No capability gaps remain.

| SDK Feature | Pi Equivalent | Coverage Status |
|---|---|---|
| `disallowedTools` per phase | `tool_call` hook (block by `event.toolName`) | Covered — `foreman-tool-gate` extension (extends `permission-gate.ts`) |
| `permissionMode: "acceptEdits"` (DCG) | `permission-gate.ts` + `sandbox/index.ts` example extensions | **Better than SDK** — OS-level sandbox available (`sandbox-exec` / `bubblewrap`) |
| `maxBudgetUsd` | `foreman-budget` extension + `ctx.getContextUsage()` | Covered — token-based approximation (tokens x pricing) |
| Session resume / `persistSession` | `switch_session` RPC + auto-JSONL persistence to `~/.pi/agent/sessions/` | **Better than SDK** — native, built-in, crash-recovery on restart |
| `sessionLogDir` transcript | Pi native JSONL sessions + `foreman-audit` extension | Covered |
| Rate limit → stuck detection | `agent_end` error mapping | Covered |
| Cost/token per phase | `ctx.getContextUsage()` on `turn_end` event | Covered |
| `filesChanged` tracking | `tool_call` hook intercepts Write/Edit events | Covered |

### 6.1 Architecture: Foreman Controls Pi via RPC

```
Foreman (TypeScript orchestrator)
  |
  |-- PiRpcSpawnStrategy
  |     |-> spawn('pi', ['--mode', 'rpc', '--extensions', 'foreman-ext'])
  |     |-> JSONL stdin: { cmd: "prompt", text: "..." }
  |     |-> JSONL stdout: { event: "tool_call", ... }, { event: "turn_end", ... }
  |     |-> JSONL stdin: { cmd: "set_model", model: "claude-sonnet-4-6" }
  |
  |-- Agent Mail Client (HTTP)
  |     |-> POST /register_agent { name: "explorer-{seedId}" }
  |     |-> POST /send_message { to: "developer-{seedId}", body: "..." }
  |     |-> GET /fetch_inbox?agent=merge-agent
  |     |-> POST /file_reservation_paths { paths: ["src/lib/store.ts"], lease: 300 }
  |
  |-- Pi Merge Agent (daemon)
        |-> Subscribes to Agent Mail inbox
        |-> On "branch-ready" message: spawns Pi RPC session for conflict resolution
        |-> Drives T3/T4 merge tiers from refinery.ts
```

### 6.2 Pi Extension Architecture

Pi extensions subscribe to events and can block or modify behavior. The `tool_call` hook API provides the full tool input before execution:

```typescript
pi.on("tool_call", async (event, ctx) => {
  // event.toolName: "bash" | "read" | "edit" | "write" | "grep" etc.
  // event.input: full input object (event.input.command for bash)
  // Returns { block: true, reason: "message" } to block, or undefined to allow
});
```

**Existing pi-mono example extensions** (do not rebuild from scratch):
- `permission-gate.ts` — pattern-matches dangerous bash commands and blocks via `tool_call` hook
- `sandbox/index.ts` — OS-level sandboxing (`sandbox-exec` on macOS, `bubblewrap` on Linux); restricts filesystem writes to CWD + `/tmp`, blocks SSH/AWS credential access, limits network to npm/PyPI/GitHub
- `protected-paths.ts` — blocks writes to sensitive directories
- `dirty-repo-guard.ts` — prevents changes when repo has uncommitted state
- `plan-mode/` — read-only exploration mode (directly applicable to Explorer phase)

The three Foreman extensions extend or compose these:

```typescript
// foreman-tool-gate.ts -- extends permission-gate.ts + protected-paths.ts
export default {
  name: "foreman-tool-gate",
  events: {
    tool_call: (event, context) => {
      const phase = context.getMetadata("foreman-phase");
      const allowed = PHASE_TOOL_MAP[phase];
      if (!allowed.has(event.toolName)) {
        return { block: true, reason: `Tool ${event.toolName} not allowed in ${phase} phase` };
      }
    }
  }
};

// foreman-budget.ts -- enforce hard turn/token limits
export default {
  name: "foreman-budget",
  events: {
    turn_end: (event, context) => {
      const limits = context.getMetadata("foreman-limits");
      if (event.turnNumber >= limits.maxTurns) {
        return { terminate: true, reason: `Turn limit reached: ${limits.maxTurns}` };
      }
      if (event.totalTokens >= limits.maxTokens) {
        return { terminate: true, reason: `Token limit reached: ${limits.maxTokens}` };
      }
    }
  }
};

// foreman-audit.ts -- stream audit trail to Agent Mail
export default {
  name: "foreman-audit",
  events: {
    "*": (event, context) => {
      const agentName = context.getMetadata("foreman-agent-name");
      agentMailClient.send({
        to: "audit-log",
        thread: context.getMetadata("foreman-run-id"),
        body: formatAuditEntry(event),
      });
    }
  }
};
```

### 6.3 Agent Mail Integration

Agent Mail (`mcp_agent_mail`) runs as a FastMCP HTTP server on port 8765. Foreman uses it for:

1. **Phase handoff messages**: Explorer sends report content to Developer's inbox. Developer sends code summary to QA's inbox. Replaces reading EXPLORER_REPORT.md from disk (disk files still written for backward compat).

2. **File reservation leases**: Before Developer starts editing files, it reserves paths via `file_reservation_paths`. QA can check reservations before running tests on files still being edited.

3. **Branch-ready signals**: When the Finalize phase completes (git push succeeds), it sends a "branch-ready" message to the merge-agent inbox. The Pi Merge Agent picks this up and begins merge processing.

4. **Audit trail**: The `foreman-audit` extension streams all tool calls, block decisions, and phase transitions to a dedicated "audit-log" agent inbox. FTS5 indexing makes the audit trail searchable.

### 6.4 Pi Session System (Native — No Custom Extension Required)

Pi ships a **fully built-in session system** that is superior to the Claude SDK's `persistSession` parameter. Session resume is a native capability, not a gap requiring custom extension work.

**How it works:**
- Sessions auto-persist to `~/.pi/agent/sessions/` as versioned JSONL (tree structure with `id`/`parentId`; v1→v2→v3 auto-migrated)
- `switch_session` RPC command resumes a session by ID — Foreman stores the session ID in `runs.session_key` for crash recovery
- `fork` RPC command branches from the current session point — directly applicable to Dev↔QA retry cycles (each retry is a fork, preserving the shared exploration context)
- Pi auto-loads the last session on restart, providing crash recovery without Foreman intervention

**Session lifecycle hooks** available for `foreman-audit` extension:
- `session_start`, `session_before_switch`, `session_switch`, `session_shutdown`
- `session_before_fork`, `session_fork`
- `session_before_compact`, `session_compact`

The `session_shutdown` hook enables the `foreman-audit` extension to checkpoint Foreman-specific metadata (runId, phase, costAccumulator) into the session file before termination.

**RPC session commands:** `new_session`, `switch_session`, `fork`, `get_fork_messages`, `set_session_name`, `get_state`, `export_html`

**Impact on implementation:** The `FOREMAN_PI_REUSE_SESSION` env var described in AC-011-5 can leverage `fork` instead of spawning a new Pi process per phase, preserving shared context while isolating each phase's tool permissions and budget.

### 6.5 Pi Merge Agent

The Pi Merge Agent is a continuously-running daemon (following the `SentinelAgent` pattern from sentinel.ts) that:

1. Polls Agent Mail for "branch-ready" messages in the `merge-agent` inbox
2. For each message, spawns a Pi RPC session to attempt merge
3. Uses the existing `Refinery` conflict resolution tiers (T1-T4)
4. For T3/T4 conflicts requiring AI resolution, drives Pi sessions with conflict context
5. Reports results back via Agent Mail and updates ForemanStore

This replaces the manual `foreman merge` command for the common case. `foreman merge` remains available for manual override and targeted retries.

---

## 7. Functional Requirements

### REQ-001: PiRpcSpawnStrategy

Implement a new spawn strategy that launches Pi in RPC mode (`pi --mode rpc`) as a child process, communicating via JSONL over stdin/stdout. This strategy replaces `TmuxSpawnStrategy` as the preferred spawn method when Pi is installed.

- AC-001-1: Given Pi binary is installed and on PATH, when `spawnWorkerProcess()` is called, then `PiRpcSpawnStrategy.spawn()` is selected and a `pi --mode rpc` child process is started with JSONL communication.
- AC-001-2: Given a PiRpcSpawnStrategy spawn, when the initial prompt is sent via stdin `{ cmd: "prompt", text: "..." }`, then Pi begins executing and streams events via stdout as JSONL lines.
- AC-001-3: Given a running Pi RPC session, when Foreman sends `{ cmd: "set_model", model: "..." }`, then Pi switches the active model for subsequent turns.
- AC-001-4: Given a running Pi RPC session, when Foreman sends `{ cmd: "set_context", files: [...] }`, then Pi updates its context window with the specified files.
- AC-001-5: Given a PiRpcSpawnStrategy spawn, when the Pi process exits (success or error), then Foreman receives the exit event and updates the run status in ForemanStore accordingly.

### REQ-002: Pi Binary Detection and Fallback

The dispatcher must detect whether the `pi` binary is available and fall back to the existing `DetachedSpawnStrategy` when it is not. This ensures zero regression for users without Pi installed.

- AC-002-1: Given Pi binary is NOT on PATH, when `spawnWorkerProcess()` is called, then `DetachedSpawnStrategy.spawn()` is used with identical behavior to the current implementation.
- AC-002-2: Given Pi binary IS on PATH, when `spawnWorkerProcess()` is called, then `PiRpcSpawnStrategy.spawn()` is preferred over `TmuxSpawnStrategy` and `DetachedSpawnStrategy`.
- AC-002-3: Given Pi binary is on PATH but PiRpcSpawnStrategy.spawn() fails, when the failure is detected, then Foreman falls back to `DetachedSpawnStrategy.spawn()` and logs a warning.
- AC-002-4: Given the fallback to DetachedSpawnStrategy, when the agent completes, then all existing behavior (SQLite updates, notification POSTs, br operations) is preserved identically.

### REQ-003: foreman-tool-gate Pi Extension

Build a Pi extension that hooks the `tool_call` event and blocks tools not in the phase's allowed list. This replaces the SDK `disallowedTools` parameter (computed by `getDisallowedTools()` in roles.ts) with enforcement at the Pi runtime level. The extension must be built by extending the existing **`permission-gate.ts`** example from pi-mono (which already handles `rm -rf`, `sudo`, and `chmod 777` pattern matching) combined with **`protected-paths.ts`** (which blocks writes to sensitive directories). Foreman-specific additions on top of those foundations: block `git push --force`, protect `.beads/` directory, and enforce the per-phase tool allowlist via the `tool_call` hook's `event.toolName` and `event.input.command` fields.

- AC-003-1: Given the Explorer phase is active, when Pi attempts to invoke the `Bash` tool, then `foreman-tool-gate` blocks the call and returns a denial reason to Pi.
- AC-003-2: Given the Explorer phase is active, when Pi invokes `Read`, `Grep`, `Glob`, or `LS`, then `foreman-tool-gate` allows the call to proceed.
- AC-003-3: Given the Developer phase is active, when Pi invokes `Read`, `Write`, `Edit`, `Bash`, `Grep`, `Glob`, or `LS`, then `foreman-tool-gate` allows the call to proceed.
- AC-003-4: Given any phase, when `foreman-tool-gate` blocks a tool call, then the block event is logged to the audit trail via Agent Mail with the tool name, phase, and denial reason.
- AC-003-5: Given the phase tool configuration in `ROLE_CONFIGS`, when the extension is loaded, then it reads the allowed tools from the phase metadata set by Foreman via the RPC `set_context` command.

### REQ-004: foreman-budget Pi Extension

Build a Pi extension that hooks the `turn_end` event and enforces hard turn and token limits per phase. When a limit is exceeded, the extension terminates the Pi session. This replaces the SDK `maxBudgetUsd` parameter.

- AC-004-1: Given the Explorer phase with maxTurns=30, when the 30th turn completes, then `foreman-budget` terminates the Pi session with reason "Turn limit reached: 30".
- AC-004-2: Given the Explorer phase with maxTokens=100K, when cumulative token usage exceeds 100,000, then `foreman-budget` terminates the Pi session with reason "Token limit reached".
- AC-004-3: Given a budget termination, when the Pi session ends, then Foreman receives the termination event with the reason and updates the run status to "stuck" (allowing retry).
- AC-004-4: Given phase limits configured via Foreman RPC metadata, when the extension is loaded, then it reads `maxTurns` and `maxTokens` from the phase metadata.
- AC-004-5: Given a budget termination, when the event is fired, then the audit extension logs the termination with current turn count, token usage, and configured limits.

### REQ-005: foreman-audit Pi Extension

Build a Pi extension that hooks all Pi events and streams structured audit entries to Agent Mail. This provides a searchable, correlated audit trail across all pipeline phases.

- AC-005-1: Given any Pi event (tool_call, turn_end, agent_start, agent_end, before_provider_request), when the event fires, then `foreman-audit` sends a structured GFM markdown message to the "audit-log" Agent Mail inbox.
- AC-005-2: Given an audit message, when it is sent to Agent Mail, then it includes: timestamp, run ID, seed ID, phase name, event type, tool name (if applicable), and event-specific details.
- AC-005-3: Given audit messages in Agent Mail, when a user searches via FTS5 for "tool_call Bash" in a specific run thread, then all Bash tool invocations for that run are returned.
- AC-005-4: Given the audit extension, when a tool_call is blocked by foreman-tool-gate, then the audit entry includes the block reason and the attempted tool name.
- AC-005-5: Given a complete pipeline run, when all phases have completed, then the audit trail contains a contiguous record from Explorer start to Finalize completion, threaded by run ID.

### REQ-006: Agent Mail Client Integration

Implement a TypeScript client for the Agent Mail HTTP API that Foreman uses for agent registration, messaging, file reservations, and inbox polling.

- AC-006-1: Given Foreman dispatching a pipeline, when each phase starts, then Foreman registers the phase agent with Agent Mail using the identity `{role}-{seedId}` (e.g., "explorer-bd-1234").
- AC-006-2: Given the Explorer phase completing, when EXPLORER_REPORT.md is written, then Foreman also sends the report content as an Agent Mail message to the `developer-{seedId}` inbox.
- AC-006-3: Given the Developer phase starting, when it checks for context, then it can fetch messages from its Agent Mail inbox as an alternative to reading disk files.
- AC-006-4: Given the Finalize phase completing (git push succeeds), when the branch is ready for merge, then Foreman sends a "branch-ready" message to the `merge-agent` inbox containing: seed ID, branch name, run ID, and commit hash.
- AC-006-5: Given Agent Mail server is not running, when Foreman attempts to send a message, then the failure is silently ignored (fire-and-forget) and the pipeline continues using disk-file communication as before.

### REQ-007: Agent Mail File Reservations

Integrate Agent Mail file reservation leases to prevent concurrent agents from editing the same files and to signal editing intent.

- AC-007-1: Given a Developer phase starting, when it identifies files to modify (from EXPLORER_REPORT.md recommendations), then it creates file reservation leases via Agent Mail for those paths.
- AC-007-2: Given active file reservations, when another agent attempts to reserve an overlapping path, then the reservation request returns a conflict indicating the holding agent and lease expiry.
- AC-007-3: Given a Developer phase completing or failing, when the phase ends, then all file reservations held by that agent are released.
- AC-007-4: Given file reservations are active, when the QA phase starts, then it can query `file_reservation_paths` to understand which files were being edited and verify they are now released.

### REQ-008: Pi Merge Agent Daemon

Implement a continuously-running daemon (following the SentinelAgent pattern) that automates branch merging by listening for "branch-ready" messages on Agent Mail.

- AC-008-1: Given the Pi Merge Agent is running, when a "branch-ready" message arrives in the `merge-agent` Agent Mail inbox, then the daemon dequeues the message and begins merge processing for that branch.
- AC-008-2: Given a branch with no conflicts (T1 clean merge), when the merge agent processes it, then it performs the merge automatically (rebase, fast-forward, test, close bead) without spawning a Pi session.
- AC-008-3: Given a branch with report-only conflicts (T2), when the merge agent processes it, then it auto-resolves report files (accept theirs) and completes the merge programmatically.
- AC-008-4: Given a branch with code conflicts (T3/T4), when the merge agent processes it, then it spawns a Pi RPC session with conflict context to drive AI-assisted resolution, following the existing `ConflictResolver` tier logic.
- AC-008-5: Given the merge agent is running, when `foreman merge` is invoked manually, then the manual command takes precedence (acquires a lock), and the daemon skips that branch.
- AC-008-6: Given the merge agent daemon, when it starts, then it acknowledges all stale "branch-ready" messages from before the daemon started and processes them.
- AC-008-7: Given the merge agent fails to merge a branch after 2 attempts, when the retry limit is exceeded, then it creates a PR for manual resolution (delegating to `Refinery.createPrForConflict()`) and sends a notification message.

### REQ-009: Per-Phase Model Selection via Pi

Replace the current Anthropic-only model selection with Pi's multi-provider model switching via the RPC `set_model` command.

- AC-009-1: Given the Explorer phase, when Pi RPC is initialized, then Foreman sends `{ cmd: "set_model", model: "claude-haiku-4-5-20251001" }` (or the configured model from `FOREMAN_EXPLORER_MODEL` env var).
- AC-009-2: Given the Developer phase, when Pi RPC is initialized, then Foreman sends `{ cmd: "set_model", model: "claude-sonnet-4-6" }` (or the configured override).
- AC-009-3: Given a non-Anthropic model identifier (e.g., `gpt-4o-mini`), when set via `FOREMAN_EXPLORER_MODEL`, then Pi accepts the model string and routes to the appropriate provider.
- AC-009-4: Given model configuration via `ROLE_CONFIGS`, when the `ModelSelection` type is updated, then it accepts any Pi-supported model string rather than the current 3-value union.
- AC-009-5: Given per-phase cost tracking, when each phase completes, then `RunProgress.costByPhase` and `RunProgress.agentByPhase` are updated with the actual model used (which may differ from the Anthropic-only defaults).

### REQ-010: Pipeline Phase Communication via Agent Mail

Enhance the pipeline phase handoff to use Agent Mail messages in addition to disk files, enabling structured, threaded, and searchable communication.

- AC-010-1: Given the Explorer phase completing, when `EXPLORER_REPORT.md` is written, then the report content is also sent as a threaded Agent Mail message with subject "Explorer Report" to the run's message thread.
- AC-010-2: Given the QA phase completing with a FAIL verdict, when the Developer phase is retried, then the QA feedback is available both as disk file (QA_REPORT.md) and as an Agent Mail message with subject "QA Feedback - Retry {n}".
- AC-010-3: Given the Reviewer phase completing, when `REVIEW.md` is written, then the review content is also sent as an Agent Mail message, and the `parseVerdict()` result is included in the message metadata.
- AC-010-4: Given Agent Mail is unavailable, when a phase attempts to send a message, then the phase continues normally using disk-file communication only (no failure, no retry).

### REQ-011: RPC Session Lifecycle Management

Manage Pi RPC session lifecycle including initialization, phase transitions, error handling, and clean shutdown. Pi's built-in session persistence (`~/.pi/agent/sessions/` JSONL) provides crash recovery natively — Foreman stores the Pi session ID in `runs.session_key` to enable `switch_session` resume without custom extension work.

- AC-011-1: Given Foreman starting a pipeline, when the Pi RPC process is spawned, then Foreman sends an initialization sequence: extensions config, phase metadata (role, allowed tools, budget limits), system prompt, and initial prompt.
- AC-011-2: Given a Pi RPC session running, when the session completes normally, then Foreman receives the `agent_end` event with final statistics (turns, tokens, cost) and updates `RunProgress`.
- AC-011-3: Given a Pi RPC session running, when the Pi process crashes or stdin/stdout pipe breaks, then Foreman detects the broken pipe within 5 seconds, marks the run as "stuck", resets the seed to open, and stores the session ID in `runs.session_key` for subsequent `switch_session` resume.
- AC-011-4: Given a Pi RPC session that needs to be terminated (e.g., operator cancellation), when Foreman closes the stdin pipe, then Pi performs a clean shutdown (triggering the `session_shutdown` hook) and the session is properly finalized.
- AC-011-5: Given a multi-phase pipeline, when transitioning from one phase to the next, then Foreman can either (a) reuse the same Pi RPC process with `set_context` and `set_model`, (b) spawn a new Pi process per phase using `switch_session` to resume context, or (c) use the `fork` RPC command to branch from the current session point (preferred for Dev↔QA retries). Configurable via `FOREMAN_PI_SESSION_STRATEGY` env var (`reuse` | `resume` | `fork`).

### REQ-012: Notification System Migration

Replace the custom NotificationServer/NotificationBus with Agent Mail for real-time status updates.

- AC-012-1: Given a pipeline run in progress, when a phase completes, then a status update message is sent to Agent Mail (replacing the HTTP POST to NotificationServer).
- AC-012-2: Given `foreman status` or `foreman monitor` running, when status updates arrive via Agent Mail, then the UI displays them in real time (replacing NotificationBus EventEmitter subscriptions).
- AC-012-3: Given Agent Mail is unavailable, when status updates need to be communicated, then the existing SQLite polling fallback (`getRunProgress()`, `getActiveRuns()`) continues to work identically.
- AC-012-4: Given the migration, when `NotificationServer` and `NotificationBus` are deprecated, then they remain in the codebase (not deleted) for the fallback path, marked with `@deprecated` JSDoc tags.

---

## 8. Non-Functional Requirements

### REQ-013: Extension Package Structure

The three Pi extensions must be packaged as a separate npm package within a `packages/` workspace directory.

- AC-013-1: Given the extension package at `packages/foreman-pi-extensions/`, when `npm install` is run from the project root, then the extensions are built and available for Pi to load.
- AC-013-2: Given the extension package, when it is built, then it produces ESM-compatible output with TypeScript strict mode (no `any` escape hatches).
- AC-013-3: Given the extension package, when unit tests are run, then coverage is at least 80% for tool-gate, budget-enforcer, and audit-logger.

### REQ-014: Agent Mail Server Lifecycle

Agent Mail server lifecycle must be managed by Foreman or run as an independent daemon.

- AC-014-1: Given `foreman init`, when the project is initialized, then the Agent Mail server configuration is stored in `.foreman/agent-mail.json` (port, persistence mode, git sync settings).
- AC-014-2: Given `foreman run`, when agents are about to be dispatched, then Foreman verifies Agent Mail is reachable (health check on configured port) and logs a warning if not.
- AC-014-3: Given Agent Mail server crashing, when Foreman detects the health check failure, then the pipeline continues using disk-file communication and SQLite updates (graceful degradation).

### REQ-015: Performance Requirements

- AC-015-1: Given a PiRpcSpawnStrategy spawn, when the Pi process starts, then the first prompt is sent within 2 seconds of process creation.
- AC-015-2: Given Agent Mail messaging, when a message is sent, then it is visible to the recipient within 500ms (local FastMCP server).
- AC-015-3: Given the Pi Merge Agent daemon, when a "branch-ready" message arrives, then merge processing begins within 5 seconds.
- AC-015-4: Given the foreman-audit extension, when streaming events to Agent Mail, then audit logging adds no more than 50ms of overhead per tool call.

### REQ-016: Observability

- AC-016-1: Given a running pipeline with Pi RPC, when `foreman status` is invoked, then it displays: current phase, turn count, token usage, model, and last tool call -- sourced from Pi RPC streaming events.
- AC-016-2: Given the audit trail in Agent Mail, when `foreman audit <runId>` is invoked (new command), then it displays a chronological list of all tool calls, phase transitions, and block events for that run.
- AC-016-3: Given the Pi Merge Agent daemon, when `foreman merge --status` is invoked, then it displays: daemon running status, pending branch-ready messages, and recent merge results.

---

## 9. Pi Phase Configuration

### REQ-017: Phase-Specific Pi Configuration

Each pipeline phase must have a Pi-specific configuration that maps to the current `ROLE_CONFIGS` structure.

| Phase | Model (Default) | Allowed Tools | Max Turns | Max Tokens | Budget USD |
|-------|----------------|---------------|-----------|------------|------------|
| Explorer | claude-haiku-4-5-20251001 | Read, Grep, Glob, LS, WebFetch, WebSearch | 30 | 100,000 | $1.00 |
| Developer | claude-sonnet-4-6 | Read, Write, Edit, Bash, Grep, Glob, LS | 80 | 500,000 | $5.00 |
| QA | claude-sonnet-4-6 | Read, Grep, Glob, LS, Bash | 30 | 200,000 | $3.00 |
| Reviewer | claude-sonnet-4-6 | Read, Grep, Glob, LS | 20 | 150,000 | $2.00 |

- AC-017-1: Given the phase configuration table, when `PiRpcSpawnStrategy` initializes a phase, then it sends the corresponding model, tool gate config, and budget limits via RPC metadata.
- AC-017-2: Given environment variable overrides (`FOREMAN_EXPLORER_MODEL`, `FOREMAN_EXPLORER_MAX_TURNS`, `FOREMAN_EXPLORER_MAX_TOKENS`), when the phase is configured, then env var values take precedence over defaults.
- AC-017-3: Given the phase configuration, when the `ModelSelection` type is extended, then it accepts any string (Pi resolves provider from model identifier) while keeping the default values as the current Anthropic model strings.

---

## 10. Migration Strategy

### Phase 1: Pi Extensions Package (Week 1-2)

**Scope**: Build the three Pi extensions as a standalone package. The `foreman-tool-gate` extension does **not** start from scratch — it extends the existing `permission-gate.ts` and `protected-paths.ts` example extensions from pi-mono, adding Foreman-specific patterns on top. The `sandbox/index.ts` example (OS-level sandboxing via `sandbox-exec`/`bubblewrap`) should be evaluated for use in the Explorer phase instead of a custom implementation.

**New files**:
- `packages/foreman-pi-extensions/package.json`
- `packages/foreman-pi-extensions/tsconfig.json`
- `packages/foreman-pi-extensions/src/tool-gate.ts` (extends `permission-gate.ts` + `protected-paths.ts`)
- `packages/foreman-pi-extensions/src/budget-enforcer.ts`
- `packages/foreman-pi-extensions/src/audit-logger.ts` (hooks `session_shutdown`, `session_fork` for Pi session events)
- `packages/foreman-pi-extensions/src/index.ts`
- `packages/foreman-pi-extensions/__tests__/tool-gate.test.ts`
- `packages/foreman-pi-extensions/__tests__/budget-enforcer.test.ts`
- `packages/foreman-pi-extensions/__tests__/audit-logger.test.ts`

**Dependencies**: Pi binary installed locally for integration testing.
**Risk**: Pi extension API may change (MIT licensed, active development). Mitigated by pinning Pi version.

### Phase 2: PiRpcSpawnStrategy + Dispatcher Integration (Week 3-4)

**Scope**: Implement `PiRpcSpawnStrategy` and integrate it into the dispatcher's strategy selection.

**New files**:
- `src/orchestrator/pi-rpc-spawn-strategy.ts`
- `src/orchestrator/__tests__/pi-rpc-spawn-strategy.test.ts`

**Modified files**:
- `src/orchestrator/dispatcher.ts` -- update `spawnWorkerProcess()` to prefer PiRpcSpawnStrategy
- `src/orchestrator/types.ts` -- extend `RuntimeSelection` to include `"pi-rpc"`
- `src/orchestrator/roles.ts` -- add `maxTurns` and `maxTokens` to `RoleConfig`

**Strategy selection order** (updated `spawnWorkerProcess()`):
1. If Pi binary available: `PiRpcSpawnStrategy`
2. If Pi spawn fails: fall back to `DetachedSpawnStrategy`
3. If Pi not available: `DetachedSpawnStrategy` directly

**Critical**: TmuxSpawnStrategy is deprecated but not removed. It remains available via a `FOREMAN_SPAWN_STRATEGY=tmux` env var override for users who explicitly prefer it.

### Phase 3: Agent Mail Integration + Phase Messaging (Week 5-6)

**Scope**: Implement Agent Mail client and integrate messaging into the pipeline.

**New files**:
- `src/orchestrator/agent-mail-client.ts`
- `src/orchestrator/__tests__/agent-mail-client.test.ts`

**Modified files**:
- `src/orchestrator/agent-worker.ts` -- add Agent Mail sends after disk-file writes
- `src/orchestrator/agent-worker-finalize.ts` -- send "branch-ready" message
- `src/orchestrator/notification-server.ts` -- mark `@deprecated`
- `src/orchestrator/notification-bus.ts` -- mark `@deprecated`
- `src/cli/commands/status.ts` -- add Agent Mail inbox polling option

**Backward compatibility**: All Agent Mail sends are fire-and-forget. If Agent Mail is down, the pipeline continues using disk files and SQLite updates exactly as today.

### Phase 4: Pi Merge Agent Daemon (Week 7-8)

**Scope**: Implement the merge agent daemon and integrate with Agent Mail.

**New files**:
- `src/orchestrator/merge-agent.ts`
- `src/orchestrator/__tests__/merge-agent.test.ts`
- `src/cli/commands/merge-agent.ts` -- CLI commands for start/stop/status

**Modified files**:
- `src/orchestrator/refinery.ts` -- extract merge logic into reusable functions callable by daemon
- `src/lib/store.ts` -- add `merge_agent_config` table (following sentinel_configs pattern)

**Pattern**: Follows `SentinelAgent` (sentinel.ts) with timer-based loop, `start()`/`stop()`, and PID tracking in SQLite.

---

## 11. Security Requirements

### REQ-018: Tool Restriction Enforcement (P0)

Tool restrictions must be enforced at the Pi extension level, providing defense-in-depth beyond what the orchestrator passes as configuration.

- AC-018-1: Given the Explorer phase, when the `foreman-tool-gate` extension is loaded, then it blocks `Write`, `Edit`, `Bash`, `NotebookEdit`, and all tools not in the Explorer allowed list -- enforcement happens inside the Pi process, not just in Foreman's configuration.
- AC-018-2: Given an attempt to bypass tool restrictions by renaming or aliasing tools, when Pi resolves the tool call, then `foreman-tool-gate` checks against the canonical tool name, not user-provided aliases.
- AC-018-3: Given the tool-gate extension is somehow disabled or fails to load, when Foreman detects the extension is not active (via RPC health check), then the pipeline refuses to start and logs an error.

### REQ-019: Hard Budget Enforcement (P0)

Budget limits must terminate the session, not issue warnings.

- AC-019-1: Given the `foreman-budget` extension, when a turn or token limit is reached, then the Pi session is terminated immediately -- no additional tool calls or turns are allowed.
- AC-019-2: Given a budget termination, when the session ends, then the run is marked as "stuck" (not "failed") in ForemanStore, allowing retry with fresh budget.
- AC-019-3: Given budget tracking, when the `foreman-budget` extension reports usage, then the total tokens and turns are independently verified against Pi's own counters (cross-check).

### REQ-020: Full Audit Trail (P0)

Every agent action must be logged to a searchable, persistent store.

- AC-020-1: Given the `foreman-audit` extension, when any tool is invoked (allowed or blocked), then an audit entry is written to Agent Mail with: timestamp, run ID, phase, tool name, tool arguments (sanitized -- no secrets), and result status.
- AC-020-2: Given audit entries in Agent Mail, when FTS5 search is performed on the audit-log inbox, then entries can be filtered by run ID, phase, tool name, and date range.
- AC-020-3: Given Agent Mail server downtime, when `foreman-audit` cannot reach Agent Mail, then audit entries are buffered locally (written to `~/.foreman/audit-buffer/`) and flushed when Agent Mail recovers.
- AC-020-4: Given a complete pipeline run, when audit entries are reviewed, then the trail covers 100% of tool invocations with no gaps between phases.

### REQ-021: Multi-Model Security (P0)

Per-phase model selection must not weaken security posture.

- AC-021-1: Given a non-Anthropic model configured for a phase, when the phase runs, then tool restrictions and budget limits are still enforced by the Pi extensions (they are model-agnostic).
- AC-021-2: Given model switching via RPC, when `set_model` is sent, then the model change is recorded in the audit trail.

---

## 12. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Pi RPC protocol changes | Medium | High | Pin Pi version in package.json; adapter layer wraps RPC calls |
| Agent Mail server instability | Medium | Medium | Fire-and-forget messaging; full fallback to disk files + SQLite |
| Pi extension API breaking changes | Medium | High | Integration tests against pinned Pi version; vendor lock minimal |
| Merge Agent creates race conditions with manual `foreman merge` | Low | High | File-based lock (`~/.foreman/merge.lock`); daemon yields to manual |
| Pi not available in CI environments | High | Low | Fallback to DetachedSpawnStrategy is transparent |
| Non-Anthropic models behave differently | Medium | Medium | Phase-specific prompt tuning; model validation in integration tests |
| Agent Mail FTS5 index grows unbounded | Low | Medium | Configurable retention policy; auto-archive audit logs older than 30 days |
| Pi stdin/stdout pipe deadlock | Low | High | Async JSONL parsing with backpressure; watchdog timer on stdin writes |
| ~~Session resume requires custom extension work~~ | ~~Medium~~ | ~~High~~ | **Resolved (v1.1):** Pi has a fully built-in session system (`switch_session`, `fork` RPC commands, auto-JSONL persistence). No custom extension needed. |
| ~~DCG/permission controls require building from scratch~~ | ~~Medium~~ | ~~High~~ | **Resolved (v1.1):** pi-mono ships `permission-gate.ts`, `sandbox/index.ts`, and `protected-paths.ts` example extensions. `foreman-tool-gate` extends these rather than building from scratch. |

---

## 13. Acceptance Criteria Summary

| AC ID | Requirement | Description | Phase |
|-------|-------------|-------------|-------|
| AC-001-1 | REQ-001 | Pi RPC process spawned when Pi available | 2 |
| AC-001-2 | REQ-001 | JSONL prompt/response communication | 2 |
| AC-001-3 | REQ-001 | Model switching via RPC set_model | 2 |
| AC-001-4 | REQ-001 | Context update via RPC set_context | 2 |
| AC-001-5 | REQ-001 | Process exit detection and status update | 2 |
| AC-002-1 | REQ-002 | Fallback to DetachedSpawnStrategy when Pi absent | 2 |
| AC-002-2 | REQ-002 | PiRpcSpawnStrategy preferred when Pi present | 2 |
| AC-002-3 | REQ-002 | Fallback on Pi spawn failure | 2 |
| AC-002-4 | REQ-002 | Zero behavior change in fallback mode | 2 |
| AC-003-1 | REQ-003 | Tool-gate blocks Bash in Explorer phase | 1 |
| AC-003-2 | REQ-003 | Tool-gate allows read-only tools in Explorer | 1 |
| AC-003-3 | REQ-003 | Tool-gate allows dev tools in Developer phase | 1 |
| AC-003-4 | REQ-003 | Tool-gate block events logged to audit | 1 |
| AC-003-5 | REQ-003 | Tool-gate reads config from phase metadata | 1 |
| AC-004-1 | REQ-004 | Budget enforcer terminates at turn limit | 1 |
| AC-004-2 | REQ-004 | Budget enforcer terminates at token limit | 1 |
| AC-004-3 | REQ-004 | Budget termination updates run status | 1 |
| AC-004-4 | REQ-004 | Budget reads limits from phase metadata | 1 |
| AC-004-5 | REQ-004 | Budget termination logged to audit | 1 |
| AC-005-1 | REQ-005 | Audit extension hooks all Pi events | 1 |
| AC-005-2 | REQ-005 | Audit messages include structured metadata | 1 |
| AC-005-3 | REQ-005 | Audit trail searchable via FTS5 | 1 |
| AC-005-4 | REQ-005 | Blocked tool calls include denial reason | 1 |
| AC-005-5 | REQ-005 | Contiguous audit trail across phases | 1 |
| AC-006-1 | REQ-006 | Agent registration with Agent Mail | 3 |
| AC-006-2 | REQ-006 | Explorer report sent via Agent Mail | 3 |
| AC-006-3 | REQ-006 | Developer fetches messages from inbox | 3 |
| AC-006-4 | REQ-006 | Branch-ready message sent on finalize | 3 |
| AC-006-5 | REQ-006 | Graceful degradation when Agent Mail down | 3 |
| AC-007-1 | REQ-007 | File reservations created for dev phase | 3 |
| AC-007-2 | REQ-007 | Overlapping reservations return conflict | 3 |
| AC-007-3 | REQ-007 | Reservations released on phase end | 3 |
| AC-007-4 | REQ-007 | QA queries reservation status | 3 |
| AC-008-1 | REQ-008 | Merge agent dequeues branch-ready messages | 4 |
| AC-008-2 | REQ-008 | T1 clean merge automated | 4 |
| AC-008-3 | REQ-008 | T2 report-only conflicts auto-resolved | 4 |
| AC-008-4 | REQ-008 | T3/T4 conflicts use Pi-assisted resolution | 4 |
| AC-008-5 | REQ-008 | Manual merge takes precedence over daemon | 4 |
| AC-008-6 | REQ-008 | Stale messages processed on daemon start | 4 |
| AC-008-7 | REQ-008 | Failed merges create PRs after retry limit | 4 |
| AC-009-1 | REQ-009 | Explorer uses configured model via Pi RPC | 2 |
| AC-009-2 | REQ-009 | Developer uses configured model via Pi RPC | 2 |
| AC-009-3 | REQ-009 | Non-Anthropic models accepted | 2 |
| AC-009-4 | REQ-009 | ModelSelection type extended | 2 |
| AC-009-5 | REQ-009 | Per-phase cost tracking with actual model | 2 |
| AC-010-1 | REQ-010 | Explorer report duplicated to Agent Mail | 3 |
| AC-010-2 | REQ-010 | QA feedback available via Agent Mail | 3 |
| AC-010-3 | REQ-010 | Review verdict in Agent Mail metadata | 3 |
| AC-010-4 | REQ-010 | Graceful degradation for phase messaging | 3 |
| AC-011-1 | REQ-011 | RPC initialization sequence | 2 |
| AC-011-2 | REQ-011 | Clean session completion handling | 2 |
| AC-011-3 | REQ-011 | Broken pipe detection within 5s | 2 |
| AC-011-4 | REQ-011 | Clean shutdown via stdin close | 2 |
| AC-011-5 | REQ-011 | Session reuse configurable | 2 |
| AC-012-1 | REQ-012 | Phase completion via Agent Mail | 3 |
| AC-012-2 | REQ-012 | Real-time status in foreman status/monitor | 3 |
| AC-012-3 | REQ-012 | SQLite polling fallback preserved | 3 |
| AC-012-4 | REQ-012 | NotificationServer/Bus deprecated not deleted | 3 |
| AC-013-1 | REQ-013 | Extension package builds from workspace | 1 |
| AC-013-2 | REQ-013 | ESM output with strict TypeScript | 1 |
| AC-013-3 | REQ-013 | 80% unit test coverage for extensions | 1 |
| AC-014-1 | REQ-014 | Agent Mail config stored in .foreman/ | 3 |
| AC-014-2 | REQ-014 | Health check before dispatch | 3 |
| AC-014-3 | REQ-014 | Graceful degradation on Agent Mail crash | 3 |
| AC-015-1 | REQ-015 | Pi RPC first prompt within 2s | 2 |
| AC-015-2 | REQ-015 | Agent Mail message visible within 500ms | 3 |
| AC-015-3 | REQ-015 | Merge processing begins within 5s | 4 |
| AC-015-4 | REQ-015 | Audit overhead under 50ms per tool call | 1 |
| AC-016-1 | REQ-016 | foreman status shows Pi RPC stats | 2 |
| AC-016-2 | REQ-016 | foreman audit command | 3 |
| AC-016-3 | REQ-016 | foreman merge --status shows daemon state | 4 |
| AC-017-1 | REQ-017 | Phase config sent via RPC metadata | 2 |
| AC-017-2 | REQ-017 | Env var overrides for phase config | 2 |
| AC-017-3 | REQ-017 | ModelSelection extended to any string | 2 |
| AC-018-1 | REQ-018 | Tool-gate blocks all non-allowed tools | 1 |
| AC-018-2 | REQ-018 | Canonical tool name enforcement | 1 |
| AC-018-3 | REQ-018 | Pipeline refuses to start without extension | 2 |
| AC-019-1 | REQ-019 | Hard session termination on budget | 1 |
| AC-019-2 | REQ-019 | Budget termination -> "stuck" status | 1 |
| AC-019-3 | REQ-019 | Cross-check with Pi's own counters | 1 |
| AC-020-1 | REQ-020 | Every tool call audited | 1 |
| AC-020-2 | REQ-020 | FTS5 search on audit entries | 3 |
| AC-020-3 | REQ-020 | Audit buffer on Agent Mail downtime | 3 |
| AC-020-4 | REQ-020 | 100% tool invocation coverage | 1 |
| AC-021-1 | REQ-021 | Extensions enforce regardless of model | 2 |
| AC-021-2 | REQ-021 | Model changes recorded in audit | 2 |

---

## 14. Success Metrics

| Metric | Current Baseline | Target | Measurement |
|--------|-----------------|--------|-------------|
| Agent spawn reliability | ~85% (tmux failures on CI) | 99% (Pi RPC + fallback) | Ratio of successful spawns to dispatch attempts over 30 days |
| Status update latency | 2-5s (SQLite polling) | <500ms (Agent Mail push) | P95 time from phase completion to UI visibility |
| Merge automation rate | 0% (manual only) | 80% of clean merges automated | Ratio of daemon-merged branches to total completed branches |
| Audit coverage | 0% (no structured audit) | 100% of tool calls logged | Ratio of audited tool calls to total tool calls per run |
| Mean time to merge | ~30 min (human dependency) | <5 min for T1/T2, <15 min for T3/T4 | Time from branch-ready to merged status |
| Model cost savings | N/A (Anthropic only) | 15% reduction via provider mixing | Monthly cost comparison before/after multi-model enablement |
| Fallback activation rate | N/A | <5% of dispatches use fallback | Ratio of DetachedSpawnStrategy activations to total dispatches |

---

## 15. Release Plan

| Phase | Timeline | Deliverables | Dependencies | Gate |
|-------|----------|-------------|--------------|------|
| 1 | Week 1-2 | Pi Extensions package (tool-gate, budget, audit) | Pi binary installed | All extension unit tests pass, 80% coverage |
| 2 | Week 3-4 | PiRpcSpawnStrategy + dispatcher integration | Phase 1 complete | E2E test: full pipeline via Pi RPC; fallback test passes |
| 3 | Week 5-6 | Agent Mail integration + phase messaging | Agent Mail server deployed; Phase 2 complete | Messaging works with Agent Mail up; pipeline completes with Agent Mail down |
| 4 | Week 7-8 | Pi Merge Agent daemon | Phases 2 + 3 complete | Daemon auto-merges T1/T2 branches; T3/T4 creates PRs; manual merge lock works |

### Rollout Strategy

1. **Alpha** (internal): Enable Pi RPC via `FOREMAN_SPAWN_STRATEGY=pi-rpc` env var. Existing tmux/detached remains default.
2. **Beta**: Make Pi RPC the default when Pi is installed. Fallback to detached is automatic.
3. **GA**: Document Pi installation as recommended. Deprecate tmux strategy.

---

## 16. Open Questions

| # | Question | Owner | Status |
|---|----------|-------|--------|
| 1 | What is Pi's exact RPC JSONL protocol specification? Published docs reference `--mode rpc` but detailed message schemas need verification. | Engineering | Open |
| 2 | Does Pi's extension system support blocking `tool_call` events, or only observing them? The `foreman-tool-gate` design depends on blocking capability. | Engineering | **Closed (v1.1):** Confirmed — the `tool_call` hook returns `{ block: true, reason: "..." }` to block execution. The `event.input.command` field provides the full bash command string before execution. |
| 3 | Should Agent Mail run as a sidecar (started by `foreman init`) or as an independent system daemon? | DevOps | Open |
| 4 | What is the Agent Mail message size limit? Explorer reports can be 10-50KB. | Engineering | Open |
| 5 | Should the Pi Merge Agent use a dedicated model (e.g., Opus for complex conflict resolution) or inherit from phase config? | Product | Open |
| 6 | How should the `ModelSelection` type be relaxed -- to `string` or to a union of known providers plus `string`? | Engineering | Open |
| 7 | Should we remove the existing `messages` table from SQLite (store.ts) now that Agent Mail replaces it, or keep it for backward compatibility? | Engineering | Open |
| 8 | What is the Pi extension loading mechanism -- filesystem path, npm package, or inline configuration? | Engineering | **Closed (v1.1):** pi-mono ships example extensions that serve as the loading reference. The `foreman-pi-extensions` package extends these directly. |
| 9 | Should Dev↔QA retry cycles use the Pi `fork` RPC command (branch from shared Explorer session) or spawn fresh Pi processes per phase? | Engineering | Open — `fork` is now confirmed available; tradeoff is context sharing vs. isolation. |
| 10 | Which pi-mono sandbox variant should be used for CI (macOS uses `sandbox-exec`, Linux uses `bubblewrap`)? Does the `sandbox/index.ts` extension auto-detect, or does Foreman need to configure it? | Engineering | Open |
