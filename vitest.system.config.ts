import { defineVitestLaneConfig } from "./vitest.shared";

export default defineVitestLaneConfig("system", {
  include: ["scripts/__tests__/**/*.test.ts"],
  fileParallelism: false,
  maxWorkers: 1,
});
