# Developer Report: Refinery Agent

## Approach

The task was to complete the `RefineryAgent.runAgent()` method, which was previously a stub returning "agent logic not yet implemented". The implementation wires the existing Pi SDK infrastructure (`runWithPiSdk`) into the agent so it can:
1. Run in the branch worktree (where it can fix files directly)
2. Execute a fix/build/test loop guided by the task prompt
3. Escalate after exhausting fix budget (maxFixIterations)
4. Perform the actual merge via `VcsBackend.merge()` on success

Key design decisions:
- **Agent runs in the worktree**: the `worktreePath` is looked up from the run record via `ForemanStore.forProject()`, so the agent can edit files directly
- **Task prompt drives the loop**: `buildRefineryTaskPrompt()` creates the prompt instructing the agent to: verify build → fix failures → run tests → report
- **Fix tracking via Edit tool calls**: `result.toolBreakdown["Edit"]` is used as a proxy for fix iteration count — when ≥ maxFixIterations, escalate
- **`send_mail` tool for escalations**: wired via `createSendMailTool(mailClient, "refinery-agent")` using the existing `SqliteMailClient`
- **Merge via VcsBackend**: on success, `vcsBackend.merge()` is called (not gh pr merge), making the agent backend-agnostic

## Files Changed

- **`src/orchestrator/refinery-agent.ts`** — Complete rewrite of `runAgent()`:
  - Added imports: `ForemanStore`, `SqliteMailClient`, `createSendMailTool`, `runWithPiSdk`, `PiRunResult`, `MergeResult`
  - Replaced stub `runAgent()` with full implementation using Pi SDK agent session
  - Added `buildRefineryTaskPrompt()` helper to generate the fix/build/test loop prompt
  - Added `RefineryTaskPromptOptions` interface
  - Added `PrState` interface and `buildRefineryTaskPrompt()` function
  - Fixed template literal issues (template strings in template strings) by using array join instead
  - Fixed `getDefaultBranch` → `detectDefaultBranch` (VcsBackend interface)
  - Fixed `mergeResult === "conflict"` → `!mergeResult.success` (MergeResult type)
  - All string concatenation uses explicit `+` operators (no template literals with `${...}` interpolation)

## Tests Added/Modified

- **`src/orchestrator/__tests__/refinery-agent.test.ts`** — Updated `makeMockVcsBackend()`:
  - Changed `merge` mock from `vi.fn()` to `vi.fn().mockResolvedValue({ success: true })`
  - Changed `getDefaultBranch` → `detectDefaultBranch`
  - Added `push` mock for merge push verification
  - Added 3 new integration test stubs for runAgent behavior
  - All 11 tests pass

## Decisions & Trade-offs

1. **Fix iteration tracking via Edit tool count**: Simpler than a custom iteration counter, but could be imprecise if the agent uses Write instead of Edit. Trade-off accepted since Edit is the canonical fix tool.
2. **Array.join() for task prompt**: TypeScript template literals with embedded `${...}` expressions cause parse errors when the outer string is itself a template literal. Resolved by using array join with explicit string concatenation.
3. **Using worktreePath vs projectPath for merge**: The merge is called with `worktreePath` as the repo path since that's where the branch's git state lives. The push uses `projectPath` (main repo) since that's where the VCS backend was initialized.
4. **No fix iteration loop in agent code**: The task prompt tells the agent to iterate, but the agent itself controls the loop. This is intentional — the agent decides when to retry vs escalate, not a mechanical counter.

## Known Limitations

- **runAgent() is not unit-tested**: The full implementation requires a real Pi SDK session which is impractical to mock in unit tests. Integration tests would cover this.
- **`ForemanStore.forProject()` opens a new DB connection**: The store is opened/closed per entry, which is fine for low-volume queue processing but not ideal for high-throughput scenarios.
- **No handling of VcsBackend.merge() returning conflicts with file list**: When merge conflicts occur, we escalate immediately rather than attempting auto-resolution (which the legacy Refinery does via ConflictResolver).
- **Agent session runs synchronously**: No streaming of agent output to console — output goes to `logFile` only. For debugging, one might want to add `onText` callback support.
