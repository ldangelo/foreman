# Developer Report: Gateway provider routing for model selection

## Approach

Implemented gateway provider routing by adding a `ProviderRegistry` class that manages per-provider configurations and injects provider-specific environment variables (`ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`) into SDK query calls. This approach works because the Claude Agent SDK reads these standard environment variables to configure its API endpoint and authentication — no SDK changes required.

Key design decisions:
- **Environment variable injection**: Providers are routed by overriding `ANTHROPIC_BASE_URL` and `ANTHROPIC_API_KEY` in the env passed to `query()`. This is the only supported mechanism since the SDK's `Options` type has no explicit `baseUrl` or `provider` field.
- **Configuration via env vars**: Provider configs are loaded from `FOREMAN_PROVIDER_{ID}_BASE_URL` and `FOREMAN_PROVIDER_{ID}_API_KEY_VAR` environment variables. API keys are never stored directly — only the _name_ of the env var holding the key.
- **Per-phase routing**: Providers are configured at the `RoleConfig` level (`roles.ts`), so each pipeline phase (explorer, developer, qa, reviewer) can use a different provider.
- **Model ID mapping**: Some providers (e.g., OpenRouter) use different model identifiers. A `modelIdMap` field in `ProviderConfig` handles this.
- **Backwards compatible**: `provider` is optional on `RoleConfig`; existing configs with no provider use the direct Anthropic API unchanged.
- **Providers propagated through WorkerConfig**: The serialized provider config is passed from `Dispatcher` through the worker JSON config to `agent-worker.ts`, so the detached worker process has full provider info.

## Files Changed

- `src/orchestrator/types.ts` — Added `ProviderConfig` interface and `GatewayProviders` type alias. `ProviderConfig` describes a gateway provider with optional `baseUrl`, `apiKeyEnvVar`, and `modelIdMap` fields.

- `src/orchestrator/roles.ts` — Added optional `provider?: string` field to `RoleConfig` interface. Existing role configs unchanged (no default provider = direct API).

- `src/orchestrator/provider-registry.ts` — **New file.** `ProviderRegistry` class with `getEnvOverrides()`, `resolveModelId()`, `hasProvider()`, `listProviders()`, and `toJSON()`. Also exports `loadProvidersFromEnv()` (loads from env vars) and `applyProviderEnv()` (convenience merge helper).

- `src/orchestrator/agent-worker.ts` — Three changes:
  1. Added `providers?: GatewayProviders` to `WorkerConfig` interface
  2. Imported `applyProviderEnv` from `provider-registry.ts`
  3. Updated `runPhase()` to apply provider env overrides and resolve model IDs before calling `query()`; log line now includes provider label when set

- `src/orchestrator/dispatcher.ts` — Four changes:
  1. Added `ProviderRegistry` import and `GatewayProviders` type import
  2. Added `providerRegistry: ProviderRegistry` field to `Dispatcher`, loaded in constructor (accepts optional `providers?: GatewayProviders` override for testing)
  3. Added `selectProvider()` method (returns `undefined` by default; hook for future task-level routing)
  4. Added `getProviders()` accessor method
  5. Updated `spawnAgent()` to pass `providers: this.providerRegistry.toJSON()` in `WorkerConfig`
  6. Added `providers?: GatewayProviders` to the local `WorkerConfig` interface

## Tests Added/Modified

- `src/orchestrator/__tests__/provider-registry.test.ts` — **New file.** 33 tests covering:
  - `ProviderRegistry` constructor (explicit config, empty env)
  - `hasProvider()` — existence checks, case-insensitivity
  - `listProviders()` — correct enumeration
  - `getEnvOverrides()` — baseUrl, apiKeyEnvVar, both combined, missing env var, unknown provider, case-insensitivity
  - `resolveModelId()` — no provider, no map, with map, unmapped model, unknown provider
  - `toJSON()` — returns copy not reference
  - `loadProvidersFromEnv()` — BASE_URL, API_KEY_VAR, both, multiple providers, lowercase normalization, empty values ignored
  - `applyProviderEnv()` — undefined provider/providers pass-through, merging, precedence, immutability
  - Integration: round-trip through `toJSON()`, OpenRouter model ID mapping pattern

## Decisions & Trade-offs

1. **Env-var injection over SDK `baseUrl`**: The SDK's `Options` type has no `baseUrl` or `provider` field. Environment variables are the only supported way to configure the endpoint. This is actually more flexible — it works with any proxy that accepts standard Anthropic API calls.

2. **`FOREMAN_PROVIDER_{ID}_API_KEY_VAR` vs direct key storage**: Storing the _name_ of the env var (not the value) avoids embedding API keys in WorkerConfig JSON files. The actual key is read at query time from the environment.

3. **Provider ID normalization to lowercase**: Provider IDs from env vars (uppercase `Z_AI`) and from `RoleConfig.provider` (camelCase `z-ai`) are both normalized to lowercase, making matching case-insensitive.

4. **`selectProvider()` stub on Dispatcher**: Added as an extension point for future task-level provider overrides (e.g., routing `refactor` tasks through a different provider). Currently returns `undefined` (no task-level routing).

5. **`resolvePhaseModel()` in agent-worker**: Kept as a private helper in `agent-worker.ts` rather than using `ProviderRegistry.resolveModelId()` directly, to keep it a simple standalone function without instantiating a registry just for model resolution.

## Known Limitations

- **No health checking**: The Explorer report mentions provider health checking. This is deferred — there's no connectivity check before routing a phase to a provider. If a provider is misconfigured, the phase will fail with an SDK error.
- **No task-level provider selection**: `selectProvider()` always returns `undefined`. Task-level routing (e.g., "route refactor tasks through z.ai") is not yet implemented.
- **Model ID maps not loadable from env**: `modelIdMap` must be provided programmatically (via `Dispatcher` constructor). There's no env var syntax for it. This is acceptable since model mapping is a code-time concern.
- **Provider IDs in RoleConfig must be manually set**: There's no automatic assignment of providers to roles. Operators must modify `ROLE_CONFIGS` in `roles.ts` to enable per-phase routing.
