# Explorer Report: Gateway provider routing for model selection

## Summary

The foreman orchestrator currently routes all API calls through hardcoded Anthropic Claude models (Haiku, Sonnet, Opus) with keyword-based selection logic. To support gateway provider routing, we need to:

1. Add a provider configuration system to allow specifying custom API endpoints (z.ai, OpenRouter, self-hosted proxies)
2. Enable routing different pipeline phases through different providers
3. Support per-phase provider/model selection (e.g., explorer via direct API, developer via z.ai)
4. Add provider health checking to ensure routing targets are available

## Relevant Files

### 1. **src/orchestrator/types.ts** (lines 1-152)
- **Purpose**: Type definitions for the orchestrator
- **Current State**:
  - `ModelSelection` type: hardcoded union of 3 models (lines 5)
  - `DispatchedTask` interface: includes `model: ModelSelection` field (line 60)
  - `ResumedTask` interface: includes `model: ModelSelection` field (line 82)
- **Relevance**: Will need to add new types for `ProviderConfig`, `GatewayProvider`, `ModelProviderSelection`
- **Impact**: Changes here ripple to dispatcher, roles, and agent-worker

### 2. **src/orchestrator/roles.ts** (lines 13-46)
- **Purpose**: Agent role configurations for the specialization pipeline
- **Current State**:
  - `RoleConfig` interface: specifies `model: ModelSelection` (line 15)
  - `ROLE_CONFIGS` object hardcodes models per role:
    - explorer: claude-haiku-4-5-20251001
    - developer: claude-sonnet-4-6
    - qa: claude-sonnet-4-6
    - reviewer: claude-sonnet-4-6
- **Relevance**: Primary location for phase-level model/provider configuration
- **Impact**: Need to extend `RoleConfig` to include optional `provider: string` or `gatewayId: string`

### 3. **src/orchestrator/dispatcher.ts** (lines 434-448)
- **Purpose**: Task routing logic that selects model and spawns agents
- **Current State**:
  - `selectModel()` method uses keyword matching on task title/description
  - Returns hardcoded ModelSelection based on keywords (refactor→opus, typo→haiku, default→sonnet)
  - Passes selected model to `spawnAgent()` and `resumeAgent()`
- **Relevance**: Where provider selection logic would be applied
- **Impact**: Need to add `selectProvider()` method or extend `selectModel()` to return provider+model pair

### 4. **src/orchestrator/agent-worker.ts** (lines 310-399)
- **Purpose**: Standalone worker that runs SDK query() calls for each phase
- **Current State**:
  - Line 334: Passes `model: roleConfig.model` to SDK query options
  - Line 337: Also passes `maxBudgetUsd: roleConfig.maxBudgetUsd`
  - Uses role config to determine model per phase
- **Relevance**: Where provider configuration is passed to SDK
- **Impact**: Need to handle provider/gateway configuration when calling SDK
- **Note**: Line 225 already handles `error_max_budget_usd` error subtype

### 5. **src/lib/store.ts** (lines 1-100+)
- **Purpose**: SQLite database schema and data access for runs/projects
- **Current State**:
  - `Project` interface: basic project metadata (lines 9-16)
  - `Run` interface: tracking for individual task runs (lines 18-30)
  - No provider/gateway configuration storage
- **Relevance**: May need to add provider config storage at project level
- **Impact**: Minimal unless provider configs need to be persisted in the database

## Architecture & Patterns

### Current Model Selection Flow
```
Task (title, description)
  ↓
Dispatcher.selectModel()
  ↓
Keyword matching (refactor/complex → opus, typo/simple → haiku, default → sonnet)
  ↓
ModelSelection returned ("claude-opus-4-6" | "claude-sonnet-4-6" | "claude-haiku-4-5-20251001")
  ↓
spawnAgent() / resumeAgent() with model parameter
  ↓
agent-worker.ts passes model to SDK query() options
```

### Proposed Provider Routing Pattern
```
Project Configuration (foreman.json or similar)
  ├── providers:
  │   ├── direct: { endpoint: "https://api.anthropic.com", apiKey: "sk-..." }
  │   ├── z-ai: { endpoint: "https://api.z.ai/anthropic", apiKey: "..." }
  │   └── openrouter: { endpoint: "https://api.openrouter.ai", apiKey: "..." }
  └── routing:
      ├── explorer: { provider: "direct", model: "claude-haiku-4-5-20251001" }
      ├── developer: { provider: "z-ai", model: "claude-sonnet-4-6" }
      ├── qa: { provider: "openrouter", model: "claude-sonnet-4-6" }
      └── reviewer: { provider: "direct", model: "claude-sonnet-4-6" }

ROLE_CONFIGS with provider routing
  ↓
Dispatcher loads provider config
  ↓
For each phase: selectProvider() + selectModel()
  ↓
agent-worker passes both to SDK
```

### SDK Integration Points
- **query() function**: Accepts `model: string` parameter in options
- **Question**: Does SDK support custom provider/endpoint configuration?
  - Searched SDK types but didn't find explicit "provider" or "baseUrl" field
  - May need to use environment variables or custom headers
  - Claude Agent SDK may have provider support not visible in type stubs

## Dependencies

### What imports/uses model selection
1. **dispatcher.ts** → `selectModel()` is core entry point
   - Imports `SeedInfo` from types.ts
   - Returns `ModelSelection` to downstream consumers

2. **agent-worker.ts** → Uses model from ROLE_CONFIGS
   - Imports `ROLE_CONFIGS` from roles.ts
   - Passes `roleConfig.model` to SDK

3. **roles.ts** → Defines role→model mapping
   - Imports `ModelSelection` from types.ts
   - ROLE_CONFIGS is source of truth for role defaults

