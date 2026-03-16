/**
 * TRD-NF-005-TEST: Coverage report validation.
 *
 * All new/modified files should have >= 80% unit test coverage.
 * This test verifies the key migrated modules have test files.
 *
 * Note: Actual coverage percentages require `npm run coverage` (vitest --coverage).
 * This file verifies that test files exist for the core migrated modules.
 */

import { describe, it, expect } from "vitest";
import { existsSync } from "node:fs";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "../../..");

function testFileExists(modulePath: string): boolean {
  const parts = modulePath.split("/");
  const filename = parts.pop()!;
  const dir = parts.join("/");
  const testPath = resolve(ROOT, dir, "__tests__", filename.replace(".ts", ".test.ts"));
  return existsSync(testPath);
}

describe("TRD-NF-005: key migrated modules have test coverage", () => {
  const coreModules = [
    "src/lib/beads-rust.ts",
    "src/lib/bv.ts",
    "src/lib/feature-flags.ts",
    // task-client.ts is interface-only; tested through consumers (beads-rust, reset, dispatcher)
    "src/orchestrator/monitor.ts",
    "src/orchestrator/dispatcher.ts",
    "src/orchestrator/task-backend-ops.ts",
  ];

  for (const mod of coreModules) {
    it(`test file exists for ${mod}`, () => {
      expect(testFileExists(mod)).toBe(true);
    });
  }

  it("cli command tests exist for run.ts", () => {
    const testPath = resolve(ROOT, "src/cli/__tests__/run-backend.test.ts");
    expect(existsSync(testPath)).toBe(true);
  });

  it("cli command tests exist for reset.ts", () => {
    const testPath = resolve(ROOT, "src/cli/__tests__/reset-br-backend.test.ts");
    expect(existsSync(testPath)).toBe(true);
  });

  it("sling command tests exist for TRD-021/TRD-022", () => {
    const dep = resolve(ROOT, "src/cli/__tests__/sling-sd-only-deprecation.test.ts");
    const def = resolve(ROOT, "src/cli/__tests__/sling-br-default.test.ts");
    expect(existsSync(dep)).toBe(true);
    expect(existsSync(def)).toBe(true);
  });
});
