# Explorer Report: Tool enforcement guards for agent roles

## Summary
Tool enforcement guards have already been implemented (commit 82f94c5) to restrict agent roles to only the tools they require. The implementation uses SDK-level `disallowedTools` configuration to enforce role-based access control, ensuring explorer and reviewer agents cannot modify source code, QA cannot spawn sub-agents, and only the developer has full read/write/execute access.

## Relevant Files

### Core Implementation
- **src/orchestrator/roles.ts** — Defines role configs with `allowedTools` whitelists and `getDisallowedTools()` computation function. Contains:
  - `RoleConfig` interface (lines 13-24): Added `allowedTools` property
  - `ALL_AGENT_TOOLS` constant (lines 27-50): Complete list of all 25 SDK tools
  - `getDisallowedTools()` function (lines 52-54): Computes disallowed tools as complement of allowed tools
  - `ROLE_CONFIGS` (lines 56+): Per-role tool configurations

- **src/orchestrator/agent-worker.ts** — Uses tool enforcement in pipeline phase execution:
  - `runPhase()` function (lines 310-399): Gets disallowed tools from config, logs tool guard summary, passes `disallowedTools` to SDK `query()` options
  - Line 322-327: Computes and logs disallowed tools summary
  - Line 335-348: Applies disallowed tools to SDK options
  - Line 340-345: Comment explaining complementary purpose of `bypassPermissions` + `disallowedTools`

### Types
- **src/orchestrator/types.ts** — Defines `AgentRole` type (line 7) including "explorer" | "developer" | "qa" | "reviewer"

### Tests
- **src/orchestrator/__tests__/roles.test.ts** — Comprehensive test coverage (197 lines added):
  - "tool enforcement guards" suite: Tests that each role has correct `allowedTools` set
  - "getDisallowedTools" suite: Tests disallowed computation logic
  - Tests verify explorer/reviewer are read-only, developer has full access, QA can't spawn agents, AskUserQuestion excluded from all roles

## Architecture & Patterns

### Role Tool Matrices
Four specialized agent roles with specific tool access patterns:

| Role | Purpose | Allowed Tools | Rationale |
|------|---------|---|---|
| **explorer** | Codebase analysis, read-only | Read, Glob, Grep, Write | Writes EXPLORER_REPORT.md only; no source modification |
| **developer** | Implementation, full access | Read, Write, Edit, Bash, Glob, Grep, Agent, TaskOutput, TaskStop, TodoWrite, WebFetch, WebSearch | Needs full control; TaskOutput/TaskStop to manage sub-agents |
| **qa** | Testing and validation | Read, Write, Edit, Bash, Glob, Grep, TodoWrite | Can modify test files; cannot spawn agents or write reports other than tests |
| **reviewer** | Code review, read-only | Read, Glob, Grep, Write | Writes REVIEW.md only; cannot modify source or run tests |

### Implementation Approach
1. **Whitelist model** — Each role declares `allowedTools` (what it CAN do)
2. **Computed disallowed set** — `getDisallowedTools()` computes complement for SDK
3. **SDK enforcement** — `disallowedTools` option passed to `query()` prevents unauthorized tool use
4. **Complementary guards** — Both `permissionMode: "bypassPermissions"` (headless operation) and `disallowedTools` (role restriction) work together

### Key Design Decisions
- **AskUserQuestion excluded** — No role uses it; pipeline runs fully autonomous without human interaction
- **Write included for explorer/reviewer** — Allows them to produce report files
- **TaskOutput/TaskStop for developer** — Enables background agent management without agent spawning permission for other roles
- **Comprehensive SDK tool list** — 25 tools tracked in `ALL_AGENT_TOOLS` to catch SDK drift

## Dependencies
- **Claude Agent SDK** (@anthropic-ai/claude-agent-sdk): Provides `disallowedTools` option in `query()` options
- **Vitest**: Testing framework for 18+ tool enforcement test cases
- **Types**: AgentRole, RoleConfig, SDKOptions

## What Depends on This Code
- `src/orchestrator/agent-worker.ts`: Uses `ROLE_CONFIGS` and `getDisallowedTools()` in `runPhase()`
- `src/orchestrator/dispatcher.ts`: Currently hardcoded to `permissionMode: "bypassPermissions"` (no role-based tool enforcement yet)
- Pipeline agents: All four roles (explorer→developer→qa→reviewer) respect tool restrictions

## Existing Tests
- **src/orchestrator/__tests__/roles.test.ts**
  - 60 existing tests for prompts, verdicts, issue extraction
  - 56+ new tests specifically for tool enforcement (added in 82f94c5)
  - Tests cover: role configurations, allowed/disallowed tool sets, API completeness, role-specific constraints

## Existing Patterns in Codebase
1. **Role-based configuration** — ROLE_CONFIGS pattern used for model selection, budget, and now tool access
2. **Whitelist-based security** — Matches existing `permissionMode` approach
3. **Computed derived values** — `getDisallowedTools()` follows pattern of verdict/issue extraction helpers
4. **Comprehensive test coverage** — Each behavior tested with multiple assertions
5. **Documentation via comments** — Inline rationales explain why tools are allowed/disallowed

## Recommended Approach (If Extending)

If future work needs to extend tool enforcement:

1. **Adding new SDK tools**
   - Update `ALL_AGENT_TOOLS` in roles.ts (keep sorted)
   - Add test to `roles.test.ts` "matches known-complete SDK tool set"
   - Decide which roles get access (update ROLE_CONFIGS)
   - Add specific test for the new tool behavior

2. **Adding new agent roles** (if pipeline expands beyond 4)
   - Add to `AgentRole` type in types.ts
   - Create RoleConfig entry in roles.ts with allowedTools
   - Update `runPhase()` to handle new role type
   - Add tests to roles.test.ts

3. **Implementing tool enforcement in dispatcher.ts**
   - Currently dispatcher's `dispatchPlanStep()` hardcodes `permissionMode: "bypassPermissions"`
   - Could add similar role-based enforcement for plan step execution
   - Would need new role type or reuse existing ones with tailored tool sets

4. **Monitoring tool violations**
   - Currently SDK silently prevents disallowed tools
   - Could add logging in agent-worker.ts to track attempted tool use
   - Would help audit compliance with role restrictions

## Known Gaps/Limitations

1. **dispatcher.ts not updated** — Single `dispatchPlanStep()` still uses hardcoded permissions; could benefit from role-based enforcement
2. **No audit logging** — Agents cannot see why a tool was disallowed; only get SDK error
3. **AskUserQuestion** — Intentionally excluded but not explicitly tested as error case (only tested as "not in allowedTools")
4. **Runtime validation** — Tool enforcement happens at SDK level; no compile-time verification

## Potential Edge Cases to Watch
- **Developer spawns agents** — Developer can use `Agent` tool but spawned sub-agents will still inherit parent's tool restrictions (verify this behavior)
- **Report file conflicts** — Multiple roles might try to write same file if role config changes (mitigated by report file rotation in agent-worker.ts lines 407-423)
- **SDK tool list drift** — When SDK gains new tools, `ALL_AGENT_TOOLS` becomes stale; test catches this but requires manual update
