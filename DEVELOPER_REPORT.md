# Developer Report: Tool enforcement guards for agent roles

## Approach

The core tool enforcement implementation (whitelist model, `ALL_AGENT_TOOLS`, `getDisallowedTools()`, and `disallowedTools` SDK option) was already fully implemented in commit 82f94c5. This iteration addresses the NOTE-level feedback from the previous code review, improving clarity and type safety without changing runtime behaviour.

## Files Changed

- **src/orchestrator/roles.ts** — Updated the `ALL_AGENT_TOOLS` JSDoc comment to clarify that this constant represents Claude Code's agent-level tool vocabulary, *not* the `@anthropic-ai/claude-agent-sdk` library's exported interface. The old comment said "Keep this sorted and up-to-date with SDK releases", which was misleading because several tools in the list (`CronCreate`, `CronDelete`, `CronList`, `TeamCreate`, `TeamDelete`, `SendMessage`, `EnterWorktree`, `ExitWorktree`, `EnterPlanMode`, `ExitPlanMode`) are Claude Code runtime primitives, not SDK exports. The new comment names those tools explicitly and directs maintainers to check the Claude Code changelog rather than the SDK package changelog.

- **src/orchestrator/agent-worker.ts** — Added a comment above the `allowedSummary` / log-file write at line 328 to document that the `[PHASE: <ROLE>] Starting (...)` log format is intentionally stable. Downstream tooling (cost analysis scripts, log parsers) may pattern-match on this line, so the comment warns maintainers to update any such tooling if the format changes.

- **src/orchestrator/__tests__/roles.test.ts** — Imported `RoleConfig` type and added `satisfies RoleConfig` to the two edge-case test objects in the `getDisallowedTools` suite ("returns empty array for a hypothetical all-tools config" and "returns all tools for empty allowedTools"). This ensures TypeScript will flag these test fixtures as structurally invalid if `RoleConfig` gains new required fields in the future, rather than silently widening the type.

## Tests Added/Modified

- **src/orchestrator/__tests__/roles.test.ts** — No new test cases added; two existing edge-case configs updated with `satisfies RoleConfig` for compile-time type safety. All 47 tests continue to pass.

## Decisions & Trade-offs

- **Skipped narrowing `getDisallowedTools` signature** — The reviewer noted that accepting `{ allowedTools: ReadonlyArray<string> }` instead of `RoleConfig` would make the dependency explicit. However, the feedback itself described the current form as "idiomatic for this codebase's pattern of passing full configs", so the signature was left unchanged to avoid unnecessary churn.

- **Log format comment is advisory, not enforced** — There is currently no automated test for the exact log line format. The comment serves as a human-readable contract. A more rigorous approach would snapshot-test the log output, but that would require a heavier test harness and is out of scope for NOTE-level feedback.

## Known Limitations

- `ALL_AGENT_TOOLS` still requires manual updates when new Claude Code tools are released; the existing test ("is sorted alphabetically", "has no duplicate entries") catches structural regressions but cannot detect missing tools.
- `dispatcher.ts` still hardcodes `permissionMode: "bypassPermissions"` without role-based tool enforcement (pre-existing gap, noted in the Explorer Report).
