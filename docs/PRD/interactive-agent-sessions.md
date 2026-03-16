# PRD: Interactive Agent Sessions via Claude CLI

**Version:** 1.1
**Status:** Draft
**Author:** Product Management
**Created:** 2026-03-13
**Last Updated:** 2026-03-13
**Priority:** P1

---

## 1. Product Summary

### 1.1 Problem Statement

When users run `foreman run` today, each agent task is spawned inside a tmux session that executes `tsx agent-worker.ts`. The agent-worker process calls the Claude Agent SDK `query()` function headlessly, piping all stdout/stderr to log files. The result: the tmux pane is blank. When a user runs `foreman attach <id>`, they see an empty terminal with no visible activity -- no streaming output, no tool calls, no ability to interact.

This is the single largest usability gap in Foreman. Users expect to see a live Claude Code session when they attach -- the same experience they get running `claude` directly in a terminal. Instead they must tail log files or poll the SQLite store for progress updates, losing the interactive debugging and intervention capabilities that make Claude Code powerful.

### 1.2 Solution

Replace the SDK `query()` invocation with spawning the `claude` CLI binary directly inside the tmux session pane. The tmux pane becomes a real, interactive Claude Code terminal. Users who `foreman attach` see live tool calls, streaming output, and can interact with the session (send keystrokes, scroll history). The existing pipeline orchestration (Explorer, Developer, QA, Reviewer, Finalize) is preserved by a TypeScript orchestrator (`pipeline-runner.ts`) that runs sequential `claude` CLI invocations, each with phase-specific prompts and constraints.

### 1.3 Value Proposition

- **Visibility**: Users see exactly what the agent is doing in real time -- no more blank tmux panes or log-tailing workarounds
- **Interactivity**: Users can intervene, answer questions, or guide agents when they get stuck -- reducing wasted compute and failed runs
- **Debuggability**: When an agent fails, users can attach and see the full Claude Code UI with conversation history, tool call results, and error context
- **Resume**: `claude --resume <sessionId>` provides native session resume, replacing the current fragile SDK session ID extraction
- **Alignment with Overstory**: Matches the tmux + interactive CLI pattern used by Overstory (the reference implementation from the seeds ecosystem)

---

## 2. User Analysis

### 2.1 User Personas

**Persona 1: Engineering Lead ("Elena")**
- Manages 3-5 concurrent Foreman agent runs daily
- Needs high-level visibility into agent progress without deep diving
- Primary workflow: `foreman run --seed X`, check `foreman status`, occasionally `foreman attach` to investigate stuck agents
- Pain point: Cannot tell if an agent is making progress or spinning its wheels without checking logs or the SQLite store
- Success metric: Can glance at a tmux pane and immediately understand agent state

**Persona 2: Hands-on Developer ("Dev")**
- Uses Foreman to offload implementation tasks, wants to monitor quality
- Frequently attaches to running agents to watch implementation approach
- Wants to intervene when an agent takes a wrong architectural direction
- Pain point: `foreman attach` shows nothing; must `tail -f` log files which show only tool names, not content
- Success metric: Can attach to a running agent, see live Claude Code output, and type to redirect the agent

**Persona 3: DevOps/Platform Engineer ("Dana")**
- Responsible for Foreman infrastructure, debugging agent failures
- Investigates rate limits, stuck agents, and pipeline failures
- Pain point: When an agent fails at the QA phase, there is no way to see what happened in the session -- only the log file summary
- Success metric: Can attach to a failed/stuck agent's session and see full conversation history via `claude --resume`

### 2.2 Pain Points (Current State)

1. **Blank tmux pane**: `foreman attach` connects to a tmux session showing nothing -- all output is redirected to log files
2. **No intervention capability**: Cannot type into the session to guide or correct the agent
3. **Opaque failures**: When agents fail, the only diagnostic is a terse log line like `FAILED: SDK stream ended without result`
4. **Fragile resume**: SDK session resume requires extracting session IDs from a custom key format (`foreman:sdk:<model>:<runId>:session-<id>`)
5. **Two mental models**: Users must understand both the Foreman abstraction layer AND the underlying SDK mechanics to debug issues

### 2.3 User Journey (Desired State)

