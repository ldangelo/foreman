# TRD: Tmux-Based Session Attachment

**Document ID:** TRD-ATTACH-SESSION
**Version:** 1.1
**Created:** 2026-03-13
**Last Updated:** 2026-03-13
**PRD Reference:** PRD-ATTACH-SESSION v1.1
**Status:** Implementation Ready

---

## 1. System Architecture

### 1.1 Architecture Overview

The attach-session system introduces tmux-based agent wrapping and interactive session attachment across six modified commands and one new utility module. The architecture preserves the existing TypeScript-orchestrated pipeline and Claude Agent SDK `query()` loop while wrapping each worker process inside a named tmux session for persistent, detachable terminal access.

```
foreman run --bead <id> (CLI)
  |
  v
Dispatcher.spawnWorkerProcess()
  |-- TmuxClient.isAvailable()  -- cached tmux availability check
  |-- TmuxClient.createSession(name, cmd, cwd)  -- tmux new-session -d -s ...
  |   OR spawn(tsx, [...], { detached: true })   -- fallback when tmux unavailable
  |-- store.updateRun({ tmux_session })          -- persist session name
  |
  v
Agent Worker (runs inside tmux session)
  |-- SDK query() loop (unchanged)
  |-- Progress updates to SQLite (unchanged)
  |-- On exit: tmux session persists for post-mortem review
  |
  v
foreman attach <id> (CLI)
  |-- store.getRun(id) → run.tmux_session
  |-- DEFAULT: tmux attach-session -t <session>  -- interactive mode
  |-- --follow: TmuxClient.capturePaneOutput() polling loop
  |-- --kill: TmuxClient.killSession()
  |-- FALLBACK: claude --resume <sessionId>      -- when no tmux session

foreman monitor / foreman doctor
  |-- TmuxClient.hasSession(name) -- liveness check
  |-- Zombie detection: session gone → mark stuck immediately
  |-- Orphan detection: foreman-* session with no active run
```

### 1.2 New Module Structure

| File | Purpose | Dependencies |
|------|---------|-------------|
| `src/lib/tmux.ts` | Tmux utility class: availability check, session CRUD, capture-pane, session listing, name sanitization | -- (shells out to `tmux` binary) |

### 1.3 Data Flow

```
Dispatch Flow:
  CLI (foreman run)
    |
    +--> Dispatcher.spawnAgent()
    |      |
    |      +--> TmuxClient.isAvailable() → boolean (cached)
    |      |
    |      +--> [tmux available]
    |      |      +--> TmuxClient.killSession(name)     -- kill stale session if exists
    |      |      +--> TmuxClient.createSession(name, cmd, cwd)
    |      |      +--> store.updateRun({ tmux_session: name })
    |      |
    |      +--> [tmux unavailable or FOREMAN_TMUX_DISABLED]
    |             +--> spawn(tsx, [...], { detached: true })  -- existing path
    |
    +--> [TTY + single agent + --seed]
           +--> tmux attach-session -t <name>  -- auto-attach interactively

Attachment Flow:
  CLI (foreman attach <id>)
    |
    +--> store.getRun(id) → Run { tmux_session, session_key }
    |
    +--> [tmux_session exists + tmux has-session succeeds]
    |      +--> DEFAULT: tmux attach-session -t <session>
    |      +--> --follow: capturePaneOutput() poll loop
    |      +--> --kill: tmux kill-session -t <session>
    |
    +--> [tmux_session missing or session dead]
           +--> claude --resume <sessionId>  -- existing fallback

Monitor Flow:
  Monitor.checkAll()
    |
    +--> for each active run with tmux_session:
           +--> TmuxClient.hasSession(name)
           |      +--> false → mark run "stuck" immediately (no timeout wait)
           +--> [has-session true] → continue existing seed-status check
```

### 1.4 Type Definitions

```typescript
// ── Tmux Client types ───────────────────────────────────────────────

/** Options for creating a new tmux session */
interface TmuxSpawnOptions {
  sessionName: string;         // e.g., "foreman-abc1"
  command: string;             // Full command string to run inside tmux
  cwd: string;                 // Working directory (worktree path)
  env?: Record<string, string>; // Environment variables for the session
}

/** Result of creating a tmux session */
interface TmuxCreateResult {
  sessionName: string;         // The sanitized session name
  created: boolean;            // true if session was created, false if fallback used
}

/** Information about an active tmux session */
interface TmuxSessionInfo {
  sessionName: string;         // tmux session name
  created: string;             // Session creation timestamp
  attached: boolean;           // Whether a client is currently attached
  windowCount: number;         // Number of windows in the session
}

/** Options for follow mode polling */
interface FollowOptions {
  sessionName: string;         // tmux session to follow
  intervalMs: number;          // Polling interval (default: 1000)
  onOutput: (lines: string[]) => void;  // Callback for new output lines
  onEnd: () => void;           // Callback when session ends
  signal: AbortSignal;         // For cancellation (Ctrl+C)
}

// ── Spawn Strategy types (dispatcher.ts) ─────────────────────────

/** Strategy interface for worker process spawning */
interface SpawnStrategy {
  spawn(config: WorkerConfig): Promise<SpawnResult>;
}

interface SpawnResult {
  tmuxSession?: string;         // Set if spawned inside a tmux session
}

/** Spawns worker inside a named tmux session */
class TmuxSpawnStrategy implements SpawnStrategy {
  constructor(private tmux: TmuxClient) {}
  async spawn(config: WorkerConfig): Promise<SpawnResult> { /* ... */ }
}

/** Spawns worker as a bare detached process (existing behavior) */
class DetachedSpawnStrategy implements SpawnStrategy {
  async spawn(config: WorkerConfig): Promise<SpawnResult> { /* ... */ }
}

// ── Extended Run interface (store.ts addition) ──────────────────────

// Add to existing Run interface in store.ts:
// tmux_session: string | null;   // Tmux session name, null if spawned without tmux

// ── Enhanced attach command types ───────────────────────────────────

/** Options for the enhanced attach command */
interface AttachOptions {
  list?: boolean;              // List all attachable sessions
  follow?: boolean;            // Read-only follow mode via capture-pane polling
  kill?: boolean;              // Kill the tmux session
  worktree?: boolean;          // Open shell in worktree (existing)
}

/** A row in the enhanced session listing */
interface SessionListRow {
  seedId: string;
  status: string;              // running, completed, failed, stuck
  phase: string;               // explorer, developer, qa, reviewer, finalize
  progress: string;            // "42 tools, 8 files"
  cost: string;                // "$0.42"
  elapsed: string;             // "12m", "1h 23m"
  tmuxSession: string;         // Session name or "(none)"
  worktree: string;            // Worktree path
}

// ── Doctor check types ──────────────────────────────────────────────

/** Session management health check result */
interface SessionHealthCheck {
  tmuxAvailable: boolean;
  tmuxVersion: string | null;
  orphanedSessions: string[];     // foreman-* sessions with no active run
  ghostRuns: string[];            // Active runs with dead tmux sessions
}
```