4. **types.ts** → Type definitions
   - `ModelSelection` union
   - `DispatchedTask`, `ResumedTask` use `model: ModelSelection`

### External dependencies
- **@anthropic-ai/claude-agent-sdk**: query() function with model option
- **better-sqlite3**: Potential storage for provider configs (via store.ts)

## Existing Tests

### 1. **src/orchestrator/__tests__/dispatcher.test.ts** (lines 17-64)
- Tests `Dispatcher.selectModel()` method exclusively
- Coverage:
  - Opus selection: refactor, architect, design, migrate keywords
  - Haiku selection: typo, config, rename, version keywords
  - Sonnet default: general implementation tasks
  - Case-insensitive matching
  - Description-based complexity detection
- **Status**: 9 test cases, all passing
- **Impact**: New provider routing tests should be added separately; existing model tests should still pass

### 2. **src/orchestrator/__tests__/roles.test.ts**
- Tests `ROLE_CONFIGS` structure and prompt generation
- May need updates if RoleConfig interface changes

### 3. **src/orchestrator/__tests__/agent-worker.test.ts**
- Tests worker initialization and config handling
- May need updates if provider config is passed through WorkerConfig

## Recommended Approach

### Phase 1: Define Provider Configuration Types
1. **Add to types.ts**:
   - `ProviderConfig` interface: endpoint, apiKey, healthCheckUrl, timeout
   - `GatewayProvider` type: union of provider names ("direct" | "z-ai" | "openrouter" | custom)
   - `ModelProviderSelection` interface: { provider: GatewayProvider, model: ModelSelection }
   - Update `ROLE_CONFIGS` to use ModelProviderSelection

2. **Extend RoleConfig**:
   - Add `provider?: GatewayProvider` field (optional, defaults to "direct")
   - Update ROLE_CONFIGS values to include provider selection

### Phase 2: Configuration System
1. **Decide configuration storage**:
   - Option A: `.foreman.json` in project root
   - Option B: Extend existing `.seeds/config.yaml`
   - Option C: Environment variables (FOREMAN_PROVIDERS_*)
   - Option D: Per-project in database (store.ts)

2. **Create provider loading logic**:
   - Load provider configs at dispatcher initialization
   - Validate provider endpoints (health check or basic connectivity)
   - Fallback to "direct" API if provider unavailable

3. **Add to Dispatcher**:
   - Constructor loads provider config
   - Add `selectProvider()` method or extend `selectModel()` to return { provider, model }

### Phase 3: Route Through SDK
1. **Update agent-worker.ts**:
   - Accept provider config in WorkerConfig
   - When calling SDK query(), pass:
     - `model: string` (e.g., "claude-sonnet-4-6" without provider prefix)
     - Potentially custom headers or baseUrl if SDK supports it

2. **Handle provider-specific model IDs**:
   - Some providers may use different model identifiers
   - May need mapping layer: { provider: "openrouter", model: "anthropic/claude-sonnet-4-6" }

### Phase 4: Testing & Validation
1. Add provider selection tests to dispatcher.test.ts
2. Add provider config loading tests
3. Add health check tests
4. Manual testing with different provider configurations

## Potential Pitfalls & Edge Cases

1. **Provider Authentication**:
   - API keys in config files — security risk
   - Solution: Load from environment variables, NOT config files
   - Encrypt keys if persisted in database

2. **Provider Model Name Differences**:
   - OpenRouter, z.ai may use different model identifiers
   - Solution: Add mapping layer in ProviderConfig
   - Example: `modelIdMap: { "claude-sonnet-4-6": "anthropic/claude-sonnet-4-6" }`

3. **Provider Downtime/Health**:
   - What happens if provider is unavailable?
   - Solution: Implement health check with fallback to direct API
   - Log provider failures for monitoring

4. **Cost Tracking**:
   - Different providers have different pricing
   - SDK returns cost_usd which may not reflect actual cost if routed through provider
   - Solution: Track provider metadata, adjust cost estimates if needed

5. **SDK Compatibility**:
   - Confirm SDK actually supports custom provider/endpoint configuration
   - The query() function's full Options type needs investigation
   - May need to use SDK extensions or environment variable approach

6. **Backwards Compatibility**:
   - Existing code expects `ModelSelection` (string union)
   - Changing to `ModelProviderSelection` object breaks compatibility
   - Solution: Keep ModelSelection but extend types to allow both, or version the interface

7. **Configuration Precedence**:
   - What if provider config exists but role config doesn't specify it?
   - Should roles inherit from task-level provider selection?
   - Solution: Clear precedence rules (task-level > role-level > project-level > direct)

## Next Steps for Developer

1. **Investigate SDK Provider Support**:
   - Read full Claude Agent SDK documentation
   - Check if query() has baseUrl, endpoint, or provider field
   - Look for environment variable support (ANTHROPIC_API_ENDPOINT, etc)

2. **Design Configuration File Format**:
   - Decide: `.foreman.json`, `foreman.config.ts`, or extend `.seeds/config.yaml`
   - Document provider credential handling (env vars, secrets management)

3. **Implement ProviderRegistry**:
   - Load and validate provider configs
   - Health check endpoints
   - Model ID mapping

4. **Update Route Passing**:
   - Modify Dispatcher to load and apply provider routing
   - Update WorkerConfig to include provider info
   - Pass provider config to SDK query options

5. **Write Comprehensive Tests**:
   - Provider config loading
   - Provider health checking
   - Provider selection logic
   - Fallback behavior when provider unavailable

6. **Documentation**:
   - Update README with provider configuration examples
   - Document supported providers
   - Add troubleshooting guide for provider connectivity issues
