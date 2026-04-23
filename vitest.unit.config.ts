import { defineVitestLaneConfig } from "./vitest.shared";

export default defineVitestLaneConfig("unit", {
  include: ["src/**/*.test.ts"],
  exclude: [
    "src/**/*-orig.test.ts",
    "src/integration/**",
    "src/**/__tests__/**/*integration*.test.ts",
    "src/**/__tests__/**/*e2e*.test.ts",
    "src/lib/vcs/__tests__/**/*.test.ts",
    "src/lib/__tests__/git*.test.ts",
    "src/cli/__tests__/commands.test.ts",
    "src/cli/__tests__/*-project-flag.test.ts",
    "src/orchestrator/__tests__/conflict-resolver-*.test.ts",
    "src/orchestrator/__tests__/finalize-ignored-files.test.ts",
  ],
});
