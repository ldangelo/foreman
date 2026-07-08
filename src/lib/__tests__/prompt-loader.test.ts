import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { findStalePrompts, getBundledPromptContent, getBundledPromptPath, loadPrompt, REQUIRED_PHASES, expandCommandPlaceholders, CommandExpansionError } from "../prompt-loader.js";

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
      "default finalize for {{taskId}}",
      "utf8",
    );

    const loaded = loadPrompt("finalize", { taskId: "bd-123" }, "custom", "/ignored/project");
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


  it("tracks fix-issue prompts as workflow-scoped required prompts", () => {
    expect(REQUIRED_PHASES.task).toContain("fix-issue");
    expect(REQUIRED_PHASES.bug).toContain("fix-issue");
    expect(REQUIRED_PHASES.chore).toContain("fix-issue");
  });

  it("bundles workflow-specific fix-issue prompts", () => {
    expect(getBundledPromptPath("task", "fix-issue")).toContain(join("task", "fix-issue.md"));
    expect(getBundledPromptPath("bug", "fix-issue")).toContain(join("bug", "fix-issue.md"));
    expect(getBundledPromptPath("chore", "fix-issue")).toContain(join("chore", "fix-issue.md"));
  });

  it("requires and bundles the shared documentation prompt", () => {
    expect(REQUIRED_PHASES.default).toContain("documentation");
    expect(REQUIRED_PHASES.smoke).toContain("documentation");
    expect(getBundledPromptPath("default", "documentation")).toContain(join("default", "documentation.md"));
    expect(getBundledPromptContent("default", "documentation")).toContain("DOCUMENTATION_REPORT.md");
    expect(getBundledPromptContent("default", "documentation")).toContain("Do not write `DOCUMENTATION_REPORT.md` at the worktree root");
  });

  it("default explorer prompt directs lightweight discovery without mentioning Graphify", () => {
    const content = getBundledPromptContent("default", "explorer");

    expect(content).toContain("`Grep`");
    expect(content).toContain("`Glob`");
    expect(content).toContain("`Read`");
    expect(content).not.toMatch(/graphify/i);
  });

  it("fix-issue prompts invoke ensemble and preserve the developer artifact contract", () => {
    for (const workflow of ["task", "bug", "chore"] as const) {
      const content = getBundledPromptContent(workflow, "fix-issue");
      expect(content?.startsWith("/ensemble:fix-issue {{taskTitle}} {{taskDescription}}")).toBe(true);
      expect(content).toContain("DEVELOPER_REPORT.md");
    }
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

  it("flags stale global documentation prompts that write the report at the worktree root", () => {
    const foremanHome = makeForemanHome();
    writeFileSync(
      join(foremanHome, "prompts", "default", "documentation.md"),
      "# Documentation Agent\nWrite DOCUMENTATION_REPORT.md in the worktree root after updating docs.",
      "utf8",
    );

    const stale = findStalePrompts("/ignored/project");
    expect(stale).toContain("default/documentation.md");
  });

  it("does not flag current global documentation prompts that use the report directory artifact", () => {
    const foremanHome = makeForemanHome();
    writeFileSync(
      join(foremanHome, "prompts", "default", "documentation.md"),
      "# Documentation Agent\nWrite the phase artifact exactly at `{{reportDir}}/DOCUMENTATION_REPORT.md`.\nDo not write `DOCUMENTATION_REPORT.md` at the worktree root.",
      "utf8",
    );

    const stale = findStalePrompts("/ignored/project");
    expect(stale).not.toContain("default/documentation.md");
  });

  it("does not flag prompts that preserve explorer-plan markers", () => {
    const foremanHome = makeForemanHome();
    writeFileSync(
      join(foremanHome, "prompts", "default", "developer.md"),
      "# Developer Agent\nRead EXPLORER_REPORT.md\n## Developer Handoff",
      "utf8",
    );
    writeFileSync(
      join(foremanHome, "prompts", "default", "explorer.md"),
      "# Explorer Agent\n## Developer Handoff\n### Edit First",
      "utf8",
    );

    const stale = findStalePrompts("/ignored/project");
    expect(stale).not.toContain("default/developer.md");
    expect(stale).not.toContain("default/explorer.md");
  });
});