1. User runs `foreman run --seed abc123`
2. Foreman creates worktree, writes TASK.md, spawns `pipeline-runner.ts` inside tmux session
3. `pipeline-runner.ts` invokes `claude` in interactive mode -- user sees dispatch confirmation with tmux session name
4. User runs `foreman attach abc123` and sees a live Claude Code session: streaming text, tool calls executing, files being read/written
5. User watches the Explorer phase complete, sees EXPLORER_REPORT.md being written
6. Pipeline transitions to Developer phase -- a new `claude` invocation starts in the same pane
7. User notices the agent taking a questionable approach, types a correction directly into the session
8. Developer phase completes, QA phase starts automatically
9. QA finds test failures, pipeline sends feedback back to Developer for retry
10. After all phases complete, Finalize commits, pushes, and closes the seed
11. If the agent hits a rate limit mid-session, user can later `foreman run --resume` which invokes `claude --resume <sessionId>`

---

## 3. Goals and Non-Goals

### 3.1 Objectives

| ID | Objective | Success Criteria |
|----|-----------|-----------------|
| O-1 | Interactive tmux sessions | `foreman attach` shows a live Claude Code session with streaming output; user can type into it |
| O-2 | Pipeline preservation | All 5 phases (Explorer, Developer, QA, Reviewer, Finalize) execute correctly via CLI invocations |
| O-3 | Session resume | `foreman run --resume` uses `claude --resume <sessionId>` for native resume |
| O-4 | Progress tracking | Foreman tracks total run cost and basic progress in SQLite |
| O-5 | Direct replacement | SDK-based agent-worker is replaced directly; no feature flags or parallel code paths |

### 3.2 Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Attach shows live output | 100% of runs | Manual verification: `foreman attach <id>` shows Claude Code UI |
| Pipeline completion rate | >= current rate (no regression) | Compare completed/total runs before and after |
| Resume success rate | >= 80% of stuck runs successfully resume | Track `--resume` outcomes |
| Session attach latency | < 1 second | Time from `foreman attach` to seeing live output |

### 3.3 Non-Goals (Out of Scope)

- **Multi-runtime support**: This PRD covers Claude CLI only, not Pi/Gemini/other runtimes
- **Web-based dashboard**: Tmux-based attach only; no browser UI for session viewing
- **Parallel phase execution**: Phases remain sequential (Explorer then Developer then QA then Reviewer then Finalize)
- **SDK removal for planning**: The SDK may still be used for `dispatchPlanStep()` (PRD/TRD generation); this PRD only covers agent worker pipeline
- **Per-phase budget enforcement**: `--max-budget-usd` and `--max-turns` are only available in print mode; budget enforcement is deferred to a future "coordinator" feature
- **Per-phase cost tracking**: MVP tracks total run cost only; per-phase cost breakdown is deferred to the coordinator feature
- **Detached/print-mode fallback**: MVP requires tmux; a `--print` mode fallback for non-tmux environments is deferred to a future iteration
- **Read-only attach mode**: All attach sessions are fully interactive; a watch-only mode may be added later if needed

---

## 4. Functional Requirements

### FR-1: Claude CLI Spawn Strategy

**Description:** Replace `TmuxSpawnStrategy` to spawn the `claude` CLI binary in interactive mode directly inside the tmux pane instead of `tsx agent-worker.ts`.

**Details:**
- The tmux session command runs `tsx pipeline-runner.ts <config>` which in turn spawns `claude` (interactive, no `-p`) per phase
- Pass the phase prompt via stdin piping: `echo "<prompt>" | claude --dangerously-skip-permissions --model <model> --session-id <uuid> ...`
- Set working directory via tmux `new-session -c <worktree-path>` (no `--cwd` flag exists on `claude` CLI)
- Remove stdout/stderr redirection to log files -- output stays in the tmux pane
- Preserve the `CLAUDECODE` env var stripping to avoid nested session conflicts

**Acceptance Criteria:**
- AC-1.1: Running `foreman run --seed X` creates a tmux session where `claude` is the running process (not `tsx agent-worker.ts` directly calling SDK)
- AC-1.2: The tmux pane shows live Claude Code TUI output (streaming text, tool call indicators)
- AC-1.3: `foreman attach X` connects to the tmux session and the user sees an active Claude Code UI
- AC-1.4: The user can type into the attached session to interact with the running `claude` process

