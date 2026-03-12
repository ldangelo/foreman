# Explorer Report: Integrate DCG (Destructive Command Guard) into foreman agent workers

## Summary

Foreman agent workers currently bypass all permission checks using `permissionMode: "bypassPermissions"` and `allowDangerouslySkipPermissions: true`. DCG (Destructive Command Guard) integration means implementing proper safeguards for destructive operations by:

1. Stopping the blanket bypass of permissions
2. Switching to a controlled permission mode (`default`, `dontAsk`, or `acceptEdits`)
3. Properly handling tool annotations (MCP tools marked with `destructive: true`)
4. Allowing explicit approval or denial of destructive operations based on the task context

## Relevant Files

### 1. **src/orchestrator/agent-worker.ts** (Main Worker Process)
- **Lines 133-156**: Single-agent query initialization with SDK options
  - Currently uses `permissionMode: "bypassPermissions"` and `allowDangerouslySkipPermissions: true`
  - These settings disable all permission prompts and safeguards

- **Lines 330-341**: Pipeline phase execution (`runPhase()` function)
  - Runs each phase (explorer, developer, qa, reviewer) as separate SDK queries
  - Currently bypasses all permissions for all phases indiscriminately
  - All phases use same permission mode regardless of destructive-ness

- **Lines 158-243**: Message handling for single-agent mode
  - Already handles rate limit errors (`error_max_budget_usd` on line 225)
  - Error handling logic can be extended for permission-related errors

### 2. **src/orchestrator/dispatcher.ts** (Task Dispatcher)
- **Lines 25-26**: Constant definition for plan step budget

- **Lines 149-160**: Agent spawning in `dispatch()` method
  - Spawns agent-worker process with config

- **Lines 330-341**: Plan step execution in `dispatchPlanStep()` method
  - Also uses `permissionMode: "bypassPermissions"`
  - Handles one-off planning steps outside pipeline phases

### 3. **Node SDK Type Definitions** (`node_modules/@anthropic-ai/claude-agent-sdk/sdk.d.ts`)
- **Lines 549-553**: MCP tool annotations
  - Tools can have `destructive?: boolean` annotation
  - Also supports `readOnly?: boolean` and `openWorld?: boolean`

- **Permission mode options**: `'default' | 'acceptEdits' | 'bypassPermissions' | 'plan' | 'dontAsk'`
  - `default`: Standard behavior, prompts for dangerous operations
  - `acceptEdits`: Auto-accept file edits
  - `bypassPermissions`: Skip all checks (current approach, requires `allowDangerouslySkipPermissions`)
  - `dontAsk`: Don't prompt, deny if not pre-approved
  - `plan`: Planning mode, no actual execution

- **MCP server status**: Tracks available tools and their annotations

### 4. **src/orchestrator/roles.ts** (Role Configuration)
- **Lines 13-46**: `RoleConfig` interface and `ROLE_CONFIGS` object
  - Defines configuration for each agent role (explorer, developer, qa, reviewer)
  - No current permission-related configuration
  - May need to add permission policies per role

### 5. **src/orchestrator/__tests__/agent-worker.test.ts** (Worker Tests)
- Basic tests for config file handling, logging
- No tests for permission modes or destructive operations
- Tests use invalid API keys to prevent actual SDK execution

### 6. **src/orchestrator/__tests__/agent-worker-team.test.ts** (Pipeline Tests)
- Tests for pipeline phase execution
- Should verify permission handling across phases

## Architecture & Patterns

### Current Permission Model
- **Blanket bypass**: All SDK queries use `bypassPermissions` mode
- **No discrimination**: All tools, all phases, all contexts use same approach
- **Intentional**: This is a deliberate trade-off to allow agents full autonomy

### Proposed DCG Integration Pattern
- **Role-based permissions**: Different permission modes per agent role:
  - **Explorer**: `default` or `dontAsk` (read-only operations only)
  - **Developer**: `default` or `dontAsk` with approval for destructive ops
  - **QA**: `acceptEdits` (mainly reviewing and testing)
  - **Reviewer**: `dontAsk` (read-only code review)

- **Destructive operation handling**:
  - Use permission mode that respects `destructive: true` annotations on MCP tools
  - Either prompt user (requires interactive session) or deny by default
  - Plan step queries (one-off planning) may have different rules

### SDK Query Options Structure
```typescript
options: {
  cwd: string;
  model: ModelSelection;
  permissionMode: PermissionMode;  // Currently always "bypassPermissions"
  allowDangerouslySkipPermissions?: boolean;  // Only used with bypassPermissions
  env: Record<string, string>;
  persistSession: boolean;
  maxBudgetUsd?: number;
}
```

## Dependencies

### What Uses Permission Settings
1. **agent-worker.ts**:
   - Imports `query` from SDK
   - Passes options with `permissionMode` to query calls
   - No current exports of permission configuration

2. **dispatcher.ts**:
   - Spawns agent-worker process
   - Also calls `query()` for plan steps with same permissions
   - Should align with agent-worker permissions