### 1.5 Integration Points

| Integration | Direction | Mechanism |
|------------|-----------|-----------|
| Dispatcher -> TmuxClient | Internal | `isAvailable()`, `createSession()`, `killSession()` |
| Attach CLI -> TmuxClient | Internal | `hasSession()`, `capturePaneOutput()`, `killSession()` |
| Monitor -> TmuxClient | Internal | `hasSession()` for liveness checks |
| Doctor -> TmuxClient | Internal | `listForemanSessions()`, `hasSession()`, `killSession()` |
| Reset -> TmuxClient | Internal | `listForemanSessions()`, `killSession()` |
| Run CLI -> Dispatcher | Internal | `--attach`/`--no-attach` flags passed through |
| Store -> SQLite | Outbound | `ALTER TABLE runs ADD COLUMN tmux_session TEXT` |

### 1.6 Error Code System

All tmux errors use structured codes `TMUX-001` through `TMUX-012`. Error codes appear in CLI stderr output and event log details.

| Code | Scenario | Severity | Response |
|------|----------|----------|----------|
| TMUX-001 | tmux binary not found in PATH | Info | Fall back to detached process spawning |
| TMUX-002 | tmux new-session command failed | Warning | Fall back to detached process spawning; log warning |
| TMUX-003 | tmux attach-session failed (session does not exist) | Warning | Fall back to `claude --resume` |
| TMUX-004 | tmux capture-pane failed | Warning | Fall back to tailing log file |
| TMUX-005 | tmux kill-session failed | Warning | Log warning; session may already be dead |
| TMUX-006 | tmux has-session reports dead session for active run | Error | Mark run as stuck; log event |
| TMUX-007 | Orphaned tmux session detected (no matching active run) | Warning | Report in doctor; `--fix` kills session |
| TMUX-008 | Ghost run detected (active run, dead tmux session) | Error | Report in doctor; `--fix` marks run stuck |
| TMUX-009 | Session name collision (stale session exists) | Info | Kill stale session before creating new one |
| TMUX-010 | tmux version too old (< 3.0) | Warning | Report in doctor; may work but unsupported |
| TMUX-011 | FOREMAN_TMUX_DISABLED is set | Info | Skip tmux wrapping; use detached process |
| TMUX-012 | Follow mode interrupted (Ctrl+C) | Info | Clean exit; agent continues running |

---

## 2. Master Task List

### Legend

- `[ ]` Not started
- `[~]` In progress
- `[x]` Completed

### 2.1 Sprint 1: Foundation -- Tmux Utilities + Schema Migration (FR-2, FR-6, FR-9)

#### Story 1.1: Tmux Client Utility Module

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T001 | Implement `TmuxClient` class with `isAvailable()` method. Check for tmux binary via `which tmux` (or `command -v tmux`). Cache the result for the process lifetime using a module-level `let` variable. Return `false` when `FOREMAN_TMUX_DISABLED=true` env var is set. Handle non-zero exit codes gracefully (no throws) | 2h | -- | `src/lib/tmux.ts` | [x] |
| AT-T002 | Implement `tmuxSessionName(seedId: string): string` function. Format: `foreman-<seedId>`. Replace characters invalid for tmux session names (colons `:`, periods `.`, spaces) with hyphens `-`. Ensure name is non-empty (fallback to `foreman-unknown` if seedId is empty) | 1h | -- | `src/lib/tmux.ts` | [x] |
| AT-T003 | Implement `createSession(opts: TmuxSpawnOptions): Promise<TmuxCreateResult>` method. Execute `tmux new-session -d -s <name> -c <cwd> '<command>'`. The command string must include stdout/stderr redirection to preserve existing log file behavior (e.g., `tsx agent-worker.ts <configPath> > logDir/runId.out 2> logDir/runId.err`). Return `{ sessionName, created: true }` on success. On failure (non-zero exit), return `{ sessionName, created: false }` with a warning logged to stderr (TMUX-002) | 3h | AT-T001, AT-T002 | `src/lib/tmux.ts` | [x] |
| AT-T004 | Implement `killSession(sessionName: string): Promise<boolean>` method. Execute `tmux kill-session -t <name>`. Return true if killed, false if session did not exist (exit code 1). Do not throw on failure (TMUX-005) | 1h | AT-T001 | `src/lib/tmux.ts` | [x] |
| AT-T005 | Implement `hasSession(sessionName: string): Promise<boolean>` method. Execute `tmux has-session -t <name>`. Return true if exit code 0, false otherwise. Used by monitor for liveness checks and by attach for existence validation | 1h | AT-T001 | `src/lib/tmux.ts` | [x] |
| AT-T006 | Implement `capturePaneOutput(sessionName: string): Promise<string[]>` method. Execute `tmux capture-pane -t <name> -p` and return stdout split into lines. Return empty array if session does not exist (TMUX-004). Used by follow mode | 2h | AT-T001, AT-T005 | `src/lib/tmux.ts` | [x] |
| AT-T007 | Implement `listForemanSessions(): Promise<TmuxSessionInfo[]>` method. Execute `tmux list-sessions -F '#{session_name} #{session_created} #{session_attached} #{session_windows}'`. Filter to sessions matching `foreman-*` prefix. Parse output into `TmuxSessionInfo[]`. Return empty array if tmux unavailable or no sessions | 2h | AT-T001 | `src/lib/tmux.ts` | [x] |
| AT-T008 | Implement `getTmuxVersion(): Promise<string | null>` method. Execute `tmux -V` and parse output (e.g., `tmux 3.4` -> `"3.4"`). Return null if tmux unavailable. Used by doctor to check version compatibility (>= 3.0) | 1h | AT-T001 | `src/lib/tmux.ts` | [x] |
| AT-T009 | Write unit tests for TmuxClient: mock `execFile` calls for all methods. Test `isAvailable()` with tmux present/missing/disabled via env var. Test `tmuxSessionName()` sanitization (colons, periods, spaces, empty). Test `createSession()` success/failure paths. Test `killSession()` success/not-found. Test `hasSession()` true/false. Test `capturePaneOutput()` parsing and empty session. Test `listForemanSessions()` filtering and parsing. Test `getTmuxVersion()` parsing | 5h | AT-T001 through AT-T008 | `src/lib/__tests__/tmux.test.ts` | [x] |

