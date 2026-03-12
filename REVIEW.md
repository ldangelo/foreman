# Code Review: Gateway provider routing for model selection

## Verdict: FAIL

## Summary

The implementation introduces a `ProviderRegistry` class that enables per-phase routing of SDK calls through different API gateway endpoints by injecting `ANTHROPIC_BASE_URL` and `ANTHROPIC_API_KEY` environment variables. The core design is sound and backward-compatible. However, there are two bugs that would cause provider routing to silently fail in practice: a provider ID mismatch between the env loader and the documented/expected ID format, and the `resumeAgent` path in `dispatcher.ts` not propagating `providers` to the worker process.

## Issues

- **[CRITICAL]** `src/orchestrator/provider-registry.ts:141` — Provider ID mismatch: `loadProvidersFromEnv` extracts IDs by lowercasing the raw env var segment, turning `FOREMAN_PROVIDER_Z_AI_BASE_URL` into `"z_ai"` (underscore). However, all documentation, `RoleConfig` JSDoc examples, and test fixtures consistently use `"z-ai"` (hyphen). When a user sets `FOREMAN_PROVIDER_Z_AI_BASE_URL` and configures a role with `provider: "z-ai"`, the registry lookup fails silently and routing never activates. The loader must convert underscores to hyphens (e.g., `baseUrlMatch[1].toLowerCase().replace(/_/g, "-")`) or the docs must consistently state that hyphens become underscores. The tests at lines 176/184/206 actually assert `"z_ai"`, confirming the mismatch is baked in and untested against the hyphenated form.

- **[WARNING]** `src/orchestrator/dispatcher.ts:574` — `resumeAgent` does not pass `providers` to `spawnWorkerProcess`. The `spawnAgent` path (line 539) correctly propagates `this.providerRegistry.toJSON()`, but the resume path omits it entirely. When a rate-limited pipeline run is resumed, provider routing will not be applied to any phase, silently falling back to the direct Anthropic API.

- **[WARNING]** `src/orchestrator/provider-registry.ts:112` — `toJSON()` returns a shallow copy (`{ ...this.providers }`). Each `ProviderConfig` value (including its `modelIdMap` object) is shared by reference. If a caller mutates a returned config's `modelIdMap`, the registry's internal state is corrupted. This matters because the returned object is JSON-serialised to a temp file and then read back in the worker, so in practice it won't be mutated at runtime — but the claim in the QA report that `toJSON()` "prevent[s] mutation of registry state" is inaccurate and could mislead future maintainers. A deep clone or `structuredClone` would be correct here.

- **[NOTE]** `src/orchestrator/agent-worker.ts:136-158` — Single-agent mode (non-pipeline path) does not apply provider env overrides. The `providers` field is on `WorkerConfig` and is available, but it is never used in the non-pipeline code path. The pipeline path (via `runPhase`) is handled correctly. If provider routing is ever needed for non-pipeline single-agent runs, this will need to be added.

- **[NOTE]** `src/orchestrator/provider-registry.ts:168-179` — `applyProviderEnv` constructs a fresh `ProviderRegistry` from the serialised `GatewayProviders` on every call. For the pipeline path this means a new registry is allocated for each of the four phases. It is not a correctness issue (the registry is cheap to construct) but it is unnecessary overhead; the function could look up the config directly without instantiating a class.

- **[NOTE]** `src/orchestrator/dispatcher.ts:462-474` — `selectProvider()` is a public stub that always returns `undefined`. Adding a public, uncalled method to a class increases surface area without purpose. Either remove it, or make it `protected` for subclassing, or wire it up to the task-level dispatch flow.

## Positive Notes

- The environment-variable-based approach for provider credentials (storing only the *name* of the env var, not the key itself) is the right security model and is well-documented in the module header.
- Backward compatibility is fully preserved: all existing ROLE_CONFIGS omit `provider`, and `applyProviderEnv` short-circuits cleanly when no provider is set.
- The 33 new tests in `provider-registry.test.ts` are comprehensive, covering happy paths, missing env vars, case-insensitivity, model ID mapping, and mutation safety.
- `resolvePhaseModel` in `agent-worker.ts` is a clean, well-placed helper that duplicates logic already on `ProviderRegistry.resolveModelId` — for pipeline phases the registry is unavailable, so this standalone function is justified.
- The `GatewayProviders` type threaded through `WorkerConfig` serialisation to the worker process is a clean design that avoids re-reading env vars in the worker.
