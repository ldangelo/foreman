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