#### Story 1.2: SQLite Schema Migration

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T010 | Add `ALTER TABLE runs ADD COLUMN tmux_session TEXT DEFAULT NULL` to the `MIGRATIONS` array in store.ts. This follows the existing idempotent pattern where ALTER TABLE throws if the column already exists, and the error is silently caught | 1h | -- | `src/lib/store.ts` | [x] |
| AT-T011 | Update the `Run` interface to include `tmux_session: string | null` field. Update `updateRun()` method signature to accept `tmux_session` in the partial updates type. No changes needed to `createRun()` as the column defaults to NULL | 2h | AT-T010 | `src/lib/store.ts` | [x] |
| AT-T012 | Write unit test verifying `tmux_session` column migration is idempotent (run migrations twice, no error). Test that `updateRun()` persists and retrieves `tmux_session` correctly. Test that existing runs without `tmux_session` return null | 2h | AT-T010, AT-T011 | `src/lib/__tests__/store-tmux.test.ts` | [x] |

### 2.2 Sprint 2: Core Spawning -- Dispatcher Integration (FR-1)

#### Story 2.1: Tmux-Based Worker Spawning

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T013 | Refactor `spawnWorkerProcess()` in dispatcher.ts to use a `SpawnStrategy` interface pattern. Define `SpawnStrategy` interface with `spawn(config: WorkerConfig): Promise<{ tmuxSession?: string }>`. Implement `TmuxSpawnStrategy` (calls `TmuxClient.createSession()`) and `DetachedSpawnStrategy` (existing `spawn(tsx, [...], { detached: true })` path). Strategy selection: `TmuxClient.isAvailable()` returns true → `TmuxSpawnStrategy`, else → `DetachedSpawnStrategy`. Both strategies share config serialization and logging setup. The tmux command string must be: `<tsxBin> <workerScript> <configPath> > <outLog> 2> <errLog>`. Pass `config.worktreePath` as `cwd`. Export the interface for future extensibility (e.g., Docker containers) | 5h | AT-T001, AT-T003 | `src/orchestrator/dispatcher.ts` | [x] |
| AT-T014 | Implement stale session cleanup in `spawnWorkerProcess()`. Before creating a new tmux session, call `TmuxClient.killSession(sessionName)` to remove any stale session with the same name (FR-1 AC-6). Log `[foreman] Killed stale tmux session foreman-<seedId>` if a session was killed (TMUX-009). Use `tmuxSessionName(config.seedId)` for the session name | 2h | AT-T002, AT-T004, AT-T013 | `src/orchestrator/dispatcher.ts` | [x] |
| AT-T015 | After successful tmux session creation, call `store.updateRun(run.id, { tmux_session: sessionName })` to persist the session name. For the fallback (detached process) path, do not set `tmux_session` (it remains null). Ensure the existing `store.updateRun()` call for `session_key`, `started_at` is preserved | 2h | AT-T011, AT-T013 | `src/orchestrator/dispatcher.ts` | [x] |
| AT-T016 | Handle tmux session creation failure gracefully. If `createSession()` returns `{ created: false }`, fall back to the existing detached `spawn()` path. Log warning: `[foreman] tmux session creation failed -- falling back to detached process` (TMUX-002). Do not set `tmux_session` on the run record | 2h | AT-T013 | `src/orchestrator/dispatcher.ts` | [x] |
| AT-T017 | Write unit tests for tmux-based spawning in dispatcher. Mock `TmuxClient.isAvailable()` and `TmuxClient.createSession()`. Test: (1) tmux available -> creates session + stores tmux_session, (2) tmux unavailable -> existing detached spawn, (3) tmux creation fails -> fallback to detached spawn, (4) stale session killed before new creation, (5) FOREMAN_TMUX_DISABLED -> detached spawn | 5h | AT-T013 through AT-T016 | `src/orchestrator/__tests__/dispatcher-tmux.test.ts` | [x] |

### 2.3 Sprint 3: Attachment Experience (FR-3, FR-4, FR-10)