### FR-2: Pipeline Orchestration via CLI

**Description:** Reimplement the pipeline phases (Explorer, Developer, QA, Reviewer) as sequential `claude` CLI invocations within the same tmux session, replacing SDK `query()` calls.

**Details:**
- Each phase runs as a separate `claude` invocation in interactive mode with phase-specific prompt and constraints
- Phase transitions are orchestrated by `pipeline-runner.ts` (TypeScript) running in the tmux pane
- The orchestrator waits for each `claude` invocation to exit, checks reports, and decides whether to proceed, retry, or fail
- All phases use `--dangerously-skip-permissions` to prevent permission prompts from stalling unattended runs
- Phase prompts are piped via stdin (since `--prompt-file` does not exist on the CLI)
- The CLAUDE.md file in the worktree is automatically respected by the `claude` CLI

**Acceptance Criteria:**
- AC-2.1: Explorer phase runs `claude` with explorer prompt, produces EXPLORER_REPORT.md, and exits
- AC-2.2: Developer phase runs `claude` with developer prompt (including explorer report context), implements changes, and exits
- AC-2.3: QA phase runs `claude` with QA prompt, runs tests, produces QA_REPORT.md with PASS/FAIL verdict
- AC-2.4: On QA FAIL, the pipeline retries Developer then QA (up to 2 retries, matching current behavior)
- AC-2.5: Reviewer phase runs `claude` with reviewer prompt, produces REVIEW.md
- AC-2.6: Finalize phase runs git add/commit/push and `sd close` (shell commands, not a `claude` invocation)

### FR-3: Phase-Specific CLI Flags and Tool Restrictions

**Description:** Map current SDK `query()` options to equivalent `claude` CLI flags for each pipeline phase, using `--disallowedTools` for role-based tool enforcement.

**Details:**
- Model selection: `claude --model <alias>` (e.g., `--model haiku` for Explorer, `--model sonnet` for Developer/QA/Reviewer)
- Permission mode: `--dangerously-skip-permissions` for all phases
- Session tracking: `--session-id <uuid>` with a deterministic UUID per phase per run (e.g., `uuidv5(runId + phaseName)`)
- Tool restrictions via `--disallowedTools` per phase, replacing the SDK-era DCG:

| Phase | Model | Disallowed Tools | Rationale |
|-------|-------|-----------------|-----------|
| Explorer | haiku | `Bash(git commit*)`, `Bash(git push*)`, `Bash(rm -rf*)`, `Write`, `Edit` | Read-only exploration; can use Bash for non-destructive commands |
| Developer | sonnet | `Bash(git push*)`, `Bash(rm -rf /*)` | Full implementation access minus dangerous operations |
| QA | sonnet | `Bash(git commit*)`, `Bash(git push*)`, `Edit` | Can run tests and read code, but should not modify source |
| Reviewer | sonnet | `Bash(git commit*)`, `Bash(git push*)`, `Bash(rm*)`, `Edit` | Read-only review plus Write for REVIEW.md |

**Acceptance Criteria:**
- AC-3.1: Explorer phase uses Haiku model and is restricted from write/edit operations via `--disallowedTools`
- AC-3.2: Developer phase uses Sonnet model with full tool access minus dangerous git/rm operations
- AC-3.3: QA phase uses Sonnet model restricted from modifying source code
- AC-3.4: Reviewer phase uses Sonnet model restricted to read-only tools plus Write (for REVIEW.md)
- AC-3.5: Each phase uses a deterministic `--session-id` UUID for tracking and resume

### FR-4: Progress and Cost Extraction

**Description:** Extract total run cost from `claude` CLI session data to update the SQLite store. Per-phase cost breakdown is deferred.

**Details:**
- After the full pipeline completes, extract total cost from available CLI output or session data
- The `pipeline-runner.ts` orchestrator updates the ForemanStore with total run cost and basic progress (phases completed, duration)
- Fall back to worktree-level heuristics (git diff for files changed) if CLI cost extraction is unavailable
- Session IDs (deterministic UUIDs) are stored in ForemanStore for resume capability
- Detailed per-phase cost tracking is out of scope; will be addressed by the future coordinator feature

