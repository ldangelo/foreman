# PRD: Tmux-Based Session Attachment

**Document ID:** PRD-ATTACH-SESSION
**Version:** 1.1
**Created:** 2026-03-13
**Last Updated:** 2026-03-13
**Status:** Draft (Refined)
**Author:** Product Management

---

## 1. Product Summary

### 1.1 Overview

This PRD enhances Foreman's agent session management by introducing tmux-based agent spawning and interactive session attachment. Today, Foreman agents run as headless detached Node processes with file-descriptor-based logging. The only way to observe a running agent is to tail its log file or poll SQLite for progress updates. The `foreman attach` command resumes an SDK session via `claude --resume`, which takes exclusive control and cannot be safely detached.

This enhancement wraps each agent worker process inside a named tmux session, enabling interactive attachment with safe detach/reattach as the default mode, read-only follow mode for passive observation, TTY-aware auto-attach during dispatch, and robust zombie session detection. The approach is inspired by Overstory's tmux-based agent management while preserving Foreman's existing architecture: TypeScript-orchestrated pipelines, Claude Agent SDK `query()` calls, SQLite state tracking, and isolated git worktrees.

### 1.2 Problem Statement

1. **No live agent visibility.** Agents run as detached processes. The only real-time output is `~/.foreman/logs/<runId>.log`, which requires manual `tail -f` and does not show the interactive Claude session. Users cannot see what an agent is doing right now.

2. **Destructive attach.** `foreman attach <id>` runs `claude --resume <sessionId>`, which takes exclusive control of the SDK session. There is no read-only observation mode. If the user interrupts the resumed session, the agent's work-in-progress may be lost.

3. **No detach/reattach.** Once attached via `claude --resume`, there is no way to detach and return later. The session runs in the foreground until completion or interruption.

4. **No zombie detection at the process level.** The monitor detects stuck agents via timeout heuristics and seed status polling, but cannot detect a dead process whose tmux session or PID no longer exists. A process that crashes silently leaves a "running" row in SQLite until the timeout fires (default: 60 minutes).

5. **Blind dispatching.** `foreman run` dispatches agents and exits (or enters watch mode polling SQLite). There is no option to immediately attach to a spawned agent's terminal for real-time observation.

6. **Session identity is opaque.** Session keys like `foreman:sdk:claude-sonnet-4-6:uuid:session-uuid` are not human-friendly. Users must cross-reference run IDs, seed IDs, and session keys to find the right agent.

### 1.3 Current Architecture

```
Dispatcher.spawnAgent()
  1. Write WorkerConfig JSON to ~/.foreman/tmp/worker-<runId>.json
  2. spawn(tsx, [agent-worker.ts, configPath], { detached: true })
     - stdio: [ignore, outFd, errFd]    -- stdout/stderr to ~/.foreman/logs/<runId>.{out,err}
     - cwd: worktreePath
     - child.unref()                      -- parent exits freely
  3. Worker reads config, runs SDK query() loop
  4. Worker updates SQLite with progress every 2s

foreman attach <id>
  1. Look up run by run-id or seed-id
  2. Extract SDK session ID from session_key
  3. spawn("claude", ["--resume", sessionId], { stdio: "inherit" })
```

**Key files:**
- `src/cli/commands/attach.ts` -- Current attach command (146 lines)
- `src/orchestrator/dispatcher.ts` -- Agent spawning via `spawnWorkerProcess()` (723 lines)
- `src/orchestrator/agent-worker.ts` -- Worker process entry point (872 lines)
- `src/lib/store.ts` -- SQLite store with Run, RunProgress types
- `src/orchestrator/monitor.ts` -- Health monitoring (161 lines)
- `src/cli/commands/run.ts` -- Dispatch CLI with `--no-watch` flag

### 1.4 Value Proposition

| Stakeholder | Current Pain | With Tmux Sessions |
|---|---|---|
| Solo developer | Cannot see what agents are doing in real time | `foreman attach <seed-id>` drops into the agent's tmux session for real-time observation |
| Power user | Must `tail -f` log files across multiple terminals | `foreman attach <seed-id>` drops into the exact tmux session |
| Ops/debugging | Dead agents sit as "running" for up to 60 min | Zombie detection via `tmux has-session` catches dead processes in seconds |
| New user | Opaque session IDs, no visibility into agent behavior | Named sessions (`foreman-<seedId>`) and enhanced listing show exactly what is happening |