#### Story 3.1: Interactive Tmux Attachment (Default Mode)

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T018 | Rewrite the default attachment path in `attach.ts`. After looking up the run, check if `run.tmux_session` is set. If set, call `TmuxClient.hasSession(run.tmux_session)`. If the tmux session exists, spawn `tmux attach-session -t <session>` with `stdio: "inherit"` (interactive mode). On exit, exit with tmux's exit code. Print header before attaching: `Attaching to foreman-<seedId> [<phase>] | Ctrl+B, D to detach` | 3h | AT-T005, AT-T011 | `src/cli/commands/attach.ts` | [x] |
| AT-T019 | Implement fallback chain in attach.ts. If `run.tmux_session` is null or `hasSession()` returns false: (1) extract SDK session ID from `session_key`, (2) if session ID exists, fall back to `claude --resume <sessionId>` (existing behavior), (3) print `Tmux session not found. Falling back to SDK session resume.` (TMUX-003), (4) if both tmux session and SDK session unavailable, print actionable error: `No active session found for "<id>". The agent may have completed or crashed. Use 'foreman attach --list' to see available sessions.` | 2h | AT-T018 | `src/cli/commands/attach.ts` | [x] |

#### Story 3.2: Read-Only Follow Mode

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T020 | Add `--follow` option to the attach command. When `--follow` is specified, enter a polling loop that calls `TmuxClient.capturePaneOutput()` every `FOREMAN_TMUX_FOLLOW_INTERVAL_MS` milliseconds (default 1000). Track previously displayed line count; only print new lines (diff-based: compare new output length against previous, print lines from `previousLength` onward). Display header: `Following foreman-<seedId> [<phase>] | Ctrl+C to stop | foreman attach <id> for interactive` | 4h | AT-T006 | `src/cli/commands/attach.ts` | [x] |
| AT-T021 | Implement follow mode termination. Listen for SIGINT (Ctrl+C) via `AbortController`. On signal, print `\nStopped following. Agent continues running.` and exit cleanly. Also detect session end: when `hasSession()` returns false during polling, print `Session ended.` and exit. Ensure the polling `setInterval` is cleared on exit | 2h | AT-T020 | `src/cli/commands/attach.ts` | [x] |
| AT-T022 | Implement follow mode fallback. If the run has no `tmux_session` or the tmux session does not exist, fall back to tailing the log file: `tail -f ~/.foreman/logs/<runId>.out`. Print: `No tmux session for this run. Tailing log file instead.` (TMUX-004). Use `spawn("tail", ["-f", logPath], { stdio: "inherit" })` | 2h | AT-T020 | `src/cli/commands/attach.ts` | [x] |

#### Story 3.3: Session Kill and Cleanup

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T023 | Add `--kill` option to the attach command. When `--kill <id>` is specified: (1) look up the run, (2) if `tmux_session` is set, call `TmuxClient.killSession(run.tmux_session)`, (3) print `Killed tmux session <name>`, (4) if the run status is "running" or "pending", mark it as "stuck" in the store. If no tmux session exists, print `No tmux session to kill for this run.` | 2h | AT-T004, AT-T011 | `src/cli/commands/attach.ts` | [x] |

#### Story 3.4: Enhanced Session Listing

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T024 | Rewrite `listSessions()` in attach.ts to include enhanced columns: SEED, STATUS, PHASE, PROGRESS, COST, ELAPSED, TMUX, WORKTREE. For each run: parse `RunProgress` from `run.progress` JSON, extract `currentPhase`, compute tool/file progress string (`"42 tools, 8 files"`), format `costUsd` as `$0.42`, compute elapsed time from `started_at` to now (format as `"12m"` or `"1h 23m"`), show `tmux_session` or `"(none)"` | 4h | AT-T011 | `src/cli/commands/attach.ts` | [x] |
| AT-T025 | Implement session listing sort order. Sort rows by: (1) status priority (running=0, stuck=1, failed=2, completed=3), (2) within same status, sort by recency (most recent `started_at` first). Include completed and failed runs that have a `tmux_session` set, as they may still be reviewable | 1h | AT-T024 | `src/cli/commands/attach.ts` | [x] |
| AT-T026 | Write unit tests for enhanced attach command. Test: (1) default attachment uses tmux attach-session when tmux_session is set, (2) fallback to claude --resume when no tmux session, (3) --follow mode polls capture-pane and prints only new lines, (4) --follow exits on SIGINT and session end, (5) --follow falls back to tail when no tmux session, (6) --kill kills session and updates run status, (7) --list shows enhanced columns with correct formatting, (8) --list sort order | 5h | AT-T018 through AT-T025 | `src/cli/__tests__/attach.test.ts` | [x] |

### 2.4 Sprint 4: Smart Dispatch (FR-5)

#### Story 4.1: TTY-Aware Auto-Attach on Dispatch

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T027 | Add `--attach` and `--no-attach` options to the `run` command in run.ts. `--attach` forces auto-attach; `--no-attach` disables auto-attach. These are mutually exclusive (commander `.conflicts()`) | 1h | -- | `src/cli/commands/run.ts` | [x] |
| AT-T028 | Implement TTY-aware auto-attach logic in run.ts. After dispatching agents, check: (1) `process.stdout.isTTY` is true, (2) only one agent was dispatched (single `--seed` mode), (3) `--no-attach` flag is not set. If all conditions met (or `--attach` is forced), look up the run's `tmux_session` from the store and spawn `tmux attach-session -t <session>` with `stdio: "inherit"`. Print `Auto-attaching to foreman-<seedId>... (Ctrl+B, D to detach)` | 3h | AT-T027, AT-T015 | `src/cli/commands/run.ts` | [x] |
| AT-T029 | Handle auto-attach edge cases. If tmux session is not yet available (race condition between spawn and tmux session creation), retry up to 3 times with 500ms delay. If tmux is unavailable (no `tmux_session` on run), skip auto-attach silently and continue with existing watch mode behavior. If `--attach` is used with multi-agent dispatch, attach to the first dispatched agent only | 2h | AT-T028 | `src/cli/commands/run.ts` | [x] |
| AT-T030 | Write unit tests for auto-attach. Test: (1) single seed dispatch from TTY auto-attaches interactively, (2) `--no-attach` skips auto-attach, (3) `--attach` forces auto-attach, (4) multi-agent dispatch without `--seed` does not auto-attach, (5) non-TTY stdout skips auto-attach, (6) tmux unavailable skips auto-attach silently, (7) `--attach` with multi-agent attaches to first agent | 4h | AT-T027 through AT-T029 | `src/cli/__tests__/run-attach.test.ts` | [x] |