**Acceptance Criteria:**
- AC-4.1: After pipeline completion, ForemanStore is updated with total run cost (best effort) and phase completion status
- AC-4.2: `foreman status` shows run progress data (current phase, phases completed, duration)
- AC-4.3: Session IDs from each CLI invocation are captured and stored for resume capability

### FR-5: Session Resume via CLI

**Description:** Replace the current SDK session resume mechanism with `claude --resume <sessionId>`.

**Details:**
- Each phase uses `--session-id <uuid>` with a deterministic UUID (e.g., `uuidv5(runId + phaseName)`)
- When `foreman run --resume` is invoked, look up the stored session ID from the most recent phase
- Invoke `claude --resume <sessionId>` in the worktree with a continuation prompt
- The tmux session for the resumed run shows the full Claude Code UI with conversation history
- `foreman attach` on a resumed run works identically to a fresh run
- `--fork-session` can be used if resume needs to branch from a previous session without modifying it

**Acceptance Criteria:**
- AC-5.1: `foreman run --resume` identifies stuck runs and resumes them via `claude --resume <sessionId>`
- AC-5.2: The resumed session continues from where the previous phase left off
- AC-5.3: `foreman attach` on a resumed run shows the live Claude Code session

### FR-6: TASK.md and Context Passing

**Description:** Ensure phase-specific prompts and task context are properly passed to the `claude` CLI via stdin piping.

**Details:**
- TASK.md is already written to the worktree before agent spawn -- `claude` will read it via the prompt instruction "Read TASK.md"
- CLAUDE.md in the worktree is automatically respected by the `claude` CLI (no special flag needed)
- Phase prompts are passed via stdin piping: `echo "<prompt>" | claude [flags]`
- For long prompts, use a heredoc or write to a temporary file and pipe: `cat /tmp/phase-prompt.txt | claude [flags]`
- `--system-prompt-file` can be used for persistent system-level instructions that apply across phases
- The prompt must include instructions to read TASK.md, phase-specific report files, and any feedback from previous phases

**Acceptance Criteria:**
- AC-6.1: Each phase's `claude` invocation receives the correct phase-specific prompt via stdin
- AC-6.2: The agent reads and acts on TASK.md content
- AC-6.3: Feedback from QA failures is included in retry prompts for the Developer phase
- AC-6.4: CLAUDE.md project instructions are respected by the CLI automatically

### FR-7: Pipeline Orchestrator (pipeline-runner.ts)

**Description:** Create a TypeScript orchestrator that runs inside the tmux pane to coordinate pipeline phases by spawning sequential `claude` CLI invocations.

**Details:**
- Replaces the current `agent-worker.ts` which uses SDK `query()` internally
- Implemented as TypeScript (`pipeline-runner.ts`) using `child_process.spawn()` to invoke `claude`
- Can directly import and call `ForemanStore` for SQLite updates (same process, no IPC needed)
- Between phases, the orchestrator:
  - Parses the previous phase's report file for verdict (PASS/FAIL)
  - Decides whether to proceed, retry, or fail
  - Updates the ForemanStore with phase completion data
  - Rotates report files (existing `rotateReport()` behavior)
- The orchestrator itself is visible in the tmux pane (showing phase transition messages between `claude` invocations)
- Passes prompts to `claude` via stdin piping using `child_process.spawn()` with stdin written programmatically

**Acceptance Criteria:**
- AC-7.1: The tmux pane shows clear phase transition markers (e.g., "--- PHASE: DEVELOPER ---")
- AC-7.2: The orchestrator correctly implements the Dev-QA retry loop (up to 2 retries)
- AC-7.3: The orchestrator correctly implements the Reviewer-Dev feedback loop
- AC-7.4: ForemanStore is updated after each phase with status and progress data
- AC-7.5: The Finalize phase (git add/commit/push, sd close) executes correctly after all phases

---

## 5. Non-Functional Requirements

### NFR-1: Performance

| Metric | Requirement |
|--------|------------|
| CLI spawn latency | < 2 seconds from dispatch to first visible output in tmux pane |
| Phase transition overhead | < 5 seconds between phases (report parsing + new CLI spawn) |
| Memory overhead | No more than 50MB additional per agent vs current SDK approach |
| Concurrent agents | Support same concurrency level as current implementation (5 default, configurable) |

### NFR-2: Reliability

