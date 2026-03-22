/**
 * TRD-NF-006-TEST: Verify TypeScript strict mode compilation.
 *
 * npx tsc --noEmit must pass with zero errors.
 * This test verifies TypeScript type constraints at the unit level.
 */

import { describe, it, expect } from "vitest";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

describe("TRD-NF-006: TypeScript strict mode compliance", () => {
  // tsc --noEmit can take 30–50s on loaded machines; allow 90s headroom
  it("npx tsc --noEmit exits with code 0", () => {
    const root = resolve(import.meta.dirname, "../../..");
    let exitCode = 0;
    let stderr = "";
    try {
      const npx = execFileSync("which", ["npx"], { encoding: "utf-8" }).trim();
      execFileSync(npx, ["tsc", "--noEmit"], { cwd: root, stdio: "pipe", timeout: 90_000 });
    } catch (err: any) {
      exitCode = err.status ?? 1;
      stderr = err.stderr?.toString() ?? "";
    }
    if (exitCode !== 0) {
      expect.fail(`tsc --noEmit failed (exit ${exitCode}):\n${stderr}`);
    }
    expect(exitCode).toBe(0);
  }, 90_000);
});
