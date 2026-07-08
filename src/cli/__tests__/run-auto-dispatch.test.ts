import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const RUN_SRC = fileURLToPath(new URL("../commands/run.ts", import.meta.url));

describe("auto-dispatch after Elixir cutover", () => {
  const source = readFileSync(RUN_SRC, "utf8");

  it("normal runtime delegates dispatch policy to the Elixir scheduler", () => {
    expect(source).toContain('Error: these foreman run dispatch-shaping options were removed after the Elixir backend cutover');
    expect(source).toContain("await client.schedulerTick();");
    expect(source).toContain("return;");
  });

  it("checks runtime assets before ticking the Elixir scheduler", () => {
    const preflightIndex = source.indexOf("const assetIssues = collectRuntimeAssetIssues(projectPath, projectCfg);");
    const schedulerIndex = source.indexOf("await client.schedulerTick();");

    expect(preflightIndex).toBeGreaterThan(-1);
    expect(schedulerIndex).toBeGreaterThan(preflightIndex);
  });

  it("legacy local test-runtime path still wires watch autoDispatch for compatibility tests", () => {
    expect(source).toContain("const makeAutoDispatchFn = (!dryRun && watch && enableAutoDispatch)");
    expect(source).toContain("autoDispatch: makeAutoDispatchFn");
  });
});