| Metric | Requirement |
|--------|------------|
| Pipeline completion rate | No regression from current SDK-based pipeline |
| Crash recovery | If the orchestrator wrapper crashes, the tmux session remains for debugging |
| Rate limit handling | Rate-limited phases should be detectable and the run marked as "stuck" for resume |
| Graceful degradation | If `claude` CLI is not installed, error message should be clear and actionable |

### NFR-3: Compatibility

| Constraint | Requirement |
|-----------|------------|
| Claude CLI version | Must work with Claude CLI >= 1.0 (verified flags documented in Appendix B) |
| tmux version | Continue to support tmux 3.x (no new tmux features required) |
| macOS / Linux | Must work on both platforms (current requirement) |
| Node.js version | Continue to support Node.js 20+ |
| Existing CLI flags | All existing `foreman run` flags must continue working: `--seed`, `--attach`, `--no-attach`, `--follow`, `--model`, `--no-pipeline`, `--skip-explore`, `--skip-review`, `--resume`, `--dry-run`, `--telemetry` |

### NFR-4: Observability

| Requirement | Details |
|------------|---------|
| Log files | Pipeline orchestrator should still write structured logs to `~/.foreman/logs/<runId>.log` |
| SQLite store | All run state, progress, and cost data must continue flowing to the ForemanStore |
| Notification server | `NotificationClient` should still POST status updates to the notification server |
| tmux capture-pane | `foreman attach --follow` capture-pane polling must show real content (not blank) |

---

## 6. Acceptance Criteria (End-to-End Scenarios)

### Scenario 1: Basic Interactive Run

```
Given: A seed "abc123" is ready
When: User runs `foreman run --seed abc123`
Then: A tmux session "foreman-abc123" is created
  And: The tmux pane shows a live Claude Code session (Explorer phase)
  And: `foreman attach abc123` connects and shows the Claude Code UI
  And: The user can type into the session to interact with the agent
  And: The pipeline completes all phases (Explorer -> Developer -> QA -> Reviewer -> Finalize)
  And: `foreman status` shows the run as "completed" with progress data
```

### Scenario 2: QA Failure Retry Loop

```
Given: A running pipeline reaches the QA phase
When: QA produces a FAIL verdict in QA_REPORT.md
Then: The orchestrator retries the Developer phase with QA feedback
  And: QA runs again after the retry
  And: The tmux pane shows the phase transition and retry messaging
  And: Maximum 2 retries before proceeding to Reviewer
```

### Scenario 3: Session Resume After Rate Limit

```
Given: A pipeline run was interrupted by a rate limit at the Developer phase
  And: The run is marked as "stuck" in ForemanStore
  And: The Developer phase session ID (UUID) is stored in ForemanStore
When: User runs `foreman run --resume`
Then: Foreman identifies the stuck run and its last session ID
  And: A new tmux session spawns with `claude --resume <sessionId>`
  And: The agent continues from where it was interrupted
  And: `foreman attach` shows the resumed session
```

### Scenario 4: Multi-Agent Concurrent Dispatch

```
Given: 3 seeds are ready and max-agents is 5
When: User runs `foreman run`
Then: 3 tmux sessions are created, each running independent pipelines
  And: `foreman attach --list` shows all 3 sessions with status
  And: Each session can be independently attached
  And: All 3 complete without interfering with each other
```

### Scenario 5: Follow Mode Shows Real Output

```
Given: A pipeline run is active in a tmux session
When: User runs `foreman attach --follow abc123`
Then: The follow mode polls tmux capture-pane and shows real Claude Code output
  And: Output includes tool calls, file reads, and streaming text (not blank lines)
```

### Scenario 6: User Intervention During Run

```
Given: A running pipeline is in the Developer phase
When: User runs `foreman attach abc123` and types a correction into the session
Then: The claude process receives the user's input
  And: The agent incorporates the user's guidance
  And: The pipeline continues normally after the user's intervention
```

---

## 7. Risk Analysis

### R-1: CLI Output Parsing Fragility (Severity: Medium)

**Risk:** The `claude` CLI output format may change across versions, breaking cost extraction.
**Mitigation:** Cost tracking is best-effort for MVP (total run cost only). Use `claude --verbose` output where available. Design the parser to degrade gracefully (log warning, continue without cost data). Pin minimum CLI version >= 1.0.

