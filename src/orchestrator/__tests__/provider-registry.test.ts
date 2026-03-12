import { describe, it, expect } from "vitest";
import { ProviderRegistry, loadProvidersFromEnv, applyProviderEnv } from "../provider-registry.js";
import type { GatewayProviders } from "../types.js";

// ── ProviderRegistry ──────────────────────────────────────────────────────

describe("ProviderRegistry", () => {
  describe("constructor", () => {
    it("accepts explicit provider config", () => {
      const providers: GatewayProviders = {
        "z-ai": { baseUrl: "https://api.z.ai/anthropic" },
      };
      const registry = new ProviderRegistry(providers);
      expect(registry.hasProvider("z-ai")).toBe(true);
    });

    it("defaults to empty registry when no config and no env vars", () => {
      // Pass empty env to avoid picking up real environment
      const registry = new ProviderRegistry(loadProvidersFromEnv({}));
      expect(registry.listProviders()).toHaveLength(0);
    });
  });

  describe("hasProvider", () => {
    it("returns true for configured provider", () => {
      const registry = new ProviderRegistry({ "openrouter": { baseUrl: "https://openrouter.ai/api/v1" } });
      expect(registry.hasProvider("openrouter")).toBe(true);
    });

    it("returns false for unknown provider", () => {
      const registry = new ProviderRegistry({});
      expect(registry.hasProvider("unknown-provider")).toBe(false);
    });

    it("is case-insensitive", () => {
      const registry = new ProviderRegistry({ "z-ai": { baseUrl: "https://api.z.ai/anthropic" } });
      expect(registry.hasProvider("Z-AI")).toBe(true);
      expect(registry.hasProvider("z-ai")).toBe(true);
    });
  });

  describe("listProviders", () => {
    it("returns all configured provider IDs", () => {
      const registry = new ProviderRegistry({
        "z-ai": { baseUrl: "https://api.z.ai" },
        "openrouter": { baseUrl: "https://openrouter.ai" },
      });
      expect(registry.listProviders()).toEqual(expect.arrayContaining(["z-ai", "openrouter"]));
      expect(registry.listProviders()).toHaveLength(2);
    });

    it("returns empty array when no providers", () => {
      const registry = new ProviderRegistry({});
      expect(registry.listProviders()).toHaveLength(0);
    });
  });

  describe("getEnvOverrides", () => {
    it("returns ANTHROPIC_BASE_URL when baseUrl is configured", () => {
      const registry = new ProviderRegistry({
        "z-ai": { baseUrl: "https://api.z.ai/anthropic" },
      });
      const overrides = registry.getEnvOverrides("z-ai");
      expect(overrides).toEqual({ ANTHROPIC_BASE_URL: "https://api.z.ai/anthropic" });
    });

    it("returns ANTHROPIC_API_KEY when apiKeyEnvVar is configured and env var is set", () => {
      const registry = new ProviderRegistry({
        "z-ai": { apiKeyEnvVar: "Z_AI_API_KEY" },
      });
      const overrides = registry.getEnvOverrides("z-ai", { Z_AI_API_KEY: "sk-zai-test-key" });
      expect(overrides).toEqual({ ANTHROPIC_API_KEY: "sk-zai-test-key" });
    });

    it("returns both ANTHROPIC_BASE_URL and ANTHROPIC_API_KEY when both configured", () => {
      const registry = new ProviderRegistry({
        "z-ai": {
          baseUrl: "https://api.z.ai/anthropic",
          apiKeyEnvVar: "Z_AI_API_KEY",
        },
      });
      const overrides = registry.getEnvOverrides("z-ai", { Z_AI_API_KEY: "sk-zai-test-key" });
      expect(overrides).toEqual({
        ANTHROPIC_BASE_URL: "https://api.z.ai/anthropic",
        ANTHROPIC_API_KEY: "sk-zai-test-key",
      });
    });

    it("omits ANTHROPIC_API_KEY when apiKeyEnvVar references a missing env var", () => {
      const registry = new ProviderRegistry({
        "z-ai": { apiKeyEnvVar: "MISSING_VAR" },
      });
      // Pass empty env — no key available
      const overrides = registry.getEnvOverrides("z-ai", {});
      expect(overrides).not.toHaveProperty("ANTHROPIC_API_KEY");
    });

    it("returns empty object for unknown provider", () => {
      const registry = new ProviderRegistry({});
      expect(registry.getEnvOverrides("nonexistent")).toEqual({});
    });

    it("is case-insensitive on provider ID", () => {
      const registry = new ProviderRegistry({
        "z-ai": { baseUrl: "https://api.z.ai/anthropic" },
      });
      expect(registry.getEnvOverrides("Z-AI")).toEqual({ ANTHROPIC_BASE_URL: "https://api.z.ai/anthropic" });
    });
  });

  describe("resolveModelId", () => {
    it("returns original model ID when provider is undefined", () => {
      const registry = new ProviderRegistry({});
      expect(registry.resolveModelId(undefined, "claude-sonnet-4-6")).toBe("claude-sonnet-4-6");
    });

    it("returns original model ID when provider has no modelIdMap", () => {
      const registry = new ProviderRegistry({
        "z-ai": { baseUrl: "https://api.z.ai" },
      });
      expect(registry.resolveModelId("z-ai", "claude-sonnet-4-6")).toBe("claude-sonnet-4-6");
    });

    it("maps model ID when provider has modelIdMap", () => {
      const registry = new ProviderRegistry({
        "openrouter": {
          baseUrl: "https://openrouter.ai/api/v1",
          modelIdMap: {
            "claude-sonnet-4-6": "anthropic/claude-sonnet-4-6",
            "claude-haiku-4-5-20251001": "anthropic/claude-haiku-4-5",
          },
        },
      });
      expect(registry.resolveModelId("openrouter", "claude-sonnet-4-6")).toBe("anthropic/claude-sonnet-4-6");
      expect(registry.resolveModelId("openrouter", "claude-haiku-4-5-20251001")).toBe("anthropic/claude-haiku-4-5");
    });

    it("returns original model ID when model not in map", () => {
      const registry = new ProviderRegistry({
        "openrouter": {
          modelIdMap: { "claude-opus-4-6": "anthropic/claude-opus-4-6" },
        },
      });
      // "claude-sonnet-4-6" not in the map — returns as-is
      expect(registry.resolveModelId("openrouter", "claude-sonnet-4-6")).toBe("claude-sonnet-4-6");
    });

    it("returns original model ID for unknown provider", () => {
      const registry = new ProviderRegistry({});
      expect(registry.resolveModelId("nonexistent", "claude-sonnet-4-6")).toBe("claude-sonnet-4-6");
    });
  });

  describe("toJSON", () => {
    it("returns a copy of the providers config", () => {
      const providers: GatewayProviders = {
        "z-ai": { baseUrl: "https://api.z.ai/anthropic" },
      };
      const registry = new ProviderRegistry(providers);
      const json = registry.toJSON();
      expect(json).toEqual(providers);
      // Verify it's a copy, not the same reference
      expect(json).not.toBe(providers);
    });

    it("returns a deep clone — mutating returned modelIdMap does not affect registry", () => {
      const providers: GatewayProviders = {
        "openrouter": {
          baseUrl: "https://openrouter.ai/api/v1",
          modelIdMap: { "claude-sonnet-4-6": "anthropic/claude-sonnet-4-6" },
        },
      };
      const registry = new ProviderRegistry(providers);
      const json = registry.toJSON();
      // Mutate the returned deep copy
      json["openrouter"]!.modelIdMap!["claude-sonnet-4-6"] = "MUTATED";
      // Registry's internal state must be unchanged
      expect(registry.resolveModelId("openrouter", "claude-sonnet-4-6")).toBe(
        "anthropic/claude-sonnet-4-6",
      );
    });
  });
});