---

## 2. User Analysis

### 2.1 User Personas

**Persona 1: Active Monitor (Primary)**
- Runs 3-5 agents simultaneously via `foreman run`
- Wants to glance at agent progress without disrupting work
- Currently relies on `foreman status` (polls SQLite) or `tail -f` log files
- Needs: read-only follow mode, enhanced session listing with phase/cost info

**Persona 2: Debugging Developer (Primary)**
- Agent is stuck or producing incorrect output
- Needs to attach interactively, inspect state, possibly intervene
- Currently uses `foreman attach` which takes exclusive control via `claude --resume`
- Needs: interactive tmux attach with safe detach (Ctrl+B, D), then reattach later

**Persona 3: Hands-Off Operator (Secondary)**
- Dispatches agents and walks away; checks back later
- Cares about completion status and cost, not real-time output
- Current `foreman run --no-watch` workflow works fine
- Needs: tmux sessions that survive terminal closure, zombie cleanup on return

### 2.2 User Pain Points

| Pain Point | Severity | Frequency | Current Workaround |
|---|---|---|---|
| Cannot observe agent output in real time | High | Every dispatch | `tail -f ~/.foreman/logs/<runId>.log` |
| `foreman attach` takes exclusive control | High | When debugging | Avoid attaching; wait for completion |
| Dead agents stay "running" for up to 60 min | Medium | ~10% of runs | `foreman monitor` with manual reset |
| No way to detach and reattach | Medium | When multitasking | Kill and restart the agent |
| Session IDs are not human-readable | Low | When listing sessions | Cross-reference with `foreman status` |

### 2.3 User Journey (Target State)

```
1. Developer dispatches: foreman run --seed foreman-abc1
   - Dispatcher creates tmux session "foreman-abc1"
   - Worker process runs inside tmux session
   - TTY detected: auto-attaches to tmux session interactively
   - User detaches with Ctrl+B, D to let agent continue

2. Later, checks progress: foreman attach --list
   - Shows: foreman-abc1  RUNNING  developer  $0.42  12m  3/15 files

3. Attaches to observe/interact: foreman attach foreman-abc1
   - Attaches to tmux session interactively (default mode)
   - Can observe, scroll buffer, copy text, or interact
   - Ctrl+B, D to detach safely (agent continues)
   - Can reattach any number of times

4. Passive observation: foreman attach --follow foreman-abc1
   - Read-only: polls tmux capture-pane every 1s
   - Shows live agent output without taking control
   - Ctrl+C to stop following (agent continues)

5. Agent crashes: foreman monitor
   - Detects tmux session is gone (tmux has-session fails)
   - Marks run as "zombie", reclaims slot immediately
   - No 60-minute timeout wait
```

---

## 3. Goals and Non-Goals

### 3.1 Goals

| ID | Goal | Success Metric |
|---|---|---|
| G-1 | Enable real-time agent observation without disrupting agent work | Users can follow live output via `--follow` with <2s latency |
| G-2 | Support safe detach/reattach for interactive sessions | Users can detach (Ctrl+B, D) and reattach without losing agent state |
| G-3 | Reduce zombie detection time from ~60 min to <30 seconds | Monitor detects dead tmux sessions via `tmux has-session` in <30s |
| G-4 | Provide human-readable session naming | All sessions named `foreman-<seedId>` with consistent lookup |
| G-5 | Maintain backward compatibility when tmux is not installed | Graceful fallback to current detached-process spawning; all existing behavior preserved |
| G-6 | Enhance session listing with operational context | `--list` shows phase, progress, cost, elapsed time, worktree path |

### 3.2 Non-Goals

| ID | Non-Goal | Rationale |
|---|---|---|
| NG-1 | Replace the SDK `query()` call with a tmux-native approach | Foreman's pipeline phases depend on SDK message streaming for progress tracking; tmux wraps the process, not the SDK |
| NG-2 | Build a full TUI dashboard | Covered by separate PRD (foreman-cc6f observability dashboard) |
| NG-3 | Multi-agent split-pane views (V1) | Deferred to Phase 4 (see Release Plan). Users can use native tmux split panes in the interim |
| NG-4 | Remote session attachment (SSH tunneling) | Local development tool; remote use is out of scope |
| NG-5 | Support screen as an alternative to tmux | tmux is the standard; supporting both multiplexers doubles testing surface |
| NG-6 | Auto-install tmux if missing | Package management is outside Foreman's responsibility; `foreman doctor` will check and warn |

