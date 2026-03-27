/**
 * Tests for JujutsuBackend.
 *
 * These tests verify the JujutsuBackend's interface compliance and
 * the getFinalizeCommands() output (which doesn't require jj to be installed).
 *
 * Tests that require the `jj` CLI are skipped when jj is not installed.
 */

import { describe, it, expect } from "vitest";
import { execFileSync } from "node:child_process";
import { JujutsuBackend } from "../jujutsu-backend.js";

// ── Check if jj is available ──────────────────────────────────────────────────

function isJjAvailable(): boolean {
  try {
    execFileSync("jj", ["--version"], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

const JJ_AVAILABLE = isJjAvailable();

// ── Constructor ───────────────────────────────────────────────────────────────

describe("JujutsuBackend constructor", () => {
  it("sets name to 'jujutsu'", () => {
    const b = new JujutsuBackend('/tmp');
    expect(b.name).toBe('jujutsu');
  });

  it("stores projectPath", () => {
    const b = new JujutsuBackend('/custom/path');
    expect(b.projectPath).toBe('/custom/path');
  });
});

// ── stageAll (no-op) ──────────────────────────────────────────────────────────

describe("JujutsuBackend.stageAll", () => {
  it("is a no-op and does not throw", async () => {
    const b = new JujutsuBackend('/tmp');
    await expect(b.stageAll('/tmp')).resolves.toBeUndefined();
  });
});

// ── getFinalizeCommands ───────────────────────────────────────────────────────

describe("JujutsuBackend.getFinalizeCommands", () => {
  it("returns empty stageCommand (jj auto-stages)", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-test',
      seedTitle: 'Test task',
      baseBranch: 'main',
      worktreePath: '/tmp/worktrees/bd-test',
    });
    expect(cmds.stageCommand).toBe('');
  });

  it("returns jj describe command for commitCommand", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-test',
      seedTitle: 'Test task',
      baseBranch: 'main',
      worktreePath: '/tmp/worktrees/bd-test',
    });
    expect(cmds.commitCommand).toContain('jj describe');
    expect(cmds.commitCommand).toContain('bd-test');
    expect(cmds.commitCommand).toContain('Test task');
    expect(cmds.commitCommand).toContain('jj new');
  });

  it("returns jj git push with --allow-new for pushCommand", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-test',
      seedTitle: 'Test task',
      baseBranch: 'main',
      worktreePath: '/tmp/worktrees/bd-test',
    });
    expect(cmds.pushCommand).toContain('jj git push');
    expect(cmds.pushCommand).toContain('--allow-new');
    expect(cmds.pushCommand).toContain('foreman/bd-test');
  });

  it("returns jj rebase command with base branch for rebaseCommand", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-test',
      seedTitle: 'Test task',
      baseBranch: 'dev',
      worktreePath: '/tmp/worktrees/bd-test',
    });
    expect(cmds.rebaseCommand).toContain('jj rebase');
    expect(cmds.rebaseCommand).toContain('dev');
  });

  it("returns jj workspace forget for cleanCommand", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-test',
      seedTitle: 'Test task',
      baseBranch: 'main',
      worktreePath: '/tmp/worktrees/bd-test',
    });
    expect(cmds.cleanCommand).toContain('jj workspace forget');
    expect(cmds.cleanCommand).toContain('bd-test');
  });

  it("all 6 FinalizeCommands fields are present", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-abc',
      seedTitle: 'Some task',
      baseBranch: 'main',
      worktreePath: '/tmp/worktrees/bd-abc',
    });
    expect(typeof cmds.stageCommand).toBe('string');
    expect(typeof cmds.commitCommand).toBe('string');
    expect(typeof cmds.pushCommand).toBe('string');
    expect(typeof cmds.rebaseCommand).toBe('string');
    expect(typeof cmds.branchVerifyCommand).toBe('string');
    expect(typeof cmds.cleanCommand).toBe('string');
  });

  it("branchVerifyCommand uses jj bookmark list", () => {
    const b = new JujutsuBackend('/tmp');
    const cmds = b.getFinalizeCommands({
      seedId: 'bd-xyz',
      seedTitle: 'XYZ task',
      baseBranch: 'main',
      worktreePath: '/tmp',
    });
    expect(cmds.branchVerifyCommand).toContain('jj bookmark list');
    expect(cmds.branchVerifyCommand).toContain('bd-xyz');
  });
});

// ── Tests requiring jj ────────────────────────────────────────────────────────

describe.skipIf(!JJ_AVAILABLE)("JujutsuBackend (requires jj)", () => {
  it("jj is available", () => {
    expect(JJ_AVAILABLE).toBe(true);
  });
});
