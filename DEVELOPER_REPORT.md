# Developer Report: Gateway provider routing for model selection

## Approach

Addressed all issues from the previous review, focusing on the critical provider ID mismatch and the resume path missing provider propagation, plus the two warnings and two notes.

## Files Changed

- `src/orchestrator/provider-registry.ts` — Four fixes:
  1. **[CRITICAL fix]** `loadProvidersFromEnv` now converts underscores to hyphens in provider IDs (`.replace(/_/g, "-")`). `FOREMAN_PROVIDER_Z_AI_BASE_URL` now produces provider id `"z-ai"` matching the `RoleConfig.provider: "z-ai"` convention everywhere else in the codebase.
  2. **[WARNING fix]** `toJSON()` now returns `structuredClone(this.providers)` instead of `{ ...this.providers }` — a true deep clone that prevents callers from mutating internal registry state through shared `modelIdMap` references.
  3. **[NOTE fix]** `applyProviderEnv` now looks up config directly instead of instantiating a full `ProviderRegistry` on each call — eliminates unnecessary overhead when called per pipeline phase.
  4. Updated JSDoc comments to accurately document that underscores are converted to hyphens.

- `src/orchestrator/dispatcher.ts` — Two fixes:
  1. **[WARNING fix]** `resumeAgent` now passes `providers: this.providerRegistry.toJSON()` to `spawnWorkerProcess`, matching the `spawnAgent` path. Without this, resumed pipeline runs would silently fall back to direct Anthropic API for all phases.
  2. **[NOTE fix]** `selectProvider` changed from `public` to `protected` — reduces surface area; it's designed for subclass override, not external callers.

- `src/orchestrator/__tests__/provider-registry.test.ts` — Updated tests:
  1. Fixed three assertions that incorrectly expected `"z_ai"` (underscore); now correctly expect `"z-ai"` (hyphen) to match the new normalization.
  2. Added `"converts underscores to hyphens in provider ID"` test explicitly verifying the end-to-end fix.
  3. Added `"returns a deep clone — mutating returned modelIdMap does not affect registry"` test verifying `toJSON()` deep clone correctness.

## Tests Added/Modified

- `src/orchestrator/__tests__/provider-registry.test.ts`
  - Updated 3 existing assertions: `providers["z_ai"]` → `providers["z-ai"]`
  - **New test**: `loadProvidersFromEnv` — "converts underscores to hyphens in provider ID" (verifies `FOREMAN_PROVIDER_Z_AI_BASE_URL` → `"z-ai"`, `FOREMAN_PROVIDER_MY_GATEWAY_API_KEY_VAR` → `"my-gateway"`)
  - **New test**: `ProviderRegistry.toJSON` — "returns a deep clone" (mutates returned `modelIdMap`, verifies registry state unchanged)
  - All 35 tests pass.

## Decisions & Trade-offs

- **Underscore→hyphen in loadProvidersFromEnv**: This is a breaking change for any existing deployments that configured roles with `provider: "z_ai"` (underscore). However, all existing documentation and examples use hyphens, so the underscore form was never the intended API. The correct fix is in the loader, not in adding hyphen aliases everywhere.

- **applyProviderEnv inlined logic**: The function now duplicates the `getEnvOverrides` logic rather than delegating to `ProviderRegistry`. This is a deliberate trade-off: avoid the registry instantiation overhead at the cost of a small amount of duplication. Both code paths are tested independently.

- **selectProvider as protected**: This preserves the extension point for subclasses while removing it from the public API. Any existing code calling `dispatcher.selectProvider(task)` externally would break, but no such callers exist in the codebase.

## Known Limitations

- **[NOTE] Single-agent mode provider routing** (agent-worker.ts:136-158): The non-pipeline single-agent path still does not apply provider env overrides from `WorkerConfig.providers`. This was called out in the review as a note (not a blocker). Fixing it would require identifying which provider to use in that path — there's no per-phase `RoleConfig` in single-agent mode, so a separate mechanism would be needed. Deferred.
