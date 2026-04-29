import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { findStalePrompts, loadPrompt } from "../prompt-loader.js";

describe("prompt loader", () => {
  const tempDirs: string[] = [];

  function makeForemanHome(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-prompt-loader-"));
    tempDirs.push(dir);
    mkdirSync(join(dir, "prompts", "default"), { recursive: true });
    process.env["FOREMAN_HOME"] = dir;
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
    delete process.env["FOREMAN_HOME"];
  });

  it("falls back to the global default workflow prompt when a workflow-specific prompt is missing", () => {
    const foremanHome = makeForemanHome();
    writeFileSync(
      join(foremanHome, "prompts", "default", "finalize.md"),
      "default finalize for {{seedId}}",
      "utf8",
    );

    const loaded = loadPrompt("finalize", { seedId: "bd-123" }, "custom", "/ignored/project");
    expect(loaded).toContain("default finalize for bd-123");
  });

  it("prefers workflow-specific prompts over the default fallback", () => {
    const foremanHome = makeForemanHome();
    mkdirSync(join(foremanHome, "prompts", "custom"), { recursive: true });
    writeFileSync(
      join(foremanHome, "prompts", "default", "developer.md"),
      "default developer",
      "utf8",
    );
    writeFileSync(
      join(foremanHome, "prompts", "custom", "developer.md"),
      "custom developer",
      "utf8",
    );

    const loaded = loadPrompt("developer", {}, "custom", "/ignored/project");
    expect(loaded).toBe("custom developer");
  });

  it("prefers project-local workflow prompts over global foreman home prompts", () => {
    const foremanHome = makeForemanHome();
    mkdirSync(join(foremanHome, "prompts", "epic"), { recursive: true });
    writeFileSync(
      join(foremanHome, "prompts", "epic", "developer.md"),
      "global developer",
      "utf8",
    );

    const projectRoot = mkdtempSync(join(tmpdir(), "foreman-project-prompts-"));
    tempDirs.push(projectRoot);
    mkdirSync(join(projectRoot, ".foreman", "prompts", "epic"), { recursive: true });
    writeFileSync(
      join(projectRoot, ".foreman", "prompts", "epic", "developer.md"),
      "local developer",
      "utf8",
    );

    const loaded = loadPrompt("developer", {}, "epic", projectRoot);
    expect(loaded).toBe("local developer");
  });

  it("flags stale global default prompts that are missing critical markers", () => {
    const foremanHome = makeForemanHome();
    writeFileSync(
      join(foremanHome, "prompts", "default", "developer.md"),
      "# Developer Agent\n## Pre-flight: Check EXPLORER_REPORT.md",
      "utf8",
    );

    const stale = findStalePrompts("/ignored/project");
    expect(stale).toContain("default/developer.md");
  });

  it("does not flag prompts that preserve explorer-plan markers", () => {
    const foremanHome = makeForemanHome();
    writeFileSync(
      join(foremanHome, "prompts", "default", "developer.md"),
      "# Developer Agent\nRead EXPLORER_REPORT.md\nImplementation Plan",
      "utf8",
    );
    writeFileSync(
      join(foremanHome, "prompts", "default", "explorer.md"),
      "# Explorer Agent\n## Implementation Plan\n### Likely Edit Files",
      "utf8",
    );

    const stale = findStalePrompts("/ignored/project");
    expect(stale).not.toContain("default/developer.md");
    expect(stale).not.toContain("default/explorer.md");
  });
});
