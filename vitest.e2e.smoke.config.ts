import { defineVitestLaneConfig } from "./vitest.shared";

export default defineVitestLaneConfig("e2e-smoke", {
  include: ["src/integration/__tests__/**/*e2e*.test.ts"],
  exclude: ["src/integration/__tests__/**/*full-run*.test.ts"],
  fileParallelism: false,
  maxWorkers: 1,
});