### R-2: Stdin Prompt Delivery (Severity: Medium)

**Risk:** Piping prompts via stdin to `claude` in interactive mode may have edge cases with long prompts, special characters, or interaction with the TUI.
**Mitigation:** Test stdin piping extensively with real phase prompts. For very long prompts, write to a temporary file and pipe via `cat`. Use `--system-prompt-file` for persistent system instructions. Fall back to writing prompt content into TASK.md if stdin proves unreliable.

### R-3: Orchestrator Wrapper Complexity (Severity: Medium)

**Risk:** Moving pipeline orchestration from in-process TypeScript (agent-worker.ts) to a wrapper that spawns external CLI processes adds process management complexity.
**Mitigation:** Keep the wrapper as TypeScript (`pipeline-runner.ts`) using `child_process.spawn()`, maintaining the same error handling and store update patterns as the current agent-worker. Direct import of ForemanStore avoids IPC. Test extensively with the Dev-QA retry loop.

### R-4: Interactive Mode Permission Stalls (Severity: Low)

**Risk:** Despite `--dangerously-skip-permissions`, edge cases in the CLI could still prompt for user input, stalling unattended phases.
**Mitigation:** Test all phases with `--dangerously-skip-permissions` to verify no prompts appear. Users can attach and respond if needed. The orchestrator can implement a timeout to detect stalls.

### R-5: Concurrent tmux Session Stability (Severity: Low)

**Risk:** Running 5+ concurrent `claude` CLI sessions in separate tmux panes may hit terminal/process limits.
**Mitigation:** This is the same as the current approach (5 tmux sessions with agent-worker). The `claude` CLI likely uses comparable resources. Monitor resource usage during testing.

### R-6: Regression in Pipeline Behavior (Severity: Medium)

**Risk:** Subtle differences between SDK `query()` and `claude` CLI (prompt interpretation, tool behavior, exit codes) could cause pipeline regressions.
**Mitigation:** Run the existing test suite against the new implementation. Create integration tests that verify report file generation, verdict parsing, and retry logic. Run comparison tests on a sample of real tasks.

---

## 8. Dependencies and Constraints

### 8.1 Technical Dependencies

| Dependency | Type | Notes |
|-----------|------|-------|
| `claude` CLI binary | Required | Must be installed and in PATH. Minimum version >= 1.0 |
| tmux 3.x | Required | MVP requires tmux; no detached fallback |
| `@anthropic-ai/claude-agent-sdk` | Retained (planning only) | Still used for `dispatchPlanStep()` (PRD/TRD generation). Removed from agent worker pipeline |
| ForemanStore (SQLite) | Required | No schema changes expected; same progress/run tracking |
| Seeds CLI (`sd`) | Required | Used in Finalize phase; no changes needed |

### 8.2 Verified Claude CLI Flags

All flags required for this PRD have been verified against the Claude CLI:

| Flag | Status | Usage in Foreman |
|------|--------|-----------------|
| `--model <alias>` | Verified | Per-phase model selection (haiku, sonnet) |
| `--dangerously-skip-permissions` | Verified | All phases -- prevents permission prompt stalls |
| `--disallowedTools` | Verified | Per-phase tool restrictions (replaces SDK-era DCG) |
| `--session-id <uuid>` | Verified | Deterministic session tracking per phase |
| `--resume <id>` | Verified | Session resume for stuck runs |
| `--fork-session` | Verified | Available for branching resumed sessions |
| `--system-prompt-file` | Verified | System-level instructions per phase |
| `--no-session-persistence` | Verified | Available if needed (print mode only) |
| `--verbose` | Verified | Debug logging |
| `-p` / `--print` | Verified | Available for future detached fallback (not MVP) |
| `--output-format json` | Verified | Available for future cost extraction (print mode only) |
| `--max-budget-usd` | Verified (print only) | Deferred to coordinator feature |
| `--max-turns` | Verified (print only) | Deferred to coordinator feature |

**Flags confirmed NOT to exist:**
- `--cwd` -- use tmux `-c` for working directory
- `--prompt-file` -- use stdin piping or `--system-prompt-file`

### 8.3 Migration Strategy

**Direct replacement.** No feature flags, no parallel code paths.