// ── loadProvidersFromEnv ──────────────────────────────────────────────────

describe("loadProvidersFromEnv", () => {
  it("loads BASE_URL from FOREMAN_PROVIDER_{ID}_BASE_URL", () => {
    const env = {
      FOREMAN_PROVIDER_Z_AI_BASE_URL: "https://api.z.ai/anthropic",
    };
    const providers = loadProvidersFromEnv(env);
    expect(providers["z-ai"]?.baseUrl).toBe("https://api.z.ai/anthropic");
  });

  it("loads apiKeyEnvVar from FOREMAN_PROVIDER_{ID}_API_KEY_VAR", () => {
    const env = {
      FOREMAN_PROVIDER_Z_AI_API_KEY_VAR: "Z_AI_SECRET_KEY",
    };
    const providers = loadProvidersFromEnv(env);
    expect(providers["z-ai"]?.apiKeyEnvVar).toBe("Z_AI_SECRET_KEY");
  });

  it("loads both BASE_URL and API_KEY_VAR for the same provider", () => {
    const env = {
      FOREMAN_PROVIDER_OPENROUTER_BASE_URL: "https://openrouter.ai/api/v1",
      FOREMAN_PROVIDER_OPENROUTER_API_KEY_VAR: "OPENROUTER_API_KEY",
    };
    const providers = loadProvidersFromEnv(env);
    expect(providers["openrouter"]).toEqual({
      baseUrl: "https://openrouter.ai/api/v1",
      apiKeyEnvVar: "OPENROUTER_API_KEY",
    });
  });

  it("loads multiple providers from env", () => {
    const env = {
      FOREMAN_PROVIDER_Z_AI_BASE_URL: "https://api.z.ai/anthropic",
      FOREMAN_PROVIDER_OPENROUTER_BASE_URL: "https://openrouter.ai/api/v1",
    };
    const providers = loadProvidersFromEnv(env);
    expect(Object.keys(providers)).toHaveLength(2);
    expect(providers["z-ai"]).toBeDefined();
    expect(providers["openrouter"]).toBeDefined();
  });

  it("normalizes provider ID to lowercase", () => {
    const env = {
      FOREMAN_PROVIDER_MYGATEWAY_BASE_URL: "https://mygateway.example.com",
    };
    const providers = loadProvidersFromEnv(env);
    expect(providers["mygateway"]).toBeDefined();
    expect(providers["MYGATEWAY"]).toBeUndefined();
  });

  it("converts underscores to hyphens in provider ID", () => {
    // FOREMAN_PROVIDER_Z_AI_BASE_URL → provider "z-ai" (not "z_ai")
    // This ensures FOREMAN_PROVIDER_Z_AI_BASE_URL + role provider: "z-ai" match.
    const env = {
      FOREMAN_PROVIDER_Z_AI_BASE_URL: "https://api.z.ai/anthropic",
      FOREMAN_PROVIDER_MY_GATEWAY_API_KEY_VAR: "MY_GATEWAY_KEY",
    };
    const providers = loadProvidersFromEnv(env);
    expect(providers["z-ai"]).toBeDefined();
    expect(providers["z_ai"]).toBeUndefined();
    expect(providers["my-gateway"]).toBeDefined();
    expect(providers["my_gateway"]).toBeUndefined();
  });

  it("returns empty object when no provider env vars present", () => {
    const env = {
      SOME_OTHER_VAR: "value",
      ANTHROPIC_API_KEY: "sk-...",
    };
    const providers = loadProvidersFromEnv(env);
    expect(Object.keys(providers)).toHaveLength(0);
  });

  it("ignores env vars with empty values", () => {
    const env = {
      FOREMAN_PROVIDER_EMPTY_BASE_URL: "",
    };
    const providers = loadProvidersFromEnv(env);
    expect(Object.keys(providers)).toHaveLength(0);
  });
});

