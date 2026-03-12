# Explorer Report: Integrate MCP Agent Mail for inter-agent communication

## Summary
Foreman currently uses a sequential agent pipeline (Explorer → Developer → QA → Reviewer) with file-based communication (markdown reports). The task is to integrate MCP (Model Context Protocol) Agent Mail to enable direct inter-agent messaging, enabling more flexible and real-time communication between agents.

## Relevant Files

### Core Pipeline & Orchestration
- **src/orchestrator/agent-worker.ts** — Main worker script that runs agents as SDK sessions. Contains `runPhase()` (lines 310-399) for executing individual phases and `runPipeline()` (lines 501-649) orchestrating the full pipeline. Currently reads/writes report files to coordinate between phases. Key functions: `readReport()` (line 401), `rotateReport()` (line 411).

- **src/orchestrator/dispatcher.ts** — Spawns agent-worker as detached child process. `spawnAgent()` (line ~149) creates the worker config and launches the child. Passes model, worktree, and seed info to agents.

- **src/orchestrator/lead-prompt.ts** — Generates the prompt for the Engineering Lead agent that coordinates sub-agents. Shows current communication model: "Sub-agents work collaboratively in the same worktree, communicating via report files (EXPLORER_REPORT.md, DEVELOPER_REPORT.md, QA_REPORT.md, REVIEW.md)" (line 6). The lead spawns sub-agents using the Agent tool and reads reports between phases.

### Configuration & Types
- **src/orchestrator/roles.ts** — Defines role configurations (`ROLE_CONFIGS`, lines 21-46) with model selection and `reportFile` for each role. Prompt templates for each role (explorerPrompt, developerPrompt, qaPrompt, reviewerPrompt) describe the current file-based report communication pattern. Each role expects to write a specific markdown report file.

- **src/orchestrator/types.ts** — Type definitions. `AgentRole` (line 7): "lead" | "explorer" | "developer" | "qa" | "reviewer" | "worker". Interface `WorkerConfig` in agent-worker.ts (lines 34-48) defines what config is passed to agents.

### Worker Configuration
- **src/orchestrator/agent-worker.ts, interface WorkerConfig** (lines 34-48) — Current config structure passed to agents includes: runId, projectId, seedId, model, worktreePath, prompt, env, resume, pipeline. No MCP-related fields yet.

### Data Flow
- **src/lib/store.ts** — SQLite store for tracking runs and progress. Agents update run status via `updateRun()` and `updateRunProgress()`. Could store MCP connection info here.

## Architecture & Patterns

### Current Communication Model
1. **File-based**: Agents write markdown reports (EXPLORER_REPORT.md, etc.) to the worktree
2. **Sequential**: runPipeline() reads each report and decides next phase (lines 562-567 for QA verdict, lines 592-594 for Review verdict)
3. **Feedback loop**: When QA/Review fails, previous feedback is passed to Developer as string in prompt (lines 109-111, 544)
4. **Orchestration**: TypeScript orchestrator (agent-worker) reads reports, parses verdicts (parseVerdict), extracts issues (extractIssues), and manages retries

### Key Functions for Report Handling
- `readReport(worktreePath, filename)` (line 401) — Reads markdown files
- `rotateReport()` (line 411) — Versions reports with timestamp before overwrite
- `parseVerdict()` and `extractIssues()` (imported from roles.ts) — Parse report content for automation

### SDK Integration
- Uses `@anthropic-ai/claude-agent-sdk` version 0.2.72 (package.json:28)
- Agents are spawned as separate `query()` calls (line 158 for single-agent, line 330 for phases)
- Query options include: cwd (worktree), model, permissionMode, env, persistSession, resume, maxBudgetUsd (line 337)
- Each phase runs in isolated SDK session with own budget (roles.ts: explorer=$1, developer=$5, qa=$3, reviewer=$2)

## Dependencies

### External
- **@anthropic-ai/claude-agent-sdk** (0.2.72) — No current MCP support explicitly; agents run via SDK query()
- **better-sqlite3** (12.6.2) — Used for data persistence in ForemanStore