### 2.5 Sprint 5: Monitoring + Health (FR-7)

#### Story 5.1: Tmux Liveness in Monitor

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T031 | Enhance `Monitor.checkAll()` to perform tmux liveness checks. For each active run that has a `tmux_session` value, call `TmuxClient.hasSession(run.tmux_session)`. If `hasSession()` returns false, immediately mark the run as "stuck" (bypass the existing timeout heuristic). Log event with `{ seedId, detectedBy: "tmux-liveness", tmuxSession }`. This check runs before the existing seed-status check so dead sessions are caught immediately | 3h | AT-T005, AT-T011 | `src/orchestrator/monitor.ts` | [x] |
| AT-T032 | Write unit tests for tmux liveness in monitor. Mock `TmuxClient.hasSession()`. Test: (1) active run with live tmux session continues normal flow, (2) active run with dead tmux session immediately marked stuck, (3) active run without tmux_session uses existing timeout heuristic, (4) stuck detection logs correct event details | 3h | AT-T031 | `src/orchestrator/__tests__/monitor-tmux.test.ts` | [x] |

#### Story 5.2: Doctor Session Management Checks

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T033 | Add "Session Management" check category to `foreman doctor`. Implement three checks: (1) **tmux availability**: call `TmuxClient.isAvailable()` and `TmuxClient.getTmuxVersion()`, report version and warn if < 3.0 (TMUX-010). (2) **Orphaned sessions**: call `TmuxClient.listForemanSessions()`, cross-reference with active runs from store; sessions with no matching active run are orphaned (TMUX-007). (3) **Ghost runs**: iterate active runs with `tmux_session` set, call `hasSession()`; runs where session is dead are ghosts (TMUX-008) | 4h | AT-T005, AT-T007, AT-T008 | `src/orchestrator/doctor.ts`, `src/cli/commands/doctor.ts` | [x] |
| AT-T034 | Implement `--fix` behavior for Session Management checks. For orphaned sessions: call `TmuxClient.killSession()` for each orphan, print `Killed orphaned tmux session <name>`. For ghost runs: call `store.updateRun(run.id, { status: "stuck" })`, print `Marked ghost run <seedId> as stuck`. Report total fixed count | 2h | AT-T033 | `src/orchestrator/doctor.ts`, `src/cli/commands/doctor.ts` | [x] |
| AT-T035 | Write unit tests for doctor session management. Test: (1) tmux available reports version, (2) tmux unavailable reports warning, (3) orphaned sessions detected and listed, (4) ghost runs detected and listed, (5) `--fix` kills orphaned sessions, (6) `--fix` marks ghost runs as stuck, (7) no issues reports clean | 4h | AT-T033, AT-T034 | `src/cli/__tests__/doctor-tmux.test.ts` | [x] |

#### Story 5.3: Reset Tmux Cleanup

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T036 | Add tmux session cleanup to `foreman reset`. After existing cleanup steps (kill processes, remove worktrees, etc.), call `TmuxClient.listForemanSessions()` to get all `foreman-*` tmux sessions. Call `TmuxClient.killSession()` for each. Print `Killed N tmux session(s)`. If tmux is unavailable, skip silently | 2h | AT-T004, AT-T007 | `src/cli/commands/reset.ts` | [x] |
| AT-T037 | Write unit tests for reset tmux cleanup. Test: (1) reset kills all foreman-* tmux sessions, (2) reset with no tmux sessions reports zero, (3) reset with tmux unavailable skips silently, (4) individual kill failure does not abort remaining kills | 2h | AT-T036 | `src/cli/__tests__/reset-tmux.test.ts` | [x] |

### 2.6 Sprint 6: Polish + E2E

#### Story 6.1: End-to-End Integration Tests

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T038 | Write integration test for full dispatch-attach-detach cycle using real tmux sessions. Wrap with `describe.skipIf(!tmuxAvailable)` for CI environments without tmux. Test: (1) dispatch agent -> real tmux session created -> run record has tmux_session, (2) attach command uses tmux attach-session, (3) detach (simulated), (4) reattach works, (5) agent completes -> session persists -> attach still works for review. Clean up all test sessions in `afterEach` | 4h | AT-T017, AT-T026 | `src/orchestrator/__tests__/tmux-integration.test.ts` | [x] |
| AT-T039 | Write integration test for fallback behavior (no tmux dependency — runs on all CI). Test: (1) dispatch without tmux -> detached process (existing behavior preserved), (2) attach falls back to claude --resume, (3) follow falls back to tail. Verify no regressions in non-tmux path | 3h | AT-T038 | `src/orchestrator/__tests__/tmux-integration.test.ts` | [x] |

#### Story 6.2: Follow Mode Edge Cases

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T040 | Write tests for follow mode edge cases. Test: (1) follow mode with rapidly updating output (ensure no duplicate lines), (2) follow mode when session ends mid-poll (graceful exit), (3) multiple concurrent follow mode sessions to same agent (independent operation), (4) follow mode with empty initial output (no crash), (5) follow mode interval respects FOREMAN_TMUX_FOLLOW_INTERVAL_MS env var | 3h | AT-T020, AT-T021 | `src/cli/__tests__/attach-follow.test.ts` | [x] |

#### Story 6.3: Monitor and Health Edge Cases

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T041 | Write tests for monitor tmux edge cases. Test: (1) monitor with mix of tmux and non-tmux runs (correct handling of each), (2) tmux command timeout during liveness check (graceful fallback to timeout heuristic), (3) concurrent monitor calls (no race conditions on store updates) | 3h | AT-T031, AT-T032 | `src/orchestrator/__tests__/monitor-tmux-edge.test.ts` | [x] |

