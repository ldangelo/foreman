/**
 * Pi extension build check behavior after Elixir cutover.
 *
 * Normal `foreman run` now ticks the Elixir scheduler and returns before the
 * legacy local dispatch path. The local Pi extension preflight remains guarded
 * so test/runtime invocations do not require a built extension package.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const RUN_SRC = fileURLToPath(new URL("../commands/run.ts", import.meta.url));

describe("Pi extensions build check in foreman run", () => {
  it("normal runtime delegates to Elixir scheduler before local Pi extension preflight", () => {
    const source = readFileSync(RUN_SRC, "utf8");
    const schedulerIndex = source.indexOf("const manager = new ElixirServerManager();");
    const returnIndex = source.indexOf("return;", schedulerIndex);
    const piCheckIndex = source.indexOf("// ── Pi Extensions check", returnIndex);

    expect(schedulerIndex).toBeGreaterThan(-1);
    expect(returnIndex).toBeGreaterThan(schedulerIndex);
    expect(piCheckIndex).toBeGreaterThan(returnIndex);
  });

  it("legacy local dispatch path skips the Pi extension check in test runtime and dry-run", () => {
    const source = readFileSync(RUN_SRC, "utf8");

    expect(source).toContain('if (!dryRun && runtimeMode !== "test" && isPiAvailable())');
    expect(source).toContain("packages/foreman-pi-extensions/dist/index.js");
    expect(source).toContain("Pi extensions package has not been built");
  });
});
