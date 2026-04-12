import { defineVitestLaneConfig } from "./vitest.shared";

export default defineVitestLaneConfig("ci", {
  include: ["src/**/*.test.ts"],
  exclude: [
    "src/integration/__tests__/**/*e2e*.test.ts",
    "src/integration/__tests__/**/*full-run*.test.ts",
  ],
});