#### Story 6.4: Error Path Tests

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T042 | Write tests for all TMUX error codes. Verify each error code (TMUX-001 through TMUX-012) is triggered by the correct scenario and produces the correct user-facing message. Test graceful degradation for all error paths (no unhandled exceptions) | 4h | AT-T009, AT-T017 | `src/lib/__tests__/tmux-errors.test.ts` | [x] |

#### Story 6.5: Session Name Edge Cases

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| AT-T043 | Write tests for session name edge cases. Test: (1) seed IDs with unicode characters, (2) very long seed IDs (tmux has a name length limit), (3) seed IDs that are entirely special characters, (4) seed IDs matching existing tmux session naming patterns, (5) case sensitivity | 2h | AT-T002 | `src/lib/__tests__/tmux-names.test.ts` | [x] |

---

## 3. Sprint Planning Summary

| Sprint | Focus | Tasks | Est. Hours | Key Deliverables |
|--------|-------|-------|-----------|--------------------|
| 1 | Foundation | AT-T001 to AT-T012 | 23h | TmuxClient utility module, SQLite migration, session name convention |
| 2 | Core Spawning | AT-T013 to AT-T017 | 16h | SpawnStrategy interface with TmuxSpawnStrategy + DetachedSpawnStrategy |
| 3 | Attachment Experience | AT-T018 to AT-T026 | 25h | Interactive attach, follow mode, --kill, enhanced listing |
| 4 | Smart Dispatch | AT-T027 to AT-T030 | 10h | --attach/--no-attach flags, TTY-aware auto-attach |
| 5 | Monitoring + Health | AT-T031 to AT-T037 | 20h | Tmux liveness in monitor, doctor checks, reset cleanup |
| 6 | Polish + E2E | AT-T038 to AT-T043 | 19h | Integration tests, edge cases, error path coverage |

**Total: 43 tasks, ~113 estimated hours across 6 sprints**

### Parallelization Opportunities

- **Sprint 1**: Stories 1.1 (TmuxClient) and 1.2 (Schema Migration) can run in parallel -- they have no shared dependencies
- **Sprint 3**: Stories 3.1/3.2 (attach/follow) and Story 3.4 (enhanced listing) can start in parallel since listing only depends on the store schema (Sprint 1)
- **Sprint 5**: Stories 5.1 (monitor), 5.2 (doctor), and 5.3 (reset) can all run in parallel -- they depend on Sprint 1 TmuxClient but not on each other

---

## 4. Dependency Graph

```
Sprint 1 (Foundation)
  AT-T001 (isAvailable) -> AT-T003 (createSession)
  AT-T001 -> AT-T004 (killSession)
  AT-T001 -> AT-T005 (hasSession)
  AT-T001 -> AT-T007 (listSessions)
  AT-T001 -> AT-T008 (getVersion)
  AT-T002 (sessionName) -> AT-T003
  AT-T005 -> AT-T006 (capturePaneOutput)
  AT-T001 through AT-T008 -> AT-T009 (tests)
  AT-T010 (migration) -> AT-T011 (Run interface)
  AT-T010, AT-T011 -> AT-T012 (store tests)

Sprint 2 (Core Spawning) -- depends on Sprint 1
  AT-T001, AT-T003 -> AT-T013 (refactor spawnWorkerProcess)
  AT-T002, AT-T004, AT-T013 -> AT-T014 (stale session cleanup)
  AT-T011, AT-T013 -> AT-T015 (store tmux_session)
  AT-T013 -> AT-T016 (fallback handling)
  AT-T013 through AT-T016 -> AT-T017 (dispatcher tests)

Sprint 3 (Attachment) -- depends on Sprint 1 + Sprint 2
  AT-T005, AT-T011 -> AT-T018 (interactive attach)
  AT-T018 -> AT-T019 (fallback chain)
  AT-T006 -> AT-T020 (follow mode)
  AT-T020 -> AT-T021 (follow termination)
  AT-T020 -> AT-T022 (follow fallback)
  AT-T004, AT-T011 -> AT-T023 (--kill)
  AT-T011 -> AT-T024 (enhanced listing)
  AT-T024 -> AT-T025 (sort order)
  AT-T018 through AT-T025 -> AT-T026 (attach tests)

Sprint 4 (Smart Dispatch) -- depends on Sprint 2
  AT-T027 (CLI options, independent)
  AT-T027, AT-T015 -> AT-T028 (auto-attach logic)
  AT-T028 -> AT-T029 (edge cases)
  AT-T027 through AT-T029 -> AT-T030 (tests)

Sprint 5 (Monitoring + Health) -- depends on Sprint 1
  AT-T005, AT-T011 -> AT-T031 (monitor liveness)
  AT-T031 -> AT-T032 (monitor tests)
  AT-T005, AT-T007, AT-T008 -> AT-T033 (doctor checks)
  AT-T033 -> AT-T034 (doctor --fix)
  AT-T033, AT-T034 -> AT-T035 (doctor tests)
  AT-T004, AT-T007 -> AT-T036 (reset cleanup)
  AT-T036 -> AT-T037 (reset tests)

Sprint 6 (Polish) -- depends on Sprint 2 + Sprint 3 + Sprint 5
  AT-T017, AT-T026 -> AT-T038 (E2E integration)
  AT-T038 -> AT-T039 (fallback E2E)
  AT-T020, AT-T021 -> AT-T040 (follow edge cases)
  AT-T031, AT-T032 -> AT-T041 (monitor edge cases)
  AT-T009, AT-T017 -> AT-T042 (error path tests)
  AT-T002 -> AT-T043 (name edge cases)
```

---

## 5. Acceptance Criteria (Technical Validation)

### 5.1 FR-1: Tmux-Based Agent Spawning

- [ ] AC-1.1: `spawnWorkerProcess()` creates a tmux session named `foreman-<seedId>` when tmux is available
- [ ] AC-1.2: Worker process (tsx agent-worker.ts) runs as the sole command in the tmux session
- [ ] AC-1.3: File-descriptor logging (`~/.foreman/logs/<runId>.{out,err}`) continues to work inside tmux
- [ ] AC-1.4: `tmux_session` is stored in the SQLite `runs` table
- [ ] AC-1.5: Completed worker leaves tmux session alive for post-mortem review
- [ ] AC-1.6: Stale sessions with same name are killed before creating new ones