describe("expandCommandPlaceholders", () => {
  it("replaces !`echo hello` with command output", () => {
    const template = "Output: !`echo hello`";
    const result = expandCommandPlaceholders(template, tmpdir());
    // echo adds trailing newline; we verify the output contains expected text
    expect(result).toContain("Output: hello");
    expect(result.endsWith("\n")).toBe(true);
  });

  it("replaces !`echo` with output (handles newlines correctly)", () => {
    const template = "!`echo line1`\n!`echo line2`";
    const result = expandCommandPlaceholders(template, tmpdir());
    // Each echo command outputs a line with trailing newline
    expect(result).toContain("line1");
    expect(result).toContain("line2");
    expect(result.split("\n").filter(l => l === "line1" || l === "line2")).toHaveLength(2);
  });

  it("throws CommandExpansionError on non-zero exit code", () => {
    const template = "!`exit 1`";
    expect(() => expandCommandPlaceholders(template, tmpdir())).toThrow(CommandExpansionError);
  });

  it("throws CommandExpansionError with exit code 42", () => {
    const template = "!`bash -c 'exit 42'`";
    try {
      expandCommandPlaceholders(template, tmpdir());
      expect.fail("Expected CommandExpansionError to be thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(CommandExpansionError);
      expect((err as CommandExpansionError).exitCode).toBe(42);
      expect((err as CommandExpansionError).command).toBe("bash -c 'exit 42'");
    }
  });

  it("preserves non-matching text", () => {
    const template = "Hello !`echo world` - this is normal text";
    const result = expandCommandPlaceholders(template, tmpdir());
    // echo world outputs "world\n"; verify core content is present
    expect(result).toContain("Hello world");
    expect(result).toContain("this is normal text");
  });

  it("preserves text without any command placeholders", () => {
    const template = "No commands here, just text";
    const result = expandCommandPlaceholders(template, tmpdir());
    expect(result).toBe("No commands here, just text");
  });

  it("expands multiple commands in one template", () => {
    const template = "Date: !`date +%Y-%m-%d`\nTime: !`date +%H:%M:%S`";
    const result = expandCommandPlaceholders(template, tmpdir());
    expect(result).toContain("Date:");
    expect(result).toContain("Time:");
    // Each date command produces a timestamp-like output
    expect(result.split("\n").filter(l => l.length > 0)).toHaveLength(2);
  });

  it("handles command with no output (exit 0)", () => {
    const template = "!`true`";
    const result = expandCommandPlaceholders(template, tmpdir());
    expect(result).toBe("");
  });

  it("throws when command does not exist", () => {
    const template = "!`nonexistent-command-xyz`";
    expect(() => expandCommandPlaceholders(template, tmpdir())).toThrow(CommandExpansionError);
  });

  it("uses provided cwd for command execution", () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "expand-command-test-"));
    try {
      const template = "!`pwd`";
      const result = expandCommandPlaceholders(template, tmpDir);
      // pwd returns the cwd path - verify it matches (normalize for macOS symlinks)
      const normalizedResult = result.trim().replace(/^\/private/, "");
      const normalizedTmpDir = tmpDir.replace(/^\/private/, "");
      expect(normalizedResult).toBe(normalizedTmpDir);
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("throws with meaningful error message containing command and exit code", () => {
    const template = "!`bash -c 'echo error >&2; exit 1'`";
    try {
      expandCommandPlaceholders(template, tmpdir());
      expect.fail("Expected CommandExpansionError to be thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(CommandExpansionError);
      const expansionErr = err as CommandExpansionError;
      expect(expansionErr.command).toBe("bash -c 'echo error >&2; exit 1'");
      expect(expansionErr.exitCode).toBe(1);
      expect(expansionErr.message).toContain("bash -c 'echo error >&2; exit 1'");
      expect(expansionErr.message).toContain("1");
    }
  });
});
