# Code Review: Tool enforcement guards for agent roles

## Verdict: PASS

## Summary
The implementation correctly adds role-based tool access control to the foreman pipeline by introducing a whitelist-based `allowedTools` field on each `RoleConfig` and a `getDisallowedTools()` helper that computes the complement. The computed set is passed directly to the SDK's `disallowedTools` option in `runPhase()`, enforcing that explorer/reviewer cannot modify source code, QA cannot spawn agents, and only developer has full access. The change is minimal (three files touched, zero pre-existing tests broken), well-commented, and ships with 36 new passing tests covering all meaningful behaviors including edge cases. TypeScript compiles cleanly with zero errors.

## Issues

- **[NOTE]** `src/orchestrator/roles.ts:32-57` — `ALL_AGENT_TOOLS` contains several tool names (`CronCreate`, `CronDelete`, `CronList`, `TeamCreate`, `TeamDelete`, `SendMessage`, `EnterWorktree`, `ExitWorktree`, `EnterPlanMode`, `ExitPlanMode`) that are not defined in `sdk-tools.d.ts`. These appear to be Claude Code agent-level tools available in the running process environment rather than built-in SDK primitives. This is not a bug (the SDK accepts any `string[]` for `disallowedTools`), but the comment "Keep this sorted and up-to-date with SDK releases" may be misleading — this list is really Claude Code's tool vocabulary, not the SDK library's exported interface. A comment clarifying this distinction would reduce future confusion when someone checks the SDK changelog.

- **[NOTE]** `src/orchestrator/agent-worker.ts:328` — The `allowedSummary` string (all allowed tool names joined) is written to the log file on every phase start. For developer's 12-tool list this is verbose but harmless. Worth noting in case log parsers downstream depend on the exact log line format.

- **[NOTE]** `src/orchestrator/roles.ts:63-66` — `getDisallowedTools` takes a `RoleConfig` but only uses `config.allowedTools`. A narrower signature accepting `{ allowedTools: ReadonlyArray<string> }` would make the dependency explicit, though the current form is idiomatic for this codebase's pattern of passing full configs.

- **[NOTE]** `src/orchestrator/__tests__/roles.test.ts:300-320` — The edge-case tests for "all-tools config" and "no-tools config" manually construct `RoleConfig` objects with hardcoded budget/model values. These will silently pass even if `RoleConfig` gains required fields in the future. Using `satisfies RoleConfig` instead of the implicit type widening would make the intent clearer, but this is a minor style point.

## Positive Notes
- Whitelist model is the right security posture — adding tools requires explicit opt-in rather than remembering to block new tools.
- `getDisallowedTools()` is a clean, pure function that is trivially testable.
- The complementarity invariant (`allowed ∪ disallowed = ALL_AGENT_TOOLS`) is verified by test for every role, which gives strong confidence the implementation is correct.
- The inline comment explaining the relationship between `bypassPermissions` and `disallowedTools` (lines 323-326 of agent-worker.ts) is genuinely helpful for future maintainers.
- Explorer uses haiku and its `allowedTools` is intentionally small — the cost profile stays low for the read-only phase.
- `AskUserQuestion` exclusion from all roles is correctly enforced and explicitly tested, ensuring the pipeline remains fully autonomous.
- Log output updated to show both allowed-tool count and disallowed-tool count, making operational debugging straightforward.
