import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { findStalePrompts, loadPrompt } from "../prompt-loader.js";

describe("prompt loader", () => {
  const tempDirs: string[] = [];

  function makeProject(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-prompt-loader-"));
    tempDirs.push(dir);
    mkdirSync(join(dir, ".foreman", "prompts", "default"), { recursive: true });
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("falls back to the project's default workflow prompt when a workflow-specific prompt is missing", () => {
    const projectRoot = makeProject();
    writeFileSync(
      join(projectRoot, ".foreman", "prompts", "default", "finalize.md"),
      "default finalize for {{seedId}}",
      "utf8",
    );

    const loaded = loadPrompt("finalize", { seedId: "bd-123" }, "custom", projectRoot);
    expect(loaded).toContain("default finalize for bd-123");
  });

  it("prefers workflow-specific prompts over the default fallback", () => {
    const projectRoot = makeProject();
    mkdirSync(join(projectRoot, ".foreman", "prompts", "custom"), { recursive: true });
    writeFileSync(
      join(projectRoot, ".foreman", "prompts", "default", "developer.md"),
      "default developer",
      "utf8",
    );
    writeFileSync(
      join(projectRoot, ".foreman", "prompts", "custom", "developer.md"),
      "custom developer",
      "utf8",
    );

    const loaded = loadPrompt("developer", {}, "custom", projectRoot);
    expect(loaded).toBe("custom developer");
  });

  it("flags stale project-local default prompts that are missing critical markers", () => {
    const projectRoot = makeProject();
    writeFileSync(
      join(projectRoot, ".foreman", "prompts", "default", "developer.md"),
      "# Developer Agent\n## Pre-flight: Check EXPLORER_REPORT.md",
      "utf8",
    );

    const stale = findStalePrompts(projectRoot);
    expect(stale).toContain("default/developer.md");
  });

  it("does not flag prompts that preserve explorer-plan markers", () => {
    const projectRoot = makeProject();
    writeFileSync(
      join(projectRoot, ".foreman", "prompts", "default", "developer.md"),
      "# Developer Agent\nRead EXPLORER_REPORT.md\nImplementation Plan",
      "utf8",
    );
    writeFileSync(
      join(projectRoot, ".foreman", "prompts", "default", "explorer.md"),
      "# Explorer Agent\n## Implementation Plan\n### Likely Edit Files",
      "utf8",
    );

    const stale = findStalePrompts(projectRoot);
    expect(stale).not.toContain("default/developer.md");
    expect(stale).not.toContain("default/explorer.md");
  });
});
