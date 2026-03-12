# Developer Report: Tool enforcement guards for agent roles

## Approach

Implemented role-based tool access control using a whitelist model. Each agent role declares the SDK tools it is permitted to use (`allowedTools`). A `getDisallowedTools()` helper computes the complement (tools NOT in the whitelist), and this list is passed to the SDK's `disallowedTools` option in `runPhase()`. This enforces role separation at the SDK level — the SDK silently blocks disallowed tools before the agent can call them.

## Files Changed

- `src/orchestrator/roles.ts` — Added:
  - `allowedTools: ReadonlyArray<string>` property to `RoleConfig` interface
  - `ALL_AGENT_TOOLS` constant listing all 24 known Claude Agent SDK tools (sorted alphabetically)
  - `getDisallowedTools(config: RoleConfig): string[]` function computing the complement
  - Per-role `allowedTools` in `ROLE_CONFIGS`:
    - **explorer**: `[Glob, Grep, Read, Write]` — read-only; Write allows producing EXPLORER_REPORT.md
    - **developer**: `[Agent, Bash, Edit, Glob, Grep, Read, TaskOutput, TaskStop, TodoWrite, WebFetch, WebSearch, Write]` — full access
    - **qa**: `[Bash, Edit, Glob, Grep, Read, TodoWrite, Write]` — can run/edit tests; cannot spawn agents
    - **reviewer**: `[Glob, Grep, Read, Write]` — read-only; Write allows producing REVIEW.md

- `src/orchestrator/agent-worker.ts` — Updated `runPhase()` to:
  - Import `getDisallowedTools` from roles.ts
  - Compute `disallowedTools` from the role config before the SDK call
  - Pass `disallowedTools` to the SDK `query()` options
  - Log the allowed tools summary and counts for observability

## Tests Added/Modified

- `src/orchestrator/__tests__/roles.test.ts` — Added 36 new tests across three new suites:
  - **`ALL_AGENT_TOOLS`**: validates the list is complete, sorted, unique, contains expected tools
  - **`tool enforcement guards`**: validates each role's `allowedTools` whitelist — explorer/reviewer are read-only, developer has full access, QA can't spawn agents, no role has AskUserQuestion
  - **`getDisallowedTools`**: validates the computation — allowed+disallowed=ALL_AGENT_TOOLS, developer has fewest disallowed, edge cases (empty/full allowedTools)

All 47 tests pass (11 original + 36 new).

## Decisions & Trade-offs

- **Whitelist model** — More secure than a blacklist; new SDK tools are automatically disallowed until explicitly added to a role's `allowedTools`.
- **`Write` for read-only roles** — Explorer and reviewer need `Write` to produce their report files. An alternative would be granting write access only to specific paths, but the SDK's `disallowedTools` mechanism is tool-level, not path-level.
- **`AskUserQuestion` excluded from all roles** — The pipeline runs fully autonomously; human interaction would block indefinitely.
- **24 tools in ALL_AGENT_TOOLS** — Counted from SDK tool list. If the SDK gains new tools, `ALL_AGENT_TOOLS` becomes stale; the test "all allowed tools exist in ALL_AGENT_TOOLS" will catch if a role references a non-existent tool, but won't catch new SDK tools that should be considered for role access.

## Known Limitations

- **No path-level enforcement for Write** — Explorer and reviewer can technically write to any file, not just their report files. Enforcing path restrictions would require a different mechanism.
- **SDK tool list drift** — When the SDK gains new tools, they are automatically disallowed for all roles (whitelist model protects against this), but `ALL_AGENT_TOOLS` should be updated for documentation/test accuracy.
- **dispatcher.ts not updated** — The `dispatchPlanStep()` function in dispatcher.ts still uses hardcoded `permissionMode: "bypassPermissions"` without role-based tool enforcement. This is noted in the Explorer Report as a known gap and is out of scope for this task.