---

## 4. Functional Requirements

### FR-1: Tmux-Based Agent Spawning

**Priority:** Must Have
**Description:** Wrap each agent worker process inside a named tmux session instead of spawning as a bare detached process. The tmux session provides a persistent terminal that survives parent process exit and supports attachment.

**Acceptance Criteria:**
1. When tmux is available, `spawnWorkerProcess()` creates a tmux session named `foreman-<seedId>` and runs the worker inside it.
2. The worker process (tsx agent-worker.ts) runs as the sole command in the tmux session.
3. Existing file-descriptor logging (`~/.foreman/logs/<runId>.{out,err}`) continues to work (tmux does not interfere with stdout/stderr redirection).
4. The tmux session name is stored in the SQLite `runs` table (new column: `tmux_session`).
5. When the worker completes (success or failure), the tmux session remains alive indefinitely for the user to review final output. Cleanup relies on explicit `foreman reset`, `foreman doctor --fix`, or manual `tmux kill-session`.
6. If a tmux session with the same name already exists (from a previous stuck run), it is killed before creating the new one.

**Implementation Notes:**
- Use `tmux new-session -d -s <name> -c <worktreePath> <command>` for detached creation.
- Pipe worker stdout/stderr to log files within the tmux command string (preserves existing logging).
- Store session name in run record for lookup.

---

### FR-2: Graceful Fallback When Tmux Is Unavailable

**Priority:** Must Have
**Description:** If tmux is not installed or not in PATH, fall back to the current detached-process spawning behavior with no functional regression.

**Acceptance Criteria:**
1. At startup, `spawnWorkerProcess()` checks for tmux availability via `which tmux` (cached for process lifetime).
2. If tmux is unavailable, spawning uses the existing `spawn(tsx, [...], { detached: true })` path unchanged.
3. `foreman attach` commands that require tmux print a clear error: "tmux is required for session attachment. Install tmux and retry."
4. `foreman doctor` includes a tmux availability check under a new "Session Management" category.
5. No runtime crashes or unhandled exceptions when tmux is missing.

---

### FR-3: Interactive Session Attachment

**Priority:** Must Have
**Description:** `foreman attach <id>` attaches to the agent's tmux session interactively, replacing the current `claude --resume` behavior when tmux sessions are available.

**Acceptance Criteria:**
1. `foreman attach <run-id|seed-id>` looks up the run's `tmux_session` value and runs `tmux attach-session -t <session>`.
2. The user can interact with the tmux session (observe, scroll buffer, copy text).
3. The user can detach with Ctrl+B, D. The agent continues running uninterrupted.
4. The user can reattach any number of times.
5. If the tmux session does not exist (agent completed or crashed), falls back to `claude --resume <sessionId>` (existing behavior for reviewing completed sessions).
6. If both tmux session and SDK session are unavailable, prints an actionable error message.

---

### FR-4: Read-Only Follow Mode

**Priority:** Must Have
**Description:** `foreman attach --follow <id>` displays live agent output without taking interactive control, using tmux `capture-pane` polling.

**Acceptance Criteria:**
1. `--follow` captures the tmux pane content via `tmux capture-pane -t <session> -p` every 1 second.
2. Only new lines (lines not previously displayed) are printed to the user's terminal.
3. The user exits follow mode with Ctrl+C. The agent continues running.
4. Follow mode displays a header: `Following foreman-<seedId> [phase] | Ctrl+C to stop | foreman attach <id> for interactive`.
5. When the tmux session ends (agent completes), follow mode prints "Session ended" and exits.
6. If the run has no tmux session, falls back to tailing the log file (`~/.foreman/logs/<runId>.log`).

---

### FR-5: TTY-Aware Auto-Attach on Dispatch

**Priority:** Must Have
**Description:** When dispatching a single agent from an interactive terminal, automatically attach to its tmux session interactively for immediate observation and control.

