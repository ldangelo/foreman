import { defineVitestLaneConfig } from "./vitest.shared";

export default defineVitestLaneConfig("e2e-full-run", {
  include: ["src/integration/__tests__/**/*full-run*.test.ts"],
  fileParallelism: false,
  maxWorkers: 1,
});