1. Implement `pipeline-runner.ts` and update `CliSpawnStrategy` in the dispatcher
2. Replace the SDK-based `agent-worker.ts` spawn path with the CLI-based pipeline-runner
3. Remove `agent-worker.ts` from active code paths (old code preserved in git history)
4. Retain SDK only for `dispatchPlanStep()` (PRD/TRD generation); evaluate migration in a future iteration

### 8.4 Files to Create or Modify

| File | Action | Description |
|------|--------|-------------|
| `src/orchestrator/pipeline-runner.ts` | Create | TypeScript orchestrator that runs inside tmux, spawns `claude` CLI per phase via `child_process.spawn()` |
| `src/orchestrator/dispatcher.ts` | Modify | Update spawn strategy to run `pipeline-runner.ts` instead of `agent-worker.ts` |
| `src/lib/claude-cli.ts` | Create | Utility for invoking `claude` CLI with proper flags, stdin prompt delivery, output parsing |
| `src/orchestrator/agent-worker.ts` | Remove | Replaced by `pipeline-runner.ts`; preserved in git history |
| `src/cli/commands/run.ts` | Modify | Ensure `--resume` uses CLI session IDs |
| `src/cli/commands/attach.ts` | Minor | Verify attach works with new session format; ensure full interactive (no read-only) |

---

## 9. Implementation Priority

The following ordering reflects the dependency chain and MVP criticality:

| Priority | Requirement | Rationale |
|----------|-------------|-----------|
| P0 | FR-1 (CLI Spawn) + FR-7 (Pipeline Orchestrator) | Core infrastructure: spawn `claude` in tmux via `pipeline-runner.ts`. Nothing works without this. |
| P0 | FR-2 (Pipeline Orchestration) | Phase logic: Explorer, Developer, QA retry loop, Reviewer, Finalize. Tightly coupled with FR-1/FR-7. |
| P1 | FR-6 (Context Passing) | Prompt delivery via stdin, CLAUDE.md auto-pickup, phase-specific prompts. Required for phases to do correct work. |
| P1 | FR-3 (Phase-Specific Flags) | `--disallowedTools` per phase, `--model` per phase, `--dangerously-skip-permissions`. Required for correct phase behavior. |
| P2 | FR-5 (Session Resume) | `--session-id` for tracking, `--resume` for stuck runs. Important but can ship slightly after core pipeline. |
| P3 | FR-4 (Cost Extraction) | Total run cost only. Nice to have for MVP, not blocking. |

---

## 10. Release Plan

### 10.1 MVP -- Target: 2 weeks

- `pipeline-runner.ts` TypeScript orchestrator with all 5 phases
- `claude` CLI spawn in interactive mode inside tmux (tmux required)
- `--dangerously-skip-permissions` for all phases
- `--disallowedTools` per phase for role-based tool enforcement
- `--session-id` with deterministic UUIDs per phase
- Stdin prompt piping for phase-specific prompts
- Direct replacement of SDK-based agent-worker (no feature flags)
- Integration tests for pipeline phases and retry logic

### 10.2 Resume and Polish -- Target: 1 week after MVP

- Session resume via `claude --resume <sessionId>`
- Total run cost extraction (best effort)
- Documentation updates
- `foreman attach` verification with full interactive mode

### 10.3 Future Iterations (Out of Scope for This PRD)

- Per-phase cost tracking and budget enforcement (coordinator feature)
- Detached/print-mode fallback for non-tmux environments
- Read-only attach mode
- `dispatchPlanStep()` migration from SDK to CLI

---

## Appendix A: Current vs Proposed Architecture

### Current (SDK-based)

```
foreman run
  --> Dispatcher.spawnAgent()
    --> TmuxSpawnStrategy.spawn()
      --> tmux new-session "tsx agent-worker.ts <config>"  [output redirected to logs]
        --> agent-worker.ts
          --> query({ prompt, options }) [SDK call, headless]
          --> for await (message of query) { ... }  [processes messages in-process]
          --> store.updateRun(...)  [direct SQLite writes]
```

### Proposed (CLI-based)