**Acceptance Criteria:**
1. `foreman run --seed <id>` auto-attaches to the tmux session when: (a) stdout is a TTY, (b) only one agent is being dispatched, and (c) `--no-attach` flag is not set.
2. `foreman run --seed <id> --no-attach` skips auto-attach (dispatch and exit).
3. `foreman run --seed <id> --attach` forces auto-attach even when dispatching multiple agents (attaches to the first).
4. `foreman run` (multi-agent, no `--seed`) never auto-attaches; enters watch mode as today.
5. Auto-attach uses interactive mode by default (full tmux attach-session). The user detaches with Ctrl+B, D to let the agent continue in the background.

---

### FR-6: Tmux Session State Tracking

**Priority:** Must Have
**Description:** Track the lifecycle of tmux sessions alongside the existing run status, enabling zombie detection and session health monitoring.

**Acceptance Criteria:**
1. A new column `tmux_session TEXT` is added to the `runs` table (nullable, for backward compatibility).
2. The store exposes `updateRun()` support for the `tmux_session` field.
3. When a run transitions to a terminal state (completed, failed, stuck), the tmux session remains alive for post-mortem review. Cleanup is handled by `foreman reset` or `foreman doctor --fix`.
4. `getActiveRuns()` results include the `tmux_session` value for UI display.

---

### FR-7: Zombie Session Detection and Recovery

**Priority:** Must Have
**Description:** Enhance the monitor to detect zombie tmux sessions (process dead but session still exists, or session gone but run still marked "running") and recover automatically.

**Acceptance Criteria:**
1. `Monitor.checkAll()` performs `tmux has-session -t <session>` for each active run that has a `tmux_session` value.
2. If `has-session` fails (session does not exist) but run status is "running", the run is immediately marked "stuck" (not waiting for timeout).
3. If `has-session` succeeds but the worker process PID is no longer alive (checked via `kill -0`), the tmux session is killed and the run is marked "stuck".
4. Zombie detection runs as part of the existing `foreman monitor` polling cycle.
5. `foreman doctor` includes a "Zombie tmux sessions" check that lists orphaned `foreman-*` tmux sessions with no corresponding active run, and `--fix` kills them.

---

### FR-8: Enhanced Session Listing

**Priority:** Should Have
**Description:** Enhance `foreman attach --list` to show operational context for each session.

**Acceptance Criteria:**
1. Listing includes columns: SEED, STATUS, PHASE, PROGRESS, COST, ELAPSED, TMUX, WORKTREE.
2. PHASE shows the current pipeline phase (explorer, developer, qa, reviewer, finalize) from `RunProgress.currentPhase`.
3. PROGRESS shows tool calls and files changed (e.g., "42 tools, 8 files").
4. COST shows `costUsd` formatted as `$0.42`.
5. ELAPSED shows time since `started_at` in human-readable format (e.g., "12m", "1h 23m").
6. TMUX shows the tmux session name or "(none)" if no tmux session.
7. Rows are sorted by status (running first, then stuck, then completed) and then by recency.

---

### FR-9: Named Session Convention

**Priority:** Must Have
**Description:** Use a consistent, human-readable naming convention for tmux sessions.

**Acceptance Criteria:**
1. Session name format: `foreman-<seedId>` (e.g., `foreman-abc1`).
2. If the seed ID contains characters invalid for tmux session names (colons, periods), they are replaced with hyphens.
3. Session names are unique per project (enforced by killing existing sessions with the same name before creating new ones, per FR-1 AC-6).
4. `foreman attach` accepts the seed ID directly (e.g., `foreman attach abc1`) and resolves to the tmux session name `foreman-abc1`.

---

### FR-10: Session Persistence and Cleanup

**Priority:** Must Have
**Description:** Tmux sessions persist after agent completion for post-mortem review. Cleanup is explicit, not automatic.

**Acceptance Criteria:**
1. After the worker process exits (in `agent-worker.ts`), the tmux session remains alive indefinitely. The user can attach to review final output, scroll history, and inspect the terminal state.
2. `foreman reset` kills all `foreman-*` tmux sessions as part of its cleanup.
3. `foreman doctor --fix` kills orphaned `foreman-*` tmux sessions that have no corresponding active run.
4. `foreman attach --list` shows completed sessions with a "COMPLETED" or "FAILED" status tag so users know which sessions are available for review.
5. Users can manually kill individual sessions via `foreman attach --kill <id>` or native `tmux kill-session -t foreman-<seedId>`.

