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
    "src/orchestrator/task-ordering.ts",
    "src/lib/feature-flags.ts",
    // task-client.ts is interface-only; tested through consumers (reset, dispatcher)
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
    const testPath = resolve(ROOT, "src/cli/__tests__/run-runtime-mode.test.ts");
    expect(existsSync(testPath)).toBe(true);
  });

  it("sling command tests exist", () => {
    const command = resolve(ROOT, "src/cli/__tests__/sling-command-context.test.ts");
    const parser = resolve(ROOT, "src/cli/__tests__/sling.test.ts");
    expect(existsSync(command)).toBe(true);
    expect(existsSync(parser)).toBe(true);
  });
});