// ── applyProviderEnv ──────────────────────────────────────────────────────

describe("applyProviderEnv", () => {
  it("returns baseEnv unchanged when providerId is undefined", () => {
    const baseEnv = { ANTHROPIC_API_KEY: "sk-original" };
    const result = applyProviderEnv(undefined, baseEnv, { "z-ai": { baseUrl: "https://api.z.ai" } });
    expect(result).toEqual(baseEnv);
  });

  it("returns baseEnv unchanged when providers is undefined", () => {
    const baseEnv = { ANTHROPIC_API_KEY: "sk-original" };
    const result = applyProviderEnv("z-ai", baseEnv, undefined);
    expect(result).toEqual(baseEnv);
  });

  it("merges provider overrides into baseEnv", () => {
    const baseEnv = {
      PATH: "/usr/bin",
      ANTHROPIC_API_KEY: "sk-original",
    };
    const providers: GatewayProviders = {
      "z-ai": {
        baseUrl: "https://api.z.ai/anthropic",
        apiKeyEnvVar: "Z_AI_KEY",
      },
    };
    const result = applyProviderEnv("z-ai", { ...baseEnv, Z_AI_KEY: "sk-zai-key" }, providers);
    expect(result.ANTHROPIC_BASE_URL).toBe("https://api.z.ai/anthropic");
    expect(result.ANTHROPIC_API_KEY).toBe("sk-zai-key");
    expect(result.PATH).toBe("/usr/bin"); // base env preserved
  });

  it("provider overrides take precedence over baseEnv", () => {
    const baseEnv = {
      ANTHROPIC_API_KEY: "sk-original",
      Z_AI_KEY: "sk-zai-key",
    };
    const providers: GatewayProviders = {
      "z-ai": { apiKeyEnvVar: "Z_AI_KEY" },
    };
    const result = applyProviderEnv("z-ai", baseEnv, providers);
    expect(result.ANTHROPIC_API_KEY).toBe("sk-zai-key");
  });

  it("does not mutate baseEnv", () => {
    const baseEnv = { ANTHROPIC_API_KEY: "sk-original" };
    const providers: GatewayProviders = { "z-ai": { baseUrl: "https://api.z.ai" } };
    applyProviderEnv("z-ai", baseEnv, providers);
    expect(baseEnv.ANTHROPIC_API_KEY).toBe("sk-original");
    expect((baseEnv as Record<string, string>).ANTHROPIC_BASE_URL).toBeUndefined();
  });
});

