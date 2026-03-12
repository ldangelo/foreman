# QA Report: Gateway provider routing for model selection

## Verdict: PASS

## Test Results
- Test suite (excluding pre-existing worktree env failures): **255 passed, 0 failed**
- Full suite (including pre-existing): 263 passed, 9 failed
- New tests added: 33 (`src/orchestrator/__tests__/provider-registry.test.ts`)

## Summary

The implementation adds gateway provider routing by introducing a `ProviderRegistry` class that injects `ANTHROPIC_BASE_URL` and `ANTHROPIC_API_KEY` environment variables into SDK query calls per pipeline phase. All 33 new tests pass, all existing tests that are runnable in this worktree environment pass, and no regressions were introduced.

## Pre-existing Failures (Not Caused by This PR)

All 9 failures are due to **tsx binary missing from the worktree's `node_modules/.bin/`**. The worktree was created as a git worktree and lacks `node_modules/.bin/tsx`, which is required by integration tests that spawn child processes. The identical failures occur on the `main` branch when run in this same worktree directory. The main project's test suite runs 250/250 when run from `/Users/ldangelo/Development/Fortium/foreman`.

Affected test files (all pre-existing, not regressions):
- `src/orchestrator/__tests__/agent-worker.test.ts` — 2 failed (tsx spawn fails)
- `src/orchestrator/__tests__/detached-spawn.test.ts` — 2 failed (tsx spawn fails)
- `src/cli/__tests__/commands.test.ts` — 4 failed (tsx/foreman CLI spawn fails)
- `src/orchestrator/__tests__/worker-spawn.test.ts` — 1 failed (`tsx binary exists` assertion)

## Issues Found

None. The implementation is correct and backward-compatible.

### Correctness Verified:
1. **`types.ts`**: `ProviderConfig` and `GatewayProviders` types are well-defined
2. **`provider-registry.ts`**: `ProviderRegistry`, `loadProvidersFromEnv()`, and `applyProviderEnv()` all work correctly per 33 tests
3. **`roles.ts`**: `provider?: string` field added to `RoleConfig`; existing ROLE_CONFIGS unchanged — all 23 role tests pass
4. **`dispatcher.ts`**: `ProviderRegistry` instantiated in constructor; `providers` passed to `WorkerConfig`; `selectProvider()` stub added — all 11 dispatcher tests pass
5. **`agent-worker.ts`**: `applyProviderEnv()` applied before `query()` call; `resolvePhaseModel()` resolves provider model IDs; `providers` field added to `WorkerConfig` — logic correct per code review

### Key Design Validation:
- Provider env injection is backward-compatible: when no `provider` is set on a `RoleConfig`, `applyProviderEnv()` returns `baseEnv` unchanged
- Provider IDs normalized to lowercase throughout (both env loading and lookup)
- API keys never stored in config — only the _name_ of the env var holding the key
- `toJSON()` returns a shallow copy to prevent mutation of registry state

## Files Modified

None — no fixes needed. All failures were pre-existing environment issues.

## Files Reviewed (Developer Added)

- `src/orchestrator/provider-registry.ts` — new file, implementation correct
- `src/orchestrator/__tests__/provider-registry.test.ts` — new file, 33 tests, all pass
- `src/orchestrator/types.ts` — `ProviderConfig`, `GatewayProviders` added
- `src/orchestrator/roles.ts` — `provider?: string` added to `RoleConfig`
- `src/orchestrator/dispatcher.ts` — `ProviderRegistry` integrated, `providers` propagated to worker
- `src/orchestrator/agent-worker.ts` — provider env overrides and model ID resolution in `runPhase()`
