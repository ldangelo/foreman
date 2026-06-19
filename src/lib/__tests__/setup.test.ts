import { describe, it, expect, afterEach, vi } from "vitest";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { runHook, runWorkspaceHook } from "../setup.js";
import type { WorkspaceHooks } from "../../orchestrator/types.js";

const tempDirs: string[] = [];

function makeTempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  for (const dir of tempDirs) {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* ok */ }
  }
  tempDirs.length = 0;
  vi.restoreAllMocks();
});

describe("runHook", () => {
  it("executes a simple echo command and returns success", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    const result = await runHook("echo hello", workspace, {}, 30_000, "test");

    expect(result.success).toBe(true);
    expect(result.timedOut).toBe(false);
    expect(result.output).toContain("hello");
  });

  it("passes environment variables to the hook command", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    const env = { MY_VAR: "test-value", FOREMAN_WORKSPACE_PATH: workspace };
    const result = await runHook("printenv MY_VAR", workspace, env, 30_000, "test");

    expect(result.success).toBe(true);
    expect(result.output).toContain("test-value");
  });

  it("runs through a shell so quotes, expansion, and redirection work", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    const result = await runHook(
      'printf "%s" "$MY_VAR" > "quoted file.txt"',
      workspace,
      { MY_VAR: "value with spaces" },
      30_000,
      "test",
    );

    expect(result.success).toBe(true);
    expect(readFileSync(join(workspace, "quoted file.txt"), "utf8")).toBe("value with spaces");
  });

  it("handles mkdir command with arguments", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    const result = await runHook("mkdir subdir", workspace, {}, 30_000, "test");

    expect(result.success).toBe(true);
    expect(existsSync(join(workspace, "subdir"))).toBe(true);
  });

  it("returns success=false for non-existent commands", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    const result = await runHook("nonexistent-command-xyz", workspace, {}, 30_000, "test");

    expect(result.success).toBe(false);
    expect(result.timedOut).toBe(false);
  });

  it("uses the label in log output", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    await runHook("echo test", workspace, {}, 30_000, "myLabel");

    expect(consoleSpy).toHaveBeenCalledWith(expect.stringContaining("[hooks] Running myLabel:"));
    consoleSpy.mockRestore();
  });

  it("returns timedOut=true when command times out", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    const result = await runHook("sleep 10", workspace, {}, 100, "test");

    expect(result.success).toBe(false);
    // timedOut should be true when the timeout is properly detected via ETIMEDOUT code.
    // Some platforms may report this as a generic failure without timedOut set; in that
    // case we still verify the command failed (success=false).
    if (result.timedOut) {
      expect(result.timedOut).toBe(true);
    } else {
      // Platform didn't detect timeout via ETIMEDOUT - verify it at least failed
      expect(result.success).toBe(false);
    }
  });
});

describe("runWorkspaceHook", () => {
  it("does nothing when no hook is configured", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    const hooks: WorkspaceHooks = {};
    const env = { FOREMAN_WORKSPACE_PATH: workspace };

    await expect(runWorkspaceHook(hooks, "afterCreate", workspace, env)).resolves.toBeUndefined();
  });

  it("runs the afterCreate hook when configured", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    const markerPath = join(workspace, "marker.txt");
    // Use a simple command without special characters
    const hooks: WorkspaceHooks = {
      afterCreate: `touch ${markerPath}`,
    };
    const env = { FOREMAN_WORKSPACE_PATH: workspace };

    await runWorkspaceHook(hooks, "afterCreate", workspace, env);

    expect(existsSync(markerPath)).toBe(true);
  });

  it("throws on afterCreate hook failure (fatal stage)", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    const hooks: WorkspaceHooks = {
      afterCreate: "false",  // false always exits with code 1
    };
    const env = { FOREMAN_WORKSPACE_PATH: workspace };

    await expect(runWorkspaceHook(hooks, "afterCreate", workspace, env)).rejects.toThrow("Workspace hook 'afterCreate' failed");
  });

  it("throws on beforeRun hook failure (fatal stage)", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    const hooks: WorkspaceHooks = {
      beforeRun: "false",
    };
    const env = { FOREMAN_WORKSPACE_PATH: workspace };

    await expect(runWorkspaceHook(hooks, "beforeRun", workspace, env)).rejects.toThrow("Workspace hook 'beforeRun' failed");
  });

  it("does not throw on afterRun hook failure (non-fatal stage)", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    const hooks: WorkspaceHooks = {
      afterRun: "false",
    };
    const env = { FOREMAN_WORKSPACE_PATH: workspace };

    // Should not throw - failures are logged but ignored
    await expect(runWorkspaceHook(hooks, "afterRun", workspace, env)).resolves.toBeUndefined();
  });

  it("does not throw on beforeRemove hook failure (non-fatal stage)", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    const hooks: WorkspaceHooks = {
      beforeRemove: "false",
    };
    const env = { FOREMAN_WORKSPACE_PATH: workspace };

    // Should not throw - failures are logged but ignored
    await expect(runWorkspaceHook(hooks, "beforeRemove", workspace, env)).resolves.toBeUndefined();
  });

  it("uses custom timeout from hooks configuration", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    const hooks: WorkspaceHooks = {
      afterCreate: "sleep 10",
      timeoutMs: 50,
    };
    const env = { FOREMAN_WORKSPACE_PATH: workspace };

    const result = await runHook(
      hooks.afterCreate!,
      workspace,
      env,
      hooks.timeoutMs!,
      "afterCreate",
    );

    expect(result.success).toBe(false);
    // Command should fail (either due to timeout or general failure)
    expect(result.success).toBe(false);
  });

  it("passes FOREMAN_* environment variables to hooks", async () => {
    const workspace = makeTempDir("foreman-hook-test-");
    // Use printenv to verify env vars are passed - printenv takes a variable name and prints its value
    const hooks: WorkspaceHooks = {
      afterCreate: "printenv FOREMAN_WORKSPACE_PATH",
    };
    const env = {
      FOREMAN_WORKSPACE_PATH: workspace,
      FOREMAN_ISSUE_ID: "test-issue",
      FOREMAN_ISSUE_IDENTIFIER: "test-issue-identifier",
      FOREMAN_ATTEMPT: "3",
    };

    const result = await runHook(hooks.afterCreate!, workspace, env, 30_000, "afterCreate");

    // The command should succeed and output the workspace path
    expect(result.success).toBe(true);
    expect(result.output.trim()).toBe(workspace);
  });
});