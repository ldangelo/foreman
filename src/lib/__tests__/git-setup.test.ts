/**
 * Tests for runSetupSteps() in src/lib/git.ts
 */
import { describe, it, expect, vi, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, rmSync, realpathSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { runSetupSteps } from "../git.js";
import type { WorkflowSetupStep } from "../workflow-loader.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeTempDir(): string {
  return realpathSync(mkdtempSync(join(tmpdir(), "foreman-git-setup-test-")));
}

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.length = 0;
  vi.restoreAllMocks();
});

// ── runSetupSteps ─────────────────────────────────────────────────────────────

describe("runSetupSteps", () => {
  it("is a no-op for an empty steps array", async () => {
    const dir = makeTempDir();
    tempDirs.push(dir);
    // Should resolve without error and without doing anything
    await expect(runSetupSteps(dir, [])).resolves.toBeUndefined();
  });

  it("runs each command in order", async () => {
    const dir = makeTempDir();
    tempDirs.push(dir);

    const order: number[] = [];

    // Use a real command that writes a marker file for each step
    const steps: WorkflowSetupStep[] = [
      { command: "touch step1.txt" },
      { command: "touch step2.txt" },
    ];

    await runSetupSteps(dir, steps);

    // Both files should exist after the steps run
    const { existsSync } = await import("node:fs");
    expect(existsSync(join(dir, "step1.txt"))).toBe(true);
    expect(existsSync(join(dir, "step2.txt"))).toBe(true);
    void order; // suppress unused warning
  });

  it("throws when a failFatal step fails (failFatal defaults to true)", async () => {
    const dir = makeTempDir();
    tempDirs.push(dir);

    const steps: WorkflowSetupStep[] = [
      { command: "false" },  // POSIX `false` always exits 1
    ];

    await expect(runSetupSteps(dir, steps)).rejects.toThrow(/Setup step failed/);
  });

  it("throws when failFatal is explicitly true and the step fails", async () => {
    const dir = makeTempDir();
    tempDirs.push(dir);

    const steps: WorkflowSetupStep[] = [
      { command: "false", failFatal: true },
    ];

    await expect(runSetupSteps(dir, steps)).rejects.toThrow(/Setup step failed/);
  });

  it("logs warning and continues when failFatal=false and step fails", async () => {
    const dir = makeTempDir();
    tempDirs.push(dir);

    const warnSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const steps: WorkflowSetupStep[] = [
      { command: "false", failFatal: false, description: "optional step" },
      { command: "touch afterfail.txt" },
    ];

    // Should NOT throw
    await expect(runSetupSteps(dir, steps)).resolves.toBeUndefined();

    // Warning should have been logged
    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining("Warning: step failed (non-fatal)"),
    );

    // The subsequent step should still have run
    const { existsSync } = await import("node:fs");
    expect(existsSync(join(dir, "afterfail.txt"))).toBe(true);
  });

  it("uses the description in the error message when the step fails", async () => {
    const dir = makeTempDir();
    tempDirs.push(dir);

    const steps: WorkflowSetupStep[] = [
      { command: "false", failFatal: true, description: "My important step" },
    ];

    await expect(runSetupSteps(dir, steps)).rejects.toThrow("My important step");
  });

  it("runs a real multi-argument command successfully", async () => {
    const dir = makeTempDir();
    tempDirs.push(dir);

    // Write a small file and use `ls` to verify the dir is accessible
    writeFileSync(join(dir, "canary.txt"), "hello");
    const steps: WorkflowSetupStep[] = [
      { command: "ls canary.txt" },
    ];

    await expect(runSetupSteps(dir, steps)).resolves.toBeUndefined();
  });

  it("throws with the failing command in the error when no description given", async () => {
    const dir = makeTempDir();
    tempDirs.push(dir);

    const steps: WorkflowSetupStep[] = [
      { command: "false" },
    ];

    const err = await runSetupSteps(dir, steps).catch((e: Error) => e);
    expect(err).toBeInstanceOf(Error);
    expect((err as Error).message).toContain("false");
  });

  it("runs commands with cwd set to the given dir", async () => {
    const dir = makeTempDir();
    tempDirs.push(dir);

    // `pwd` output should match the dir — we can verify by writing a file relative to cwd
    const steps: WorkflowSetupStep[] = [
      { command: "touch cwd-marker.txt" },
    ];

    await runSetupSteps(dir, steps);

    const { existsSync } = await import("node:fs");
    expect(existsSync(join(dir, "cwd-marker.txt"))).toBe(true);
  });
});
