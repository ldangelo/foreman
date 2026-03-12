# Code Review: Integrate MCP Agent Mail for inter-agent communication

## Verdict: FAIL

## Summary
The implementation delivers two features: (1) a clean `maxTurns → maxBudgetUsd` migration with appropriate per-role budget values, and (2) a new in-process MCP mail server enabling inter-agent communication across pipeline phases. The `mcp-mail-server.ts` module is well-structured, the business logic is correct, and the 37-test suite thoroughly covers the new code. However, a `clearAll()` method was explicitly designed for use between pipeline retries (per its docstring) but is never called in `runPipeline()`, causing stale messages to accumulate across dev-QA retry loops. This could cause QA agents on retry N to receive both old and new developer messages, leading to potentially confusing or conflicting context. The issue is straightforward to fix and should be resolved before shipping.

## Issues

- **[WARNING]** `src/orchestrator/agent-worker.ts:591–596` — `mailServer.clearAll()` is never called at retry-loop boundaries. The `MailServerHandle.clearAll()` docstring explicitly states it is "useful between pipeline retries", and the method is wired up and tested for exactly this purpose. Without a `clearAll()` call before each developer retry, QA and Developer inboxes accumulate messages from all prior retry iterations. On retry 2, the QA agent will see developer messages from both retry 1 and retry 2, which may introduce conflicting or outdated context. Fix: call `mailServer.clearAll()` (or selectively clear specific inboxes) at the top of the `while` retry loop body before each developer phase.

- **[WARNING]** `src/orchestrator/mcp-mail-server.ts:52` — `mcpConfig` is typed `any` on the `MailServerHandle` interface. This suppresses type-checking at every call site in `agent-worker.ts` where `mailServer.mcpConfig` is passed into `mcpServers`. The developer comments that `McpSdkServerConfigWithInstance` is not easily importable, but the actual shape returned by `createSdkMcpServer()` can be inferred via `ReturnType<typeof createSdkMcpServer>` instead. The `any` typing means future SDK shape changes will not produce a compile-time error.

- **[NOTE]** `src/orchestrator/mcp-mail-server.ts:148–200` — The `as unknown as ReturnType<typeof tool>` double-cast on both tool definitions is a compile-time workaround for a Zod v3/v4 type incompatibility with the SDK. It has no runtime impact and is clearly commented, but it is a code smell that may silently break if either Zod or the SDK is upgraded. Worth tracking as a TODO or suppressing with a more targeted `// @ts-expect-error` and explanation.

- **[NOTE]** `src/orchestrator/mcp-mail-server.ts:98–122` — The `from` field in `send_message` is not validated against `MAIL_ROLES`. Any string is accepted as a sender identity. Since agents are trusted LLMs in an internal pipeline, this is not a security concern, but a typo (e.g., `from: "dev"` instead of `"developer"`) would silently produce a misleading log entry. Validating `from` the same way `to` is validated would be a minor defensive improvement.

- **[NOTE]** `src/orchestrator/agent-worker.ts:714–723` — `logMailActivity()` logs cumulative inbox state after each phase (messages are never consumed). After retry cycles, the logs will show the same messages multiple times (once after each developer/QA phase). This is correct given non-destructive read semantics, but a log comment noting "cumulative since pipeline start" would clarify intent.

## Positive Notes
- The `maxTurns → maxBudgetUsd` migration is complete, correct, and consistent: the `RoleConfig` interface, `ROLE_CONFIGS` values, `runPhase()` log header, and `query()` options are all updated together with sensible per-role budgets ($1 haiku explorer, $5/$3/$2 for sonnet dev/qa/reviewer).
- The `mcp-mail-server.ts` module is cleanly separated with well-named types, a thin factory function, and test-friendly `_sendMessage`/`_readMessages` escape hatches — a good design pattern for an in-process MCP server.
- The `MailServerHandle.getMessages()` and `getAllMessages()` methods correctly return copies rather than internal array references, preventing external mutation of mailbox state.
- Test coverage for the new module is comprehensive: 37 tests covering normal paths, error paths, ID counter behavior, inbox isolation, copy semantics, `clearAll()` reset, instance independence, and a realistic pipeline simulation.
- All four role prompts include clear, consistent agent-mail documentation with role-specific examples and an explicit `read_messages(...)` starting instruction for the receiving phases (developer, QA, reviewer).
- The `logMailActivity()` helper is correctly fire-and-forget (`.catch(() => {})`) consistent with other non-fatal logging calls in the file.