### 5.2 FR-2: Graceful Fallback

- [ ] AC-2.1: `spawnWorkerProcess()` checks for tmux availability via `which tmux` (cached)
- [ ] AC-2.2: Tmux unavailable -> existing `spawn(tsx, [...], { detached: true })` path used unchanged
- [ ] AC-2.3: `foreman attach` prints clear error when tmux required but unavailable
- [ ] AC-2.4: `foreman doctor` includes tmux availability check
- [ ] AC-2.5: No runtime crashes or unhandled exceptions when tmux is missing

### 5.3 FR-3: Interactive Session Attachment

- [ ] AC-3.1: `foreman attach <id>` runs `tmux attach-session -t <session>` when tmux session exists
- [ ] AC-3.2: User can observe, scroll buffer, copy text in attached session
- [ ] AC-3.3: Ctrl+B, D detaches safely; agent continues running
- [ ] AC-3.4: User can reattach any number of times
- [ ] AC-3.5: Falls back to `claude --resume` if tmux session not available
- [ ] AC-3.6: Both tmux and SDK unavailable -> actionable error message

### 5.4 FR-4: Read-Only Follow Mode

- [ ] AC-4.1: `--follow` captures pane content via `tmux capture-pane -t <session> -p` every 1s
- [ ] AC-4.2: Only new lines (not previously displayed) are printed
- [ ] AC-4.3: Ctrl+C exits follow mode; agent continues running
- [ ] AC-4.4: Header displayed: `Following foreman-<seedId> [phase] | Ctrl+C to stop`
- [ ] AC-4.5: Session end detected and reported: `Session ended.`
- [ ] AC-4.6: No tmux session -> falls back to tailing log file

### 5.5 FR-5: TTY-Aware Auto-Attach

- [ ] AC-5.1: `foreman run --bead <id>` auto-attaches interactively when stdout is TTY + single agent + no `--no-attach`
- [ ] AC-5.2: `--no-attach` skips auto-attach
- [ ] AC-5.3: `--attach` forces auto-attach even with multi-agent dispatch (first agent)
- [ ] AC-5.4: Multi-agent dispatch without `--seed` never auto-attaches
- [ ] AC-5.5: Auto-attach uses interactive tmux mode (full attach-session)

### 5.6 FR-6: Tmux Session State Tracking

- [ ] AC-6.1: `tmux_session TEXT` column added to `runs` table (nullable)
- [ ] AC-6.2: `updateRun()` supports `tmux_session` field
- [ ] AC-6.3: Terminal state transitions leave tmux session alive
- [ ] AC-6.4: `getActiveRuns()` results include `tmux_session` value

### 5.7 FR-7: Zombie Session Detection

- [ ] AC-7.1: `Monitor.checkAll()` checks `tmux has-session` for runs with `tmux_session`
- [ ] AC-7.2: Dead session -> run immediately marked "stuck" (no timeout wait)
- [ ] AC-7.3: Live session with dead PID -> session killed, run marked stuck
- [ ] AC-7.4: Zombie detection runs in existing `foreman monitor` cycle
- [ ] AC-7.5: `foreman doctor` detects orphaned `foreman-*` sessions and ghost runs

### 5.8 FR-8: Enhanced Session Listing

- [ ] AC-8.1: `--list` shows SEED, STATUS, PHASE, PROGRESS, COST, ELAPSED, TMUX, WORKTREE columns
- [ ] AC-8.2: PHASE shows current pipeline phase
- [ ] AC-8.3: COST formatted as `$0.42`
- [ ] AC-8.4: ELAPSED formatted as `"12m"` or `"1h 23m"`
- [ ] AC-8.5: Rows sorted by status priority then recency

### 5.9 FR-9: Named Session Convention

- [ ] AC-9.1: Session name format is `foreman-<seedId>`
- [ ] AC-9.2: Invalid characters (colons, periods) replaced with hyphens
- [ ] AC-9.3: Unique sessions per project (stale killed before creation)
- [ ] AC-9.4: `foreman attach` accepts seed ID directly (resolves to `foreman-<seedId>`)

### 5.10 FR-10: Session Persistence and Cleanup

- [ ] AC-10.1: Tmux sessions persist indefinitely after agent completion
- [ ] AC-10.2: `foreman reset` kills all `foreman-*` tmux sessions
- [ ] AC-10.3: `foreman doctor --fix` kills orphaned sessions
- [ ] AC-10.4: `foreman attach --list` shows completed sessions with status tag
- [ ] AC-10.5: `foreman attach --kill <id>` kills individual session

---

## 6. Quality Requirements

### 6.1 Testing Standards

| Type | Target | Notes |
|------|--------|-------|
| Unit test coverage | >= 80% | All new modules must have co-located `__tests__/`. Mock `execFile` calls to tmux binary. |
| Integration test coverage | >= 70% | Tmux integration, fallback paths, E2E dispatch-attach cycle |
| Real tmux tests | CI-aware | Integration tests use real tmux sessions. Use `describe.skipIf(!tmuxAvailable)` to skip on CI environments where tmux is not installed. |
| Test framework | Vitest | Co-located in `__tests__/` subdirectories per CLAUDE.md |

### 6.2 Code Quality

- TypeScript strict mode -- no `any` escape hatches
- ESM only -- all imports use `.js` extensions
- TDD methodology -- RED-GREEN-REFACTOR for all coding tasks
- Non-interactive commands -- all shell commands must use `-f` flags (no `-i` prompts)
- Input validation at boundaries only (CLI argument parsing)

### 6.3 Performance Targets

| Operation | Target | Task Reference |
|-----------|--------|----------------|
| tmux session creation overhead | < 200ms | AT-T003, AT-T013 |
| Follow mode latency (output to display) | < 2s | AT-T020 |
| Zombie detection speed | < 30s from death | AT-T031 |
| Session listing render | < 500ms for 20 sessions | AT-T024 |
| tmux availability check (cached) | < 1ms after first call | AT-T001 |

