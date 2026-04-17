import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { findMissingPrompts, loadPrompt } from "../prompt-loader.js";

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

    const loaded = loadPrompt("finalize", { seedId: "bd-123" }, "small", projectRoot);
    expect(loaded).toContain("default finalize for bd-123");
  });

  it("prefers workflow-specific prompts over the default fallback", () => {
    const projectRoot = makeProject();
    mkdirSync(join(projectRoot, ".foreman", "prompts", "small"), { recursive: true });
    writeFileSync(
      join(projectRoot, ".foreman", "prompts", "default", "developer.md"),
      "default developer",
      "utf8",
    );
    writeFileSync(
      join(projectRoot, ".foreman", "prompts", "small", "developer.md"),
      "small developer",
      "utf8",
    );

    const loaded = loadPrompt("developer", {}, "small", projectRoot);
    expect(loaded).toBe("small developer");
  });

  it("treats default fallback prompts as satisfying small/medium requirements", () => {
    const projectRoot = makeProject();
    writeFileSync(
      join(projectRoot, ".foreman", "prompts", "default", "developer.md"),
      "default developer",
      "utf8",
    );
    writeFileSync(
      join(projectRoot, ".foreman", "prompts", "default", "qa.md"),
      "default qa",
      "utf8",
    );
    writeFileSync(
      join(projectRoot, ".foreman", "prompts", "default", "finalize.md"),
      "default finalize",
      "utf8",
    );

    const missing = findMissingPrompts(projectRoot);
    expect(missing).not.toContain("small/developer.md");
    expect(missing).not.toContain("small/finalize.md");
    expect(missing).not.toContain("medium/developer.md");
    expect(missing).not.toContain("medium/qa.md");
    expect(missing).not.toContain("medium/finalize.md");
  });
});