---

## 5. Non-Functional Requirements

### NFR-1: Performance

| Metric | Target | Rationale |
|---|---|---|
| Tmux session creation overhead | <200ms added to dispatch | Must not noticeably slow down `foreman run` |
| Follow mode latency | <2s from agent output to user display | `capture-pane` polling at 1s interval |
| Zombie detection speed | <30s from process death to status update | `has-session` check per monitor cycle |
| Session listing render time | <500ms for 20 sessions | Must feel instant for typical workloads |

### NFR-2: Reliability

| Requirement | Description |
|---|---|
| Crash safety | If foreman crashes, tmux sessions continue running; agents complete their work |
| Idempotent cleanup | `foreman reset` and `foreman doctor --fix` can be run multiple times safely |
| Concurrent access | Multiple `foreman attach --follow` calls to the same session work independently |
| Log preservation | tmux wrapping does not interfere with existing log file output |

### NFR-3: Compatibility

| Requirement | Description |
|---|---|
| tmux version | Supports tmux >= 3.0 (macOS Homebrew default, Ubuntu 20.04+) |
| macOS + Linux | Works on both platforms (primary: macOS via Homebrew) |
| Existing workflows | All current `foreman run`, `foreman attach`, `foreman status` behaviors preserved when tmux is unavailable |
| SQLite schema | New column added via migration; existing databases upgraded seamlessly |

### NFR-4: Observability

| Requirement | Description |
|---|---|
| Session events | `tmux_session_created`, `tmux_session_killed`, `tmux_zombie_detected` events logged to SQLite events table |
| Doctor checks | `foreman doctor` reports tmux availability, orphaned sessions, and session/run mismatches |

---

## 6. CLI Interface Specification

### 6.1 Modified Commands

#### `foreman run`

```
foreman run [options]

New options:
  --attach         Force auto-attach to first dispatched agent's tmux session
  --no-attach      Skip auto-attach even for single-agent dispatch from TTY

Behavior changes:
  - When --seed <id> is used from a TTY, auto-attaches interactively (unless --no-attach)
  - Multi-agent dispatch: no change (enters watch mode)
```

#### `foreman attach`

```
foreman attach <run-id|seed-id> [options]

Existing options (preserved):
  --list           List all attachable sessions
  --worktree       Open shell in agent's worktree

New options:
  --follow         Follow agent output in read-only mode (polls tmux capture-pane)
  --kill           Kill the tmux session for a completed/stuck run

Behavior changes:
  - Default: interactive tmux attach-session (was: claude --resume)
  - Falls back to claude --resume if no tmux session exists
  - --list output enhanced with phase, cost, elapsed time columns
  - Completed sessions remain available for post-mortem review
```

#### `foreman reset`

```
Behavior changes:
  - Additionally kills all foreman-* tmux sessions during cleanup
```

#### `foreman doctor`

```
New checks:
  - [Session Management] tmux availability
  - [Session Management] Orphaned tmux sessions (foreman-* with no active run)
  - [Session Management] Ghost runs (active run with dead tmux session)

--fix behavior:
  - Kills orphaned tmux sessions
  - Marks ghost runs as "stuck"
```

#### `foreman monitor`

```
Behavior changes:
  - Checks tmux session liveness for runs with tmux_session set
  - Immediately marks runs as stuck when tmux session is gone (no timeout wait)
```

### 6.2 Environment Variables

| Variable | Default | Description |
|---|---|---|
| `FOREMAN_TMUX_FOLLOW_INTERVAL_MS` | `1000` | Polling interval for `--follow` mode capture-pane |
| `FOREMAN_TMUX_DISABLED` | `false` | Force disable tmux wrapping (use detached process spawning) |

---

## 7. Error Handling

