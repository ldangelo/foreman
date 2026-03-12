/**
 * ProviderRegistry — gateway provider configuration for model routing.
 *
 * Supports routing different pipeline phases through different API endpoints
 * (e.g., z.ai, OpenRouter, self-hosted proxies) by injecting provider-specific
 * environment variables into SDK query() calls.
 *
 * ## How Provider Routing Works
 * The Claude Agent SDK reads ANTHROPIC_BASE_URL and ANTHROPIC_API_KEY from the
 * environment. By injecting these variables per-phase, we route different phases
 * through different providers without any SDK changes.
 *
 * ## Configuration via Environment Variables
 * ```
 * FOREMAN_PROVIDER_{ID}_BASE_URL      — API endpoint (e.g., https://api.z.ai/anthropic)
 * FOREMAN_PROVIDER_{ID}_API_KEY_VAR   — name of env var holding the provider API key
 * ```
 *
 * Provider IDs are normalized to lowercase with underscores converted to hyphens. Example:
 * ```
 * FOREMAN_PROVIDER_Z_AI_BASE_URL=https://api.z.ai/anthropic   → provider id "z-ai"
 * FOREMAN_PROVIDER_Z_AI_API_KEY_VAR=Z_AI_API_KEY
 * Z_AI_API_KEY=sk-zai-...
 * ```
 *
 * ## Role-Level Routing
 * Set `provider` in a RoleConfig to route that pipeline phase:
 * ```typescript
 * developer: { role: "developer", model: "claude-sonnet-4-6", provider: "z-ai", ... }
 * ```
 */

import type { GatewayProviders, ProviderConfig } from "./types.js";

// Re-export for consumers that import from this module
export type { GatewayProviders, ProviderConfig };

// ── ProviderRegistry ─────────────────────────────────────────────────────

export class ProviderRegistry {
  private providers: GatewayProviders;

  constructor(providers?: GatewayProviders) {
    this.providers = providers ?? loadProvidersFromEnv();
  }

  /**
   * Build environment variable overrides for a given provider ID.
   *
   * Returns an object with ANTHROPIC_BASE_URL and/or ANTHROPIC_API_KEY
   * set to the provider's values. Returns an empty object if the provider
   * is not configured or if no overrides apply.
   *
   * @param providerId  The provider ID (e.g., "z-ai"). Case-insensitive.
   * @param sourceEnv   Optional env to read apiKeyEnvVar values from (defaults to process.env).
   */
  getEnvOverrides(
    providerId: string,
    sourceEnv?: Record<string, string | undefined>,
  ): Record<string, string> {
    const config = this.providers[providerId.toLowerCase()];
    if (!config) return {};

    const env = sourceEnv ?? process.env;
    const overrides: Record<string, string> = {};

    if (config.baseUrl) {
      overrides.ANTHROPIC_BASE_URL = config.baseUrl;
    }

    if (config.apiKeyEnvVar) {
      const apiKey = env[config.apiKeyEnvVar];
      if (apiKey) {
        overrides.ANTHROPIC_API_KEY = apiKey;
      }
    }

    return overrides;
  }

  /**
   * Resolve the model ID for a given provider.
   *
   * Some providers use different model identifiers than Anthropic's canonical IDs
   * (e.g., OpenRouter uses "anthropic/claude-sonnet-4-6"). The modelIdMap in
   * ProviderConfig handles this mapping.
   *
   * Returns the original model ID if no mapping is configured for this provider/model.
   *
   * @param providerId  Provider ID, or undefined for direct Anthropic API.
   * @param modelId     Foreman canonical model ID (e.g., "claude-sonnet-4-6").
   */
  resolveModelId(providerId: string | undefined, modelId: string): string {
    if (!providerId) return modelId;
    const config = this.providers[providerId.toLowerCase()];
    if (!config?.modelIdMap) return modelId;
    return config.modelIdMap[modelId] ?? modelId;
  }

  /** Check if a provider ID is configured. */
  hasProvider(providerId: string): boolean {
    return providerId.toLowerCase() in this.providers;
  }

  /** List all configured provider IDs (lowercase). */
  listProviders(): string[] {
    return Object.keys(this.providers);
  }

  /** Serialize provider configs for inclusion in WorkerConfig (passed to agent-worker). */
  toJSON(): GatewayProviders {
    return structuredClone(this.providers);
  }
}

// ── Environment variable loader ──────────────────────────────────────────

/**
 * Load provider configurations from environment variables.
 *
 * Reads:
 *   FOREMAN_PROVIDER_{ID}_BASE_URL      → config[id].baseUrl
 *   FOREMAN_PROVIDER_{ID}_API_KEY_VAR   → config[id].apiKeyEnvVar
 *
 * Provider IDs are normalized to lowercase with underscores converted to hyphens.
 * Example: FOREMAN_PROVIDER_Z_AI_BASE_URL → provider id "z-ai"
 *
 * @param env   Environment to load from (defaults to process.env).
 */
export function loadProvidersFromEnv(
  env?: Record<string, string | undefined>,
): GatewayProviders {
  const source = env ?? process.env;
  const providers: GatewayProviders = {};

  for (const [key, value] of Object.entries(source)) {
    if (!value) continue;

    const baseUrlMatch = key.match(/^FOREMAN_PROVIDER_(.+)_BASE_URL$/);
    if (baseUrlMatch) {
      const id = baseUrlMatch[1].toLowerCase().replace(/_/g, "-");
      providers[id] = { ...providers[id], baseUrl: value };
      continue;
    }

    const apiKeyVarMatch = key.match(/^FOREMAN_PROVIDER_(.+)_API_KEY_VAR$/);
    if (apiKeyVarMatch) {
      const id = apiKeyVarMatch[1].toLowerCase().replace(/_/g, "-");
      providers[id] = { ...providers[id], apiKeyEnvVar: value };
    }
  }

  return providers;
}

// ── Utility: apply provider env to a query env ───────────────────────────

/**
 * Merge provider-specific env overrides into a base env record.
 *
 * Convenience wrapper for use in runPhase() and similar call sites.
 *
 * @param providerId   Provider ID from RoleConfig.provider (may be undefined).
 * @param baseEnv      The base env (from WorkerConfig.env).
 * @param providers    The GatewayProviders map (from WorkerConfig.providers).
 * @returns            Merged env with provider overrides applied.
 */
export function applyProviderEnv(
  providerId: string | undefined,
  baseEnv: Record<string, string | undefined>,
  providers: GatewayProviders | undefined,
): Record<string, string | undefined> {
  if (!providerId || !providers) return baseEnv;

  // Look up config directly without instantiating a full ProviderRegistry.
  const config = providers[providerId.toLowerCase()];
  if (!config) return baseEnv;

  const overrides: Record<string, string> = {};

  if (config.baseUrl) {
    overrides.ANTHROPIC_BASE_URL = config.baseUrl;
  }

  if (config.apiKeyEnvVar) {
    const apiKey = baseEnv[config.apiKeyEnvVar];
    if (apiKey) {
      overrides.ANTHROPIC_API_KEY = apiKey;
    }
  }

  return { ...baseEnv, ...overrides };
}