```
foreman run
  --> Dispatcher.spawnAgent()
    --> CliSpawnStrategy.spawn()
      --> tmux new-session -c <worktree> "tsx pipeline-runner.ts <config>"
        --> pipeline-runner.ts
          --> spawn("claude", ["--dangerously-skip-permissions", "--model", "haiku",
                "--disallowedTools", "Write", "Edit", "--session-id", "<uuid>"])
              with stdin: "<explorer prompt>"
            --> [LIVE CLAUDE CODE TUI IN TMUX PANE -- USER CAN ATTACH AND INTERACT]
          --> parseReport("EXPLORER_REPORT.md")
          --> spawn("claude", ["--dangerously-skip-permissions", "--model", "sonnet",
                "--disallowedTools", "Bash(git push*)", "--session-id", "<uuid>"])
              with stdin: "<developer prompt>"
            --> [LIVE CLAUDE CODE TUI IN TMUX PANE]
          --> parseReport("QA_REPORT.md") --> retry loop if FAIL
          --> finalize()  [git add/commit/push, sd close]
          --> store.updateRun(...)  [direct SQLite writes]
```

### Key Difference

The `claude` process is the foreground process in the tmux pane. Users see its TUI directly. The `pipeline-runner.ts` wrapper manages phase transitions but `claude` owns the terminal during each phase. Users who `foreman attach` get full interactive access -- they can type into the running `claude` session.

---

## Appendix B: Claude CLI Flag Reference

Verified flags relevant to this PRD:

```
claude --model <alias>                    # Model: sonnet, opus, haiku, or full name
claude --dangerously-skip-permissions     # Skip ALL permission prompts
claude --disallowedTools "Tool1" "Tool2"  # Remove tools from context
claude --session-id <uuid>               # Set specific session ID (must be valid UUID)
claude --resume <id> "optional query"     # Resume session by ID
claude --fork-session                     # Fork when resuming (new session)
claude --system-prompt-file <path>        # Load system prompt from file
claude --verbose                          # Enable verbose logging
claude -p                                 # Print mode (non-interactive)
claude --output-format json               # JSON output (print mode only)
claude --max-budget-usd <amount>          # Budget cap (print mode only)
claude --max-turns <n>                    # Turn limit (print mode only)
claude --continue                         # Load most recent conversation in cwd
claude --no-session-persistence           # Don't save sessions (print mode only)
```

---

## Changelog

### v1.1 (2026-03-13) -- User Interview Refinement

**Changes based on stakeholder interview conducted 2026-03-13:**

- **Resolved all 6 open questions** from v1.0 using verified Claude CLI flag documentation (see Appendix B)
- **Removed FR-6 (Detached Process Fallback)** from MVP scope. Tmux is required for MVP; print-mode fallback deferred to future iteration
- **Removed budget/turns enforcement** from scope. `--max-budget-usd` and `--max-turns` are print-mode only; deferred to future coordinator feature
- **Removed feature flag migration strategy**. Direct replacement of SDK agent-worker with no `--cli`/`--sdk` flags or parallel code paths
- **Simplified cost tracking** to total run cost only. Per-phase cost breakdown deferred to coordinator feature
- **Added `--disallowedTools` per-phase mapping** (FR-3) with specific tool restrictions per role, replacing SDK-era DCG
- **Added stdin prompt piping strategy** (FR-6) since `--prompt-file` does not exist on the CLI
- **Added `--session-id` with deterministic UUIDs** (FR-3, FR-5) for reliable session tracking and resume
- **Confirmed TypeScript** (`pipeline-runner.ts`) as pipeline orchestrator approach using `child_process.spawn()`
- **Confirmed `--dangerously-skip-permissions`** for all phases (simple, replaces DCG)
- **Confirmed full interactive attach** -- users can type into attached sessions, no read-only mode
- **Confirmed interactive mode** for all phases (not print mode) -- live TUI in tmux is the core value
- **Added Section 9 (Implementation Priority)** with explicit P0-P3 ordering
- **Renumbered FRs** after removing detached fallback: old FR-7 became FR-6, old FR-8 became FR-7
- **Updated risk analysis** to reflect new architecture decisions (removed session ID risk, added stdin prompt risk, adjusted severities)
- **Added Appendix B** with complete verified CLI flag reference
- **Added Scenario 6** (User Intervention During Run) to end-to-end acceptance criteria

### v1.0 (2026-03-13) -- Initial Draft

- Initial PRD creation with full requirements, personas, and architecture proposal
- 6 open questions pending CLI capability research
