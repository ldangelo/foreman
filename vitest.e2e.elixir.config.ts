import { defineVitestLaneConfig } from "./vitest.shared";

export default defineVitestLaneConfig("e2e-elixir", {
  include: ["src/integration/__tests__/**/*elixir*.e2e.test.ts"],
  fileParallelism: false,
  maxWorkers: 1,
  testTimeout: 120_000,
  hookTimeout: 120_000,
  env: {
    FOREMAN_BACKEND: "elixir",
  },
});