| Scenario | Detection | Response | User Message |
|---|---|---|---|
| tmux not installed | `which tmux` fails at spawn time | Fall back to detached process | `[foreman] tmux not found -- spawning agent as detached process (install tmux for session attachment)` |
| tmux session creation fails | `tmux new-session` exits non-zero | Fall back to detached process; log warning | `[foreman] tmux session creation failed -- falling back to detached process` |
| Attach to non-existent session | `tmux has-session` fails | Fall back to `claude --resume` if session ID available; error otherwise | `Tmux session not found. Falling back to SDK session resume.` or `No active session found for "<id>".` |
| Follow mode on completed agent | tmux session gone, log file exists | Tail log file instead | `Session ended. Showing final log output from ~/.foreman/logs/<runId>.log` |
| Follow mode on agent without tmux | No `tmux_session` in run record | Tail log file | `No tmux session for this run. Tailing log file instead.` |
| Duplicate session name | `tmux has-session` succeeds for name | Kill existing session before creating new one | `[foreman] Killed stale tmux session foreman-<seedId>` |
| Accumulated completed sessions | Many completed tmux sessions consuming resources | `foreman doctor --fix` or `foreman reset` cleans them up | `[foreman] Cleaned up N completed tmux sessions` |
| Worker crashes inside tmux | Process exits non-zero; tmux session goes to shell or exits | Monitor detects via `has-session` or PID check | `[foreman] Agent foreman-<seedId> process died. Marking as stuck.` |
| `FOREMAN_TMUX_DISABLED=true` | Env var check at spawn time | Use detached process spawning | `[foreman] tmux disabled via FOREMAN_TMUX_DISABLED` |

---

## 8. Test Scenarios

### 8.1 Unit Tests

| ID | Test | Location |
|---|---|---|
| UT-1 | `tmuxSessionName()` sanitizes seed IDs with special characters | `src/lib/__tests__/tmux.test.ts` |
| UT-2 | `isTmuxAvailable()` returns false when tmux not in PATH | `src/lib/__tests__/tmux.test.ts` |
| UT-3 | `spawnWorkerProcess()` includes `tmux_session` in run record when tmux available | `src/orchestrator/__tests__/dispatcher.test.ts` |
| UT-4 | `spawnWorkerProcess()` falls back to detached process when tmux unavailable | `src/orchestrator/__tests__/dispatcher.test.ts` |
| UT-5 | Enhanced `--list` output includes phase, cost, elapsed columns | `src/cli/__tests__/attach.test.ts` |
| UT-6 | `tmux_session` column migration is idempotent | `src/lib/__tests__/store.test.ts` |

### 8.2 Integration Tests

| ID | Test | Location |
|---|---|---|
| IT-1 | Dispatch agent -> tmux session created -> attach -> detach -> agent continues -> completes | `src/orchestrator/__tests__/tmux-integration.test.ts` |
| IT-2 | Dispatch without tmux -> detached process (existing behavior preserved) | `src/orchestrator/__tests__/tmux-integration.test.ts` |
| IT-3 | Agent crashes -> monitor detects dead session -> marks stuck | `src/orchestrator/__tests__/tmux-integration.test.ts` |
| IT-4 | Follow mode captures new output lines only (no duplicates) | `src/cli/__tests__/attach-follow.test.ts` |
| IT-5 | Completed agent tmux session persists for post-mortem review | `src/orchestrator/__tests__/tmux-integration.test.ts` |
| IT-6 | `foreman doctor --fix` kills orphaned tmux sessions | `src/cli/__tests__/doctor-tmux.test.ts` |
| IT-7 | `foreman reset` kills all foreman-* tmux sessions | `src/cli/__tests__/reset-tmux.test.ts` |

### 8.3 Manual Verification

| ID | Scenario |
|---|---|
| MV-1 | Dispatch agent, attach interactively, detach with Ctrl+B D, reattach, verify agent continued working |
| MV-2 | Use `--follow` mode on a running agent, verify output updates every ~1s, Ctrl+C to stop, agent unaffected |
| MV-3 | Kill agent process manually (`kill -9`), run `foreman monitor`, verify immediate stuck detection |
| MV-4 | Dispatch with `--no-attach` from TTY, verify no auto-attach |
| MV-5 | Run on system without tmux installed, verify all existing behavior works |

---

## 9. Implementation Notes

### 9.1 New Files

