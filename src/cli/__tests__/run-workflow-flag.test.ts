/**
 * Tests for the `--workflow <name>` flag on `foreman run` and the retirement
 * of the dead `--skip-explore` / `--skip-review` flags.
 *
 * The skip flags never affected the YAML-driven pipeline (they were only
 * consumed by the legacy lead-agent prompt builder). They are kept as hidden,
 * deprecated no-ops for backwards compatibility; `--workflow quick` is the
 * YAML-first replacement.
 */
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { readFileSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

import { runCommand, validateWorkflowOverride } from "../commands/run.js";
import { runTaskCommand, skipFlagsDeprecationWarning } from "../commands/run-task.js";

function findOption(
  command: { options: ReadonlyArray<{ long?: string; hidden?: boolean }> },
  long: string,
) {
  return command.options.find((o) => o.long === long);
}

describe("foreman run --workflow flag", () => {
  it("exposes a visible --workflow <name> option", () => {
    const opt = findOption(runCommand, "--workflow");
    expect(opt).toBeDefined();
    expect(opt?.hidden ?? false).toBe(false);
  });

  it("still parses --skip-explore and --skip-review but hides them from help", () => {
    const skipExplore = findOption(runCommand, "--skip-explore");
    const skipReview = findOption(runCommand, "--skip-review");
    expect(skipExplore).toBeDefined();
    expect(skipReview).toBeDefined();
    expect(skipExplore?.hidden).toBe(true);
    expect(skipReview?.hidden).toBe(true);
  });

  it("does not show the deprecated skip flags in help output", () => {
    const help = runCommand.helpInformation();
    expect(help).toContain("--workflow");
    expect(help).not.toContain("--skip-explore");
    expect(help).not.toContain("--skip-review");
  });
});

describe("foreman run task deprecated skip flags", () => {
  it("still parses --skip-explore and --skip-review but hides them from help", () => {
    const skipExplore = findOption(runTaskCommand, "--skip-explore");
    const skipReview = findOption(runTaskCommand, "--skip-review");
    expect(skipExplore).toBeDefined();
    expect(skipReview).toBeDefined();
    expect(skipExplore?.hidden).toBe(true);
    expect(skipReview?.hidden).toBe(true);
  });
});

describe("skipFlagsDeprecationWarning", () => {
  it("returns null when no deprecated flag is set", () => {
    expect(skipFlagsDeprecationWarning({})).toBeNull();
    expect(skipFlagsDeprecationWarning({ skipExplore: false, skipReview: false })).toBeNull();
  });

  it("warns that the flags have no effect and suggests --workflow quick for `foreman run`", () => {
    const warning = skipFlagsDeprecationWarning({ skipExplore: true });
    expect(warning).toBeTruthy();
    expect(warning).toContain("--skip-explore");
    expect(warning).toContain("no effect");
    expect(warning).toContain("--workflow quick");
  });

  it("suggests passing `quick` as the workflow argument for `foreman run task`", () => {
    // `foreman run task <task-id> <workflow>` takes the workflow as a
    // positional argument — there is no --workflow flag on that subcommand.
    const warning = skipFlagsDeprecationWarning({ skipExplore: true }, "task");
    expect(warning).toBeTruthy();
    expect(warning).toContain("--skip-explore");
    expect(warning).toContain("no effect");
    expect(warning).not.toContain("--workflow quick");
    expect(warning).toContain("workflow argument");
  });

  it("mentions both flags when both are set", () => {
    const warning = skipFlagsDeprecationWarning({ skipExplore: true, skipReview: true });
    expect(warning).toContain("--skip-explore");
    expect(warning).toContain("--skip-review");
  });
});

describe("validateWorkflowOverride", () => {
  let foremanHome: string;

  beforeEach(() => {
    foremanHome = join(tmpdir(), `foreman-wf-flag-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    mkdirSync(foremanHome, { recursive: true });
    process.env["FOREMAN_HOME"] = foremanHome;
  });

  afterEach(() => {
    rmSync(foremanHome, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("accepts a bundled workflow name", () => {
    const result = validateWorkflowOverride("quick", foremanHome);
    expect(result.ok).toBe(true);
  });

  it("accepts a project workflow name", () => {
    mkdirSync(join(foremanHome, ".foreman", "workflows"), { recursive: true });
    writeFileSync(join(foremanHome, ".foreman", "workflows", "local.yaml"), "name: local\nphases:\n  - name: finalize\n    builtin: true\n");
    const result = validateWorkflowOverride("local", foremanHome);
    expect(result.ok).toBe(true);
  });

  it("rejects an unknown workflow with a list of available workflows", () => {
    const result = validateWorkflowOverride("nope-not-a-workflow", foremanHome);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.message).toContain("nope-not-a-workflow");
      expect(result.message).toContain("default");
      expect(result.message).toContain("quick");
    }
  });
});

describe("dispatcher workflow override wiring", () => {
  const dispatcherSource = readFileSync(
    fileURLToPath(new URL("../../orchestrator/dispatcher.ts", import.meta.url)),
    "utf8",
  );

  it("passes the CLI workflow override into resolveWorkflowName", () => {
    expect(dispatcherSource).toContain("opts?.workflow,");
  });

  it("no longer threads the dead skip flags into worker configs", () => {
    expect(dispatcherSource).not.toContain("skipExplore");
    expect(dispatcherSource).not.toContain("skipReview");
  });
});
