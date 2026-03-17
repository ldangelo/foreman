/**
 * TRD-NF-007-TEST: Verify ESM import compliance.
 *
 * All relative imports in src/ must use .js extensions per project convention.
 * (TypeScript ESM requires .js extensions at import time even for .ts source.)
 */

import { describe, it, expect } from "vitest";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

describe("TRD-NF-007: ESM import compliance — all relative imports use .js", () => {
  it("no relative imports are missing .js extension in src/", () => {
    const root = resolve(import.meta.dirname, "../../../..");

    // Pattern: from ".<something>" that does NOT end in .js, .json, .css, or similar
    // Excludes: node: builtin imports, package imports (no leading dot)
    let output = "";
    try {
      output = execFileSync(
        "grep",
        [
          "-rn",
          "--include=*.ts",
          // Match: from "./<something>" or from "../<something>" NOT ending in .js/.json
          'from "\\.\\.\\?/',
          "src/",
        ],
        { cwd: root, stdio: "pipe" },
      ).toString();
    } catch {
      // grep exits 1 when no matches — that's the pass case
      output = "";
    }

    // Filter to only lines that are missing .js extension
    const violations = output
      .split("\n")
      .filter((line) => line.trim())
      .filter((line) => {
        // Extract the import path
        const match = line.match(/from "(\.\.?\/.+?)"/);
        if (!match) return false;
        const importPath = match[1];
        // It's a violation if it lacks a known extension
        return !importPath.endsWith(".js") &&
          !importPath.endsWith(".json") &&
          !importPath.endsWith(".css") &&
          !importPath.endsWith(".md");
      })
      // Skip test fixtures and .d.ts files
      .filter((line) => !line.includes(".d.ts") && !line.includes("__fixtures__"));

    if (violations.length > 0) {
      const sample = violations.slice(0, 5).join("\n");
      expect.fail(`Found ${violations.length} relative imports missing .js extension:\n${sample}`);
    }

    expect(violations).toHaveLength(0);
  });
});