### 6.4 Compatibility

- Works with tmux >= 3.0 (macOS Homebrew default, Ubuntu 20.04+)
- macOS and Linux support (primary: macOS via Homebrew)
- Existing workflows preserved when tmux unavailable
- SQLite schema change applied via idempotent migration
- No changes to `agent-worker.ts` (sessions persist naturally)

---

## 7. Risk Register

| Risk | Likelihood | Impact | Mitigation | Tasks Affected |
|------|-----------|--------|------------|----------------|
| tmux not available in user environment | Medium | Low | Graceful fallback (FR-2); `foreman doctor` check; clear messaging | AT-T001, AT-T016 |
| tmux version incompatibility (< 3.0) | Low | Medium | Document minimum version; doctor checks version; test on 3.0+ | AT-T008, AT-T033 |
| Session name collision across projects | Low | Low | Seed IDs unique within project; kill stale before create | AT-T002, AT-T014 |
| Race condition: auto-attach before tmux session ready | Medium | Low | Retry up to 3 times with 500ms delay | AT-T029 |
| Follow mode capture-pane misses output between polls | Low | Low | 1s polling interval is acceptable; users can use interactive mode for real-time | AT-T020 |
| Accumulated completed sessions consume resources | Medium | Medium | `foreman doctor --fix`, `foreman reset`, `foreman attach --kill` | AT-T023, AT-T034, AT-T036 |
| tmux command hangs (e.g., broken tmux server) | Low | Medium | Use execFile with timeout (5s); fall back to detached process on timeout | AT-T003, AT-T005 |

---

## 8. Files Modified/Created Summary

### New Files

| File | Sprint | Tasks |
|------|--------|-------|
| `src/lib/tmux.ts` | 1 | AT-T001 through AT-T008 |

### Modified Files

| File | Sprint | Tasks | Changes |
|------|--------|-------|---------|
| `src/lib/store.ts` | 1 | AT-T010, AT-T011 | Add `tmux_session TEXT` column migration; update `Run` interface and `updateRun()` signature |
| `src/orchestrator/dispatcher.ts` | 2 | AT-T013 through AT-T016 | Refactor `spawnWorkerProcess()` with tmux session creation path and fallback |
| `src/cli/commands/attach.ts` | 3 | AT-T018 through AT-T025 | Rewrite default to tmux attach-session; add --follow, --kill; enhance --list |
| `src/cli/commands/run.ts` | 4 | AT-T027 through AT-T029 | Add --attach/--no-attach flags; TTY-aware auto-attach logic |
| `src/orchestrator/monitor.ts` | 5 | AT-T031 | Add tmux has-session liveness check for runs with tmux_session |
| `src/orchestrator/doctor.ts` | 5 | AT-T033, AT-T034 | Add Session Management check category with orphan/ghost detection |
| `src/cli/commands/doctor.ts` | 5 | AT-T033, AT-T034 | Wire Session Management checks into CLI output and --fix |
| `src/cli/commands/reset.ts` | 5 | AT-T036 | Add tmux session cleanup (kill all foreman-* sessions) |

### Test Files (all new)

| File | Sprint | Tasks |
|------|--------|-------|
| `src/lib/__tests__/tmux.test.ts` | 1 | AT-T009 |
| `src/lib/__tests__/store-tmux.test.ts` | 1 | AT-T012 |
| `src/orchestrator/__tests__/dispatcher-tmux.test.ts` | 2 | AT-T017 |
| `src/cli/__tests__/attach.test.ts` | 3 | AT-T026 |
| `src/cli/__tests__/run-attach.test.ts` | 4 | AT-T030 |
| `src/orchestrator/__tests__/monitor-tmux.test.ts` | 5 | AT-T032 |
| `src/cli/__tests__/doctor-tmux.test.ts` | 5 | AT-T035 |
| `src/cli/__tests__/reset-tmux.test.ts` | 5 | AT-T037 |
| `src/orchestrator/__tests__/tmux-integration.test.ts` | 6 | AT-T038, AT-T039 |
| `src/cli/__tests__/attach-follow.test.ts` | 6 | AT-T040 |
| `src/orchestrator/__tests__/monitor-tmux-edge.test.ts` | 6 | AT-T041 |
| `src/lib/__tests__/tmux-errors.test.ts` | 6 | AT-T042 |
| `src/lib/__tests__/tmux-names.test.ts` | 6 | AT-T043 |

---

## 9. Definition of Done

A task is considered complete when:

1. Implementation follows TypeScript strict mode (no `any`)
2. All imports use `.js` extensions (ESM)
3. TDD cycle completed (test written first, implementation makes it pass, refactored)
4. Unit tests pass with >= 80% coverage for the touched module
5. `npx tsc --noEmit` passes with zero errors
6. `npm test` passes (full suite)
7. Non-interactive commands only (no `-i` flags; use `-f` for cp/mv/rm)
8. Error codes used for all failure paths (TMUX-xxx)
9. Git commit with descriptive message referencing task ID
10. Graceful fallback verified for all tmux-dependent code paths

---

## 10. Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-03-13 | Initial TRD creation from PRD-ATTACH-SESSION v1.1 |
| 1.1 | 2026-03-13 | Refined based on technical interview: (1) Confirmed TmuxClient as class instance pattern. (2) Adopted SpawnStrategy interface pattern for dispatcher refactoring — `TmuxSpawnStrategy` and `DetachedSpawnStrategy` implementations for cleaner separation and future extensibility. AT-T013 updated, SpawnStrategy types added to Section 1.4. (3) Integration tests use real tmux sessions with `describe.skipIf(!tmuxAvailable)` for CI environments. AT-T038 updated. (4) Confirmed capture-pane polling approach for follow mode. (5) Sprint organization confirmed as-is (6 sprints). |