3. **roles.ts**:
   - Defines role configurations but not permission policies
   - Could be extended to include `permissionMode` per role

### SDK Dependencies
- `@anthropic-ai/claude-agent-sdk` version supports:
  - Tool annotations (destructive, readOnly, openWorld)
  - Multiple permission modes
  - Error handling for permission denials

## Existing Tests

### 1. **src/orchestrator/__tests__/agent-worker.test.ts**
- Tests config file handling
- Tests log directory creation
- No permission-related assertions
- Uses invalid API key to prevent actual SDK calls

### 2. **src/orchestrator/__tests__/agent-worker-team.test.ts**
- Tests pipeline phase orchestration
- Tests dev→qa retry logic
- Tests finalization and git operations
- **Gap**: No tests for permission enforcement

### 3. **src/orchestrator/__tests__/roles.test.ts**
- Tests role configuration structure
- Tests prompt templates
- **Gap**: No permission policy tests

## Recommended Approach

### Phase 1: Design Permission Policy
1. **Define per-role permission modes**:
   - Create mapping from role → permission mode
   - Consider whether each role should guard destructive operations
   - Document the rationale for each choice

2. **Plan error handling**:
   - What happens when a destructive operation is denied?
   - Should pipeline continue or fail?
   - How to log permission denials for audit trail

### Phase 2: Update Role Configuration
1. In `roles.ts`:
   - Extend `RoleConfig` interface to include `permissionMode: PermissionMode`
   - Update `ROLE_CONFIGS` with appropriate permission modes per role
   - Example:
     ```typescript
     export interface RoleConfig {
       role: AgentRole;
       model: ModelSelection;
       maxBudgetUsd: number;
       permissionMode: PermissionMode;  // ADD THIS
       reportFile: string;
     }
     ```

### Phase 3: Update Agent Worker Queries
1. In `agent-worker.ts`:
   - **Single-agent mode** (lines 133-156):
     - Change permission settings based on task context
     - Option A: Use `default` mode (interactive - not viable for detached process)
     - Option B: Use `dontAsk` mode (auto-deny destructive ops)
     - Option C: Keep bypass but add logging/audit trail

   - **Pipeline phases** (lines 330-341):
     - Replace hardcoded `permissionMode: "bypassPermissions"` with `roleConfig.permissionMode`
     - Remove `allowDangerouslySkipPermissions: true` when not needed

2. Error handling enhancements:
   - Add specific handlers for permission denial errors
   - Log when destructive operations are denied
   - Consider retry logic or phase failure handling

### Phase 4: Update Dispatcher Plan Steps
1. In `dispatcher.ts`:
   - Plan step queries should use controlled permission mode
   - Consider whether plan steps need same safeguards as pipeline phases

### Phase 5: Add Tests
1. In `__tests__/roles.test.ts`:
   - Verify each role has appropriate permission mode
   - Test that explorer has most restrictive, developer has appropriate level

2. In `__tests__/agent-worker.test.ts`:
   - Test that permission mode is correctly passed to SDK
   - Test behavior when destructive operation is denied

3. Consider adding integration test for permission enforcement (if feasible with SDK mock)

## Potential Pitfalls & Edge Cases

1. **Interactive vs Non-Interactive**:
   - Worker is detached process with no user interaction
   - Permission mode `default` will prompt user but no one to respond → hang
   - Solution: Use `dontAsk` or `acceptEdits`, not `default`

2. **Permission Denial vs Feature Limitation**:
   - When a destructive operation is denied, how should pipeline respond?
   - Is it a failure condition or expected behavior?
   - Error messages must clearly indicate permission denial vs actual failure

3. **MCP Tool Annotations**:
   - Not all destructive operations may have proper annotations
   - Some tools might not be from MCP sources (built-in SDK tools)
   - Built-in tools like `Write`, `Edit`, `Bash` may not have destructive annotations

4. **Phase-Specific Permissions**:
   - Explorer should be very restrictive (read-only)
   - Developer needs write access
   - Current design may need fine-grained tool-level permissions, not just mode

5. **Backwards Compatibility**:
   - Currently agents have full autonomy
   - Switching to guarded mode may cause legitimate operations to be blocked
   - May need transition period with logging of what would be blocked

6. **Plan Steps vs Pipeline Phases**:
   - Plan steps for decomposition/analysis have different safety requirements than dev phases
   - May need different permission policies

## Next Steps for Developer

1. **Decision**: Choose which permission mode aligns with project safety goals:
   - `bypassPermissions`: Current (unsafe but permissive)
   - `dontAsk`: Deny destructive by default (safest but restrictive)
   - `acceptEdits`: Auto-accept file edits but deny other destructive ops (balanced)

2. **Implementation Priority**:
   - Start with pipeline phases (most impact)
   - Then handle plan steps
   - Finally, add tests for permission enforcement

3. **Validation**:
   - Test with actual destructive operations (force delete, shell commands)
   - Verify denied operations don't break pipeline
   - Check error messages are clear

4. **Documentation**:
   - Update CLAUDE.md to explain DCG integration
   - Document which roles have which permissions
   - Explain how to handle permission denials
