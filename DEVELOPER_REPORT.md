# Developer Report: Integrate DCG (Destructive Command Guard) into foreman agent workers

## Approach

Replaced the blanket `permissionMode: "bypassPermissions"` + `allowDangerouslySkipPermissions: true` pattern throughout agent workers with role-appropriate permission modes. The core change is:

- **Before**: All SDK query calls used `bypassPermissions` — skipping all safety checks
- **After**: All SDK query calls use `acceptEdits` — auto-accepting file edits (needed for report/source writes) while guarding against truly destructive operations (arbitrary shell commands, rm -rf, etc.)

The permission mode is now part of each role's configuration in `ROLE_CONFIGS`, making it easy to tighten or differentiate per-role as requirements evolve.

Key design decision: `acceptEdits` was chosen over `dontAsk` because:
1. All pipeline roles need to write files (EXPLORER_REPORT.md, DEVELOPER_REPORT.md, QA_REPORT.md, REVIEW.md, and source/test files)
2. `dontAsk` might block file writes that require prompting, breaking the pipeline
3. Workers run as detached non-interactive processes — `default` mode would hang on prompts
4. `acceptEdits` specifically allows file edits while still guarding destructive non-edit tool calls

## Files Changed

- **src/orchestrator/roles.ts** — Added `permissionMode: PermissionMode` field to `RoleConfig` interface. Imported `PermissionMode` type from the SDK. Set `"acceptEdits"` for all four pipeline roles (explorer, developer, qa, reviewer) with inline comments explaining the rationale.

- **src/orchestrator/agent-worker.ts** — Updated `runPhase()` to use `roleConfig.permissionMode` from `ROLE_CONFIGS` instead of the hardcoded `"bypassPermissions"`. Removed `allowDangerouslySkipPermissions: true` (only valid/needed for `bypassPermissions` mode). Updated single-agent mode queries to use `"acceptEdits"` instead of `"bypassPermissions"`.

- **src/orchestrator/dispatcher.ts** — Updated `dispatchPlanStep()` SDK query to use `"acceptEdits"` instead of `"bypassPermissions"`. Removed `allowDangerouslySkipPermissions: true`.

## Tests Added/Modified

- **src/orchestrator/__tests__/roles.test.ts** — Added a new `"DCG (Destructive Command Guard) permission modes"` describe block with 7 tests:
  1. All roles have a `permissionMode` configured
  2. No role uses `bypassPermissions` (enforces the DCG contract)
  3. All roles use non-interactive modes (safe for detached workers — rejects `default`)
  4. Explorer uses `acceptEdits` specifically
  5. Developer uses `acceptEdits` specifically
  6. QA uses `acceptEdits` specifically
  7. Reviewer uses `acceptEdits` specifically
  8. All `permissionMode` values are valid SDK `PermissionMode` literals

All 31 tests in `roles.test.ts` pass.

## Decisions & Trade-offs

**`acceptEdits` for all roles vs role-differentiated modes**:
- The EXPLORER_REPORT suggested more differentiated modes (reviewer → `dontAsk`)
- However, all roles write report files, so `dontAsk` risks breaking the pipeline if it blocks `Write` tool calls
- Using `acceptEdits` universally is the safe baseline; individual roles can be tightened later once behavior under `dontAsk` for file writes is verified

**Single-agent mode also updated**:
- Single-agent mode (non-pipeline, user-initiated runs) was also changed from `bypassPermissions` to `acceptEdits`
- These workers are also detached and non-interactive, so the same rationale applies

**`allowDangerouslySkipPermissions` removed**:
- This flag is only meaningful with `bypassPermissions` mode
- Removing it makes the intent clear and avoids confusion

## Known Limitations

- `acceptEdits` auto-accepts ALL file edits. An agent that tries to write to `/etc/passwd` or overwrite critical files would not be blocked at the permission level — this is enforced by the OS file permissions instead.
- MCP tools with `destructive: true` annotations will be handled differently than before — they will no longer be automatically approved. Any MCP tool in the pipeline with `destructive: true` may now be denied/blocked. This is intentional but may surface unexpected pipeline failures if any integrated MCP tools have that annotation.
- Plan steps (`dispatchPlanStep`) now use `acceptEdits` — if any plan step previously relied on destructive non-edit operations, those would now be denied.