| File | Purpose |
|---|---|
| `src/lib/tmux.ts` | Tmux utility functions: `isTmuxAvailable()`, `createSession()`, `killSession()`, `hasSession()`, `capturePaneOutput()`, `tmuxSessionName()`, `listForemanSessions()` |
| `src/lib/__tests__/tmux.test.ts` | Unit tests for tmux utilities |
| `src/orchestrator/__tests__/tmux-integration.test.ts` | Integration tests for tmux-based spawning and monitoring |
| `src/cli/__tests__/attach-follow.test.ts` | Tests for follow mode |

### 9.2 Modified Files

| File | Changes |
|---|---|
| `src/orchestrator/dispatcher.ts` | `spawnWorkerProcess()`: add tmux session creation path with fallback; store `tmux_session` in run record |
| `src/orchestrator/agent-worker.ts` | No tmux cleanup on exit — sessions persist for post-mortem review. Worker exits normally; tmux session stays alive. |
| `src/cli/commands/attach.ts` | Replace `claude --resume` default with `tmux attach-session`; add `--follow` and `--interactive` options; enhance `--list` output |
| `src/cli/commands/run.ts` | Add `--attach` / `--no-attach` flags; implement TTY-aware auto-attach |
| `src/cli/commands/reset.ts` | Add tmux session cleanup (`tmux kill-server` for foreman sessions or iterate and kill) |
| `src/cli/commands/doctor.ts` | Add Session Management health checks |
| `src/orchestrator/monitor.ts` | Add `tmux has-session` liveness check for runs with `tmux_session` |
| `src/lib/store.ts` | Add `tmux_session TEXT` column migration; update `updateRun()` to support the new field |

### 9.3 Reuse Opportunities

| Component | Reuse |
|---|---|
| `spawnWorkerProcess()` | Refactor to accept a `SpawnStrategy` interface; `TmuxSpawnStrategy` and `DetachedSpawnStrategy` implementations share config serialization and logging setup |
| `Monitor.checkAll()` | Existing loop iterates active runs; add tmux health check alongside seed-status check |
| `ForemanStore` migrations | Follow existing `MIGRATIONS` array pattern for idempotent `ALTER TABLE` |
| `buildWorkerEnv()` | Reuse as-is; tmux inherits the worker's environment |
| `NotificationClient` | No changes needed; HTTP notifications work the same inside tmux |

### 9.4 SQLite Schema Change

```sql
-- Migration (idempotent via ALTER TABLE failure pattern)
ALTER TABLE runs ADD COLUMN tmux_session TEXT DEFAULT NULL;
```

---

## 10. Resolved Decisions

| ID | Decision | Rationale | Alternatives Considered |
|---|---|---|---|
| RD-1 | Use tmux for session wrapping, not a custom PTY multiplexer | tmux is battle-tested, widely installed, and provides detach/reattach natively. Building a custom PTY solution would be months of work with inferior reliability. | Custom PTY via `node-pty`; `screen`; raw PTY forwarding |
| RD-2 | Default to interactive mode for all attachment (attach and auto-attach) | Users prefer direct control and the ability to observe, scroll, and interact immediately. Follow mode available via `--follow` for passive observation. tmux's native Ctrl+B, D detach makes interactive mode safe. | Follow mode by default; no auto-attach |
| RD-3 | Keep existing file-descriptor logging alongside tmux | Log files are the authoritative record for debugging and the watch UI. Tmux provides real-time visibility. Both serve different needs. | Replace log files with tmux capture; tmux-only logging |
| RD-4 | Sessions persist indefinitely after agent completion | Users want full access to completed session output for post-mortem review without time pressure. Cleanup is explicit via `foreman reset`, `foreman doctor --fix`, or `foreman attach --kill`. | 30-second grace period; 5-minute grace; immediate kill |
| RD-5 | Store `tmux_session` in the runs table, not a separate table | One-to-one relationship with runs; adding a column is simpler than a join table. Nullable column ensures backward compatibility. | Separate `tmux_sessions` table; store in progress JSON |
| RD-6 | Fall back to detached process when tmux unavailable, not error | Foreman should work in CI/CD environments and containers where tmux is not installed. Erroring would break existing workflows. | Require tmux; auto-install tmux; error with instructions |
| RD-7 | Session naming uses seed ID, not run ID | Seed IDs are stable, human-assigned identifiers. Run IDs are UUIDs. Users think in terms of tasks (seeds), not execution instances (runs). Conflicts resolved by killing stale sessions. | Run ID naming; compound naming (`foreman-<seedId>-<shortRunId>`) |
| RD-8 | Follow mode uses `tmux capture-pane` polling, not a log file tail | `capture-pane` shows exactly what the agent's terminal displays, including formatted output. Log files contain structured event logs, not the agent's interactive output. | `tail -f` on log file; tmux pipe-pane to a FIFO; WebSocket streaming |
| RD-9 | Auto-attach only for single-agent dispatch (`--seed`) | Multi-agent dispatch should enter watch mode (overview of all agents). Single-agent dispatch is the "I want to watch this one task" use case. | Always auto-attach to first agent; never auto-attach; prompt user |
| RD-10 | Session cleanup is explicit, not automatic | Sessions persist after agent completion so users can review output at their leisure. `foreman reset` and `foreman doctor --fix` handle bulk cleanup. `foreman attach --kill` handles individual cleanup. | Auto-cleanup via grace period; dispatcher cleanup via polling; external cron |

