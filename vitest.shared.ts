import type { UserConfig } from "vitest/config";
import { defineConfig } from "vitest/config";

const baseExclude = [
  ".omx/**",
  "**/node_modules/**",
  "**/dist/**",
  "**/.omx/**",
  "**/.foreman-worktrees/**",
  "**/.claude/worktrees/**",
];

const baseTestConfig: NonNullable<UserConfig["test"]> = {
  exclude: baseExclude,
  testTimeout: 30_000,
  hookTimeout: 30_000,
  env: {
    GIT_TERMINAL_PROMPT: "0",
    GIT_ASKPASS: "true",
    // Skip runtime asset preflight checks (prompts/workflows) in test mode.
    // Tests that need to verify preflight behavior set FOREMAN_RUNTIME_MODE=normal
    // in their beforeEach and restore it in afterEach.
    FOREMAN_RUNTIME_MODE: "test",
    // Most legacy command tests predate Elixir as the runtime default and exercise
    // Node/Postgres/local-store paths. Default test lanes to node; Elixir parity
    // tests explicitly unset or override FOREMAN_BACKEND to verify cutover guards.
    FOREMAN_BACKEND: "node",
  },
};

export function defineVitestLaneConfig(
  lane: string,
  overrides: NonNullable<UserConfig["test"]>,
) {
  return defineConfig({
    test: {
      ...baseTestConfig,
      ...overrides,
      name: lane,
      exclude: [...baseExclude, ...(overrides.exclude ?? [])],
      env: {
        ...baseTestConfig.env,
        ...(overrides.env ?? {}),
      },
    },
  });
}

