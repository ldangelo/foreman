# Developer Report: Integrate MCP Agent Mail for inter-agent communication

## Approach

Implemented an in-process MCP mailbox server using the Claude Agent SDK's `createSdkMcpServer` and `tool` APIs. The server provides `send_message` and `read_messages` tools to pipeline agents, enabling direct inter-agent messaging alongside the existing file-based report system.

The key design choice was to use the SDK's built-in `McpSdkServerConfigWithInstance` type (via `createSdkMcpServer`), which allows the server to run in the same Node.js process as the orchestrator. This means:
1. A single server instance is created per pipeline run
2. The same in-memory mailboxes are shared across all phases (Explorer → Developer → QA → Reviewer)
3. No external process or port is required

## Files Changed

- **src/orchestrator/mcp-mail-server.ts** (new) — Creates the MCP mail server with `send_message` and `read_messages` tools backed by an in-memory Map. Exposes `_sendMessage` and `_readMessages` for unit testing without needing MCP transport. Also exports `MAIL_ROLES` constant and `MailMessage` types.

- **src/orchestrator/agent-worker.ts** — Integrated the mail server into `runPipeline()`:
  - Imports `createMailServer` and `MailServerHandle`
  - Creates a `mailServer` instance at the start of each pipeline run
  - Passes `mcpServers: { "agent-mail": mailServer.mcpConfig }` to every `runPhase()` call via the `query()` options
  - Added `mailServer` as an optional 7th parameter to `runPhase()`
  - Added `logMailActivity()` helper to log inter-agent messages to the run log file after each phase

- **src/orchestrator/roles.ts** — Added a `## MCP Agent Mail` section to all four role prompt templates (Explorer, Developer, QA, Reviewer) explaining the available tools, when to use them, and the initial `read_messages` call each role should make.

## Tests Added/Modified

- **src/orchestrator/__tests__/mcp-mail-server.test.ts** (new, 31 tests) — Comprehensive test coverage including:
  - Server creation (mcpConfig structure, type, name)
  - Initial empty state for all MAIL_ROLES
  - `_sendMessage`: success paths, error on unknown role, incrementing IDs, independent inboxes, multiple messages
  - `_readMessages`: empty inbox, single/multiple messages, ordering, formatted output content
  - `getMessages()`: copy semantics (mutation safety)
  - `getAllMessages()`: snapshot with correct inbox counts
  - `clearAll()`: removes messages and resets ID counter
  - Multiple instances are independent
  - Pipeline simulation test (Explorer → Developer → QA → Reviewer flow)
  - Role prompt integration tests (all 4 prompts mention agent-mail, send_message, read_messages, and their role name)

## Decisions & Trade-offs

**In-process vs. external server**: Used `createSdkMcpServer` (in-process) rather than a separate MCP HTTP/stdio server. This avoids port management complexity and keeps the server lifecycle tied to the pipeline run.

**Hybrid communication**: Kept existing file-based reports (EXPLORER_REPORT.md etc.) as the primary deliverable mechanism. Agent mail is supplementary — for real-time status updates and direct agent-to-agent communication that doesn't need to be in the final report.

**Exposed test helpers (`_sendMessage`, `_readMessages`)**: Since `McpServer.callTool()` is not a public API, unit tests use these directly-exposed functions. This is a pragmatic trade-off: clean unit tests without MCP transport setup.

**Optional parameter in `runPhase()`**: The `mailServer` parameter is optional so the function signature stays backwards-compatible in case it's called from other contexts.

**`as unknown as ReturnType<typeof tool>` casts**: The `tool()` helper from the SDK has complex Zod v3/v4 generic type handling. The double cast avoids a type incompatibility between Zod v4's `ZodString` and the SDK's union `AnyZodRawShape` type. This is a TypeScript limitation, not a runtime issue.

## Known Limitations

- **No message persistence**: Messages are in-memory only. If the pipeline process crashes and restarts, messages are lost (file-based reports survive).
- **No cross-retry clearing**: Messages accumulate across dev→QA retries. A future enhancement could call `mailServer.clearAll()` between retry cycles.
- **Agents must opt in**: The mail tools are available but agents only use them if their prompts guide them to. This is intentional — the feature is additive and doesn't break the existing pipeline.
- **One server per pipeline run**: Currently one `MailServerHandle` per `runPipeline()` call. Multiple concurrent pipeline runs each get their own isolated server.
