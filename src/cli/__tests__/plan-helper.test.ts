import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { buildPipelineSteps, inferPrdHintPath } from "../commands/plan.js";

describe("plan helper functions", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-plan-helper-"));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("builds the full PRD -> TRD pipeline by default", () => {
    const steps = buildPipelineSteps("Build auth", "/repo/docs", undefined, false);

    expect(steps.map((step) => step.name)).toEqual([
      "Create PRD",
      "Refine PRD",
      "Create TRD",
      "Refine TRD",
    ]);
    expect(steps[2]?.input).toBe("/repo/docs/PRD.md");
  });

  it("skips PRD creation when starting from an existing PRD", () => {
    const steps = buildPipelineSteps("Build auth", "/repo/docs", "/repo/docs/PRD-existing.md", false);

    expect(steps.map((step) => step.name)).toEqual([
      "Create TRD",
      "Refine TRD",
    ]);
    expect(steps[0]?.input).toBe("/repo/docs/PRD-existing.md");
  });

  it("stops after PRD steps when prdOnly is enabled", () => {
    const steps = buildPipelineSteps("Build auth", "/repo/docs", undefined, true);

    expect(steps.map((step) => step.name)).toEqual([
      "Create PRD",
      "Refine PRD",
    ]);
  });

  it("can produce an empty pipeline when both fromPrd and prdOnly are set", () => {
    const steps = buildPipelineSteps("Build auth", "/repo/docs", "/repo/docs/PRD.md", true);

    expect(steps).toEqual([]);
  });

  it("prefers the newest sorted PRD markdown file for the sling hint", () => {
    const dir = makeTempDir();
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "PRD-001.md"), "old\n");
    writeFileSync(join(dir, "PRD-010.md"), "new\n");
    writeFileSync(join(dir, "TRD.md"), "ignore\n");

    expect(inferPrdHintPath(dir)).toBe(join(dir, "PRD-010.md"));
  });

  it("falls back to outputDir/PRD.md when no PRD files exist", () => {
    const dir = makeTempDir();
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "notes.txt"), "ignore\n");

    expect(inferPrdHintPath(dir)).toBe(join(dir, "PRD.md"));
  });

  it("returns the explicit fromPrd path without inspecting outputDir", () => {
    expect(inferPrdHintPath("/repo/docs", "/repo/custom/PRD.md")).toBe("/repo/custom/PRD.md");
  });
});