// ── Integration: full provider routing flow ───────────────────────────────

describe("ProviderRegistry integration", () => {
  it("round-trips through toJSON and back", () => {
    const original: GatewayProviders = {
      "z-ai": {
        baseUrl: "https://api.z.ai/anthropic",
        apiKeyEnvVar: "Z_AI_API_KEY",
        modelIdMap: { "claude-sonnet-4-6": "claude-sonnet-4-6" },
      },
    };
    const registry1 = new ProviderRegistry(original);
    const registry2 = new ProviderRegistry(registry1.toJSON());

    expect(registry2.hasProvider("z-ai")).toBe(true);
    expect(registry2.getEnvOverrides("z-ai", { Z_AI_API_KEY: "test-key" })).toEqual({
      ANTHROPIC_BASE_URL: "https://api.z.ai/anthropic",
      ANTHROPIC_API_KEY: "test-key",
    });
  });

  it("supports OpenRouter model ID mapping pattern", () => {
    const registry = new ProviderRegistry({
      "openrouter": {
        baseUrl: "https://openrouter.ai/api/v1",
        apiKeyEnvVar: "OPENROUTER_API_KEY",
        modelIdMap: {
          "claude-opus-4-6": "anthropic/claude-opus-4-6",
          "claude-sonnet-4-6": "anthropic/claude-sonnet-4-6",
          "claude-haiku-4-5-20251001": "anthropic/claude-haiku-4-5",
        },
      },
    });

    expect(registry.resolveModelId("openrouter", "claude-opus-4-6")).toBe("anthropic/claude-opus-4-6");
    expect(registry.resolveModelId("openrouter", "claude-sonnet-4-6")).toBe("anthropic/claude-sonnet-4-6");
    expect(registry.resolveModelId("openrouter", "claude-haiku-4-5-20251001")).toBe("anthropic/claude-haiku-4-5");
    // Undefined provider falls through to direct
    expect(registry.resolveModelId(undefined, "claude-sonnet-4-6")).toBe("claude-sonnet-4-6");
  });
});
