import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import { isSafeWorkflowName, listWorkflows, workflowsCommand, workflowStub, validateWorkflows } from "../commands/workflows.js";

describe("workflows command helpers", () => {
  it("loads workflow management subcommands", () => {
    expect(workflowsCommand.name()).toBe("workflows");
    expect(workflowsCommand.commands.map((cmd) => cmd.name())).toEqual(["list", "show", "validate", "install", "create"]);
  });

  it("validates workflow names for generated files", () => {
    expect(isSafeWorkflowName("custom-flow_1.2")).toBe(true);
    expect(isSafeWorkflowName("../escape")).toBe(false);
    expect(isSafeWorkflowName("bad/name")).toBe(false);
    expect(isSafeWorkflowName("bad name")).toBe(false);
  });

  it("lists project workflow overrides before bundled workflows", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-workflows-list-"));
    mkdirSync(join(project, ".foreman", "workflows"), { recursive: true });
    writeFileSync(join(project, ".foreman", "workflows", "default.yml"), workflowStub("default"));

    const rows = listWorkflows(project);
    expect(rows.find((row) => row.workflow === "default")).toMatchObject({ source: "project" });
    expect(rows.some((row) => row.workflow === "quick")).toBe(true);
  });

  it("validates bundled workflows", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-workflows-validate-"));
    const oldHome = process.env.FOREMAN_HOME;
    process.env.FOREMAN_HOME = join(project, "foreman-home");
    try {
      expect(validateWorkflows(project)).toEqual({ ok: true, invalid: [] });
    } finally {
      if (oldHome === undefined) delete process.env.FOREMAN_HOME;
      else process.env.FOREMAN_HOME = oldHome;
    }
  });

  it("validates duplicate task_type declarations", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-workflows-duplicate-task-type-"));
    const oldHome = process.env.FOREMAN_HOME;
    process.env.FOREMAN_HOME = join(project, "foreman-home");
    mkdirSync(join(project, ".foreman", "workflows"), { recursive: true });
    writeFileSync(join(project, ".foreman", "workflows", "one.yaml"), "name: one\ntask_type: duplicate\nphases:\n  - name: developer\n    action: prompt-agent\n    prompt: developer.md\n");
    writeFileSync(join(project, ".foreman", "workflows", "two.yaml"), "name: two\ntask_type: duplicate\nphases:\n  - name: developer\n    action: prompt-agent\n    prompt: developer.md\n");
    try {
      const result = validateWorkflows(project);
      expect(result.ok).toBe(false);
      expect(result.invalid.some((line) => line.includes("task_type/duplicate"))).toBe(true);
    } finally {
      if (oldHome === undefined) delete process.env.FOREMAN_HOME;
      else process.env.FOREMAN_HOME = oldHome;
    }
  });

  it("validates shadowed global workflow files", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-workflows-invalid-global-"));
    const oldHome = process.env.FOREMAN_HOME;
    process.env.FOREMAN_HOME = join(project, "foreman-home");
    mkdirSync(join(project, ".foreman", "workflows"), { recursive: true });
    mkdirSync(join(project, "foreman-home", "workflows"), { recursive: true });
    writeFileSync(join(project, ".foreman", "workflows", "default.yaml"), workflowStub("default"));
    writeFileSync(join(project, "foreman-home", "workflows", "default.yaml"), "name: default\nphases: nope\n");
    try {
      const result = validateWorkflows(project);
      expect(result.ok).toBe(false);
      expect(result.invalid.some((line) => line.includes("global/default.yaml"))).toBe(true);
    } finally {
      if (oldHome === undefined) delete process.env.FOREMAN_HOME;
      else process.env.FOREMAN_HOME = oldHome;
    }
  });

  it("installs bundled workflows from the command", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-workflows-install-"));
    const cwd = process.cwd();
    process.chdir(project);
    try {
      await workflowsCommand.parseAsync(["node", "foreman", "install"]);
      expect(existsSync(join(project, ".foreman", "workflows", "default.yaml"))).toBe(true);
      expect(existsSync(join(project, ".foreman", "workflows", "tdd.yaml"))).toBe(true);
    } finally {
      process.chdir(cwd);
    }
  });

  it("creates a project workflow stub from the command", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-workflows-create-"));
    const cwd = process.cwd();
    process.chdir(project);
    try {
      await workflowsCommand.parseAsync(["node", "foreman", "create", "custom-flow"]);
      expect(existsSync(join(project, ".foreman", "workflows", "custom-flow.yaml"))).toBe(true);
    } finally {
      process.chdir(cwd);
    }
  });

  it("rejects unsafe workflow names from the create command", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-workflows-unsafe-create-"));
    const cwd = process.cwd();
    const previousExitCode = process.exitCode;
    process.exitCode = undefined;
    process.chdir(project);
    try {
      await workflowsCommand.parseAsync(["node", "foreman", "create", "../escape"]);
      expect(process.exitCode).toBe(1);
      expect(existsSync(join(project, ".foreman", "escape.yaml"))).toBe(false);
    } finally {
      process.chdir(cwd);
      process.exitCode = previousExitCode;
    }
  });

  it("creates a global workflow stub from the command", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-workflows-global-create-"));
    const cwd = process.cwd();
    const oldHome = process.env.FOREMAN_HOME;
    process.env.FOREMAN_HOME = join(project, "foreman-home");
    process.chdir(project);
    try {
      await workflowsCommand.parseAsync(["node", "foreman", "create", "global-flow", "--global"]);
      expect(existsSync(join(project, "foreman-home", "workflows", "global-flow.yaml"))).toBe(true);
    } finally {
      process.chdir(cwd);
      if (oldHome === undefined) delete process.env.FOREMAN_HOME;
      else process.env.FOREMAN_HOME = oldHome;
    }
  });
});