---

## 11. Risks and Mitigations

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| tmux not available in user's environment | Medium | Low | Graceful fallback (FR-2); `foreman doctor` check; clear messaging |
| tmux version incompatibility (<3.0) | Low | Medium | Document minimum version; test on tmux 3.0+; `foreman doctor` checks version |
| Session name collisions across projects | Low | Low | Seed IDs are unique within a project; cross-project collisions unlikely with short-ID format |
| Performance overhead of tmux wrapping | Low | Low | Measured at <200ms; negligible compared to SDK startup time |
| User confusion: follow vs interactive mode | Low | Low | Interactive is the universal default; follow mode is opt-in via `--follow`. Clear CLI help text. |
| Accumulated completed sessions consuming resources | Medium | Medium | `foreman doctor --fix`; `foreman reset`; `foreman attach --kill`; monitor zombie detection. `foreman doctor` warns when >10 completed sessions exist. |

---

## 12. Release Plan

### Phase 1: Core Tmux Spawning (MVP)
- FR-1: Tmux-based agent spawning
- FR-2: Graceful fallback
- FR-6: Session state tracking (schema migration)
- FR-9: Named session convention
- FR-10: Session cleanup on completion

### Phase 2: Attachment Experience
- FR-3: Interactive session attachment
- FR-4: Read-only follow mode
- FR-8: Enhanced session listing

### Phase 3: Smart Dispatch and Monitoring
- FR-5: TTY-aware auto-attach (interactive mode)
- FR-7: Zombie session detection and recovery
- Doctor checks and reset integration

### Phase 4: Multi-Agent Views (Future)
- Multi-agent split-pane layout via `foreman attach --all`
- Automatic tmux split-pane creation for concurrent agents
- Per-pane status headers showing phase, cost, progress

---

## 13. Success Metrics

| Metric | Target | Measurement |
|---|---|---|
| Zombie detection time | <30 seconds (from 60 min) | Time from process death to run status change in SQLite |
| Session attachment adoption | >70% of active runs are attached to at least once | CLI usage telemetry (opt-in) |
| User-reported visibility satisfaction | >80% positive | Post-launch survey |
| Fallback rate (tmux unavailable) | <10% of users | `foreman doctor` reports aggregated in issue tracker |
| Zero regressions | 0 existing test failures | CI pipeline |

---

## 14. Version History

| Version | Date | Changes |
|---|---|---|
| 1.0 | 2026-03-13 | Initial draft with 10 functional requirements |
| 1.1 | 2026-03-13 | Refined based on stakeholder interview: (1) Changed default attach mode from follow to interactive everywhere — both `foreman attach` and auto-attach on dispatch now use interactive tmux sessions by default. (2) Removed 30-second grace period — tmux sessions now persist indefinitely after agent completion for post-mortem review; cleanup is explicit via `foreman reset`, `foreman doctor --fix`, or `foreman attach --kill`. (3) Elevated FR-5 (TTY-aware auto-attach) from "Should Have" to "Must Have". (4) Moved multi-agent split-pane views from non-goal to Phase 4 future work in the release plan. (5) Added `--kill` option to `foreman attach` for individual session cleanup. (6) Updated resolved decisions RD-2, RD-4, RD-10 to reflect new defaults. |