### Internal
- ForemanStore (src/lib/store.ts) — Manages run persistence and progress tracking
- ROLE_CONFIGS and prompt templates — Define phase behavior

### What Depends on This Code
- Dispatcher.ts spawns agent-worker instances
- CLI commands (src/cli/commands/run.ts) invoke dispatcher
- Pipeline mode relies on report file structure (agent-worker.ts, roles.ts)

## Existing Tests
- **src/orchestrator/__tests__/agent-worker.test.ts** — Tests for config file handling and logging. Currently minimal (only tests config read/delete and log creation).
- **src/orchestrator/__tests__/agent-worker-team.test.ts** — Tests for multi-agent team orchestration
- **src/orchestrator/__tests__/dispatcher.test.ts** — Tests for dispatcher functionality
- **No existing tests for MCP** — This is a new integration

## Recommended Approach

### Phase 1: MCP Server Infrastructure
1. **Add @modelcontextprotocol/sdk** to package.json (version ^1.0.0+)
2. **Create src/orchestrator/mcp-mail-server.ts**:
   - Implement MCP server with "send_message" and "read_messages" resources
   - Store messages in memory or SQLite (keyed by agent role + run ID)
   - Support mailbox pattern: agents can send messages to other agent roles
3. **Extend WorkerConfig** (agent-worker.ts):
   - Add `mcpServerUrl` or `mcpServerPort` field
   - Add `agentId` field (unique identifier for this agent instance)

### Phase 2: Integration into Pipeline
1. **Update agent-worker.ts runPipeline()**:
   - Start MCP server before first phase
   - Pass server endpoint to agents via environment variables or config
   - Wait for all phases to complete before closing server
2. **Update runPhase()**:
   - Pass MCP server info to SDK via env or new queryOpts field
   - Agents can now use MCP tools to send/receive messages

### Phase 3: Agent-Side Integration
1. **Update role prompts** (roles.ts):
   - Add section explaining MCP Agent Mail usage
   - Document send_message and read_messages tools
   - Show examples: "Read messages from QA to understand failures", "Send status to Lead"
2. **Modify lead-prompt.ts**:
   - Add instructions for agents to use MCP for coordination
   - Lead can monitor agent messages in real-time instead of waiting for reports

### Phase 4: Report Files → Hybrid Approach
1. **Keep report files** as primary deliverables (backward compatible)
2. **Add supplementary MCP messages** for:
   - Real-time status updates (agent → orchestrator)
   - Quick feedback queries (QA → Developer)
   - Phase completion notifications
3. **Update runPipeline()** to check for MCP messages as alternative/supplement to file parsing

### Potential Pitfalls & Edge Cases
1. **SDK Tool Availability**: MCP tools must be available within SDK query context. May need SDK support or workaround to expose MCP client.
2. **Message Ordering**: Agents may send messages while another phase is running. Need queue/buffer mechanism.
3. **Server Lifecycle**: MCP server must start before any agent query and persist for the full pipeline duration.
4. **Backward Compatibility**: Existing file-based reports must continue working (some agents may not use MCP).
5. **Error Handling**: Agent crashes during message send should not crash orchestrator. Need timeout/retry logic.
6. **Testing**: Current tests don't cover MCP; need integration tests for message passing.
7. **Lead Agent Coordination**: The Engineering Lead (in lead-prompt.ts) also runs as an SDK agent and may need MCP client integration to communicate with sub-agents.

## Implementation Order
1. Add MCP dependency and server infrastructure (Phase 1)
2. Integrate server into agent-worker pipeline (Phase 2)
3. Update prompts with MCP instructions (Phase 3)
4. Write integration tests
5. (Optional) Enable truly parallel agent execution with MCP coordination (Phase 4)

## Questions for Developer
1. Should MCP server be embedded in agent-worker.ts or a separate service?
2. Should agents send MCP messages or only receive them (read-only reports)?
3. Should the Lead agent also use MCP to communicate with sub-agents, or keep its current prompt-based orchestration?
4. What message schema should MCP mailbox use (JSON? structured format)?
