/**
 * Tests for the VcsBackend interface and VcsBackendFactory.
 *
 * Verifies that:
 * - The VcsBackend interface is structurally correct (mock implementation compiles).
 * - VcsBackendFactory.resolveBackend() applies the correct resolution logic.
 * - VcsBackendFactory.fromEnv() handles env var values correctly.
 * - GitBackend and JujutsuBackend instances satisfy the VcsBackend interface.
 */

import { describe, it, expect, afterEach, vi } from "vitest";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  realpathSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { VcsBackend } from "../interface.js";
import {
  VcsBackendFactory,
  GitBackend,
  JujutsuBackend,
} from "../index.js";
import type {
  Workspace,
  WorkspaceResult,
  MergeResult,
  RebaseResult,
  DeleteBranchResult,
  FinalizeCommands,
} from "../types.js";

// ── Mock VcsBackend ───────────────────────────────────────────────────────────

/**
 * A minimal mock that satisfies the VcsBackend interface for compile-time
 * verification. This ensures the interface has no breaking structural issues.
 */
class MockVcsBackend implements VcsBackend {
  readonly name = 'git' as const;
  async getRepoRoot(_p: string): Promise<string> { return '/'; }
  async getMainRepoRoot(_p: string): Promise<string> { return '/'; }
  async detectDefaultBranch(_p: string): Promise<string> { return 'main'; }
  async getCurrentBranch(_p: string): Promise<string> { return 'main'; }
  async getRemoteUrl(_p: string, _r?: string): Promise<string | null> { return null; }
  async checkoutBranch(_p: string, _b: string): Promise<void> {}
  async branchExists(_p: string, _b: string): Promise<boolean> { return false; }
  async branchExistsOnRemote(_p: string, _b: string): Promise<boolean> { return false; }
  async deleteBranch(_p: string, _b: string): Promise<DeleteBranchResult> {
    return { deleted: false, wasFullyMerged: false };
  }
  async createWorkspace(_p: string, _s: string): Promise<WorkspaceResult> {
    return { workspacePath: '/tmp/ws', branchName: 'foreman/test' };
  }
  async removeWorkspace(_p: string, _w: string): Promise<void> {}
  async listWorkspaces(_p: string): Promise<Workspace[]> { return []; }
  async stageAll(_p: string): Promise<void> {}
  async commit(_p: string, _m: string): Promise<void> {}
  async push(_p: string, _b: string): Promise<void> {}
  async pull(_p: string, _b: string): Promise<void> {}
  async saveWorktreeState(_p: string): Promise<boolean> { return false; }
  async restoreWorktreeState(_p: string): Promise<void> {}
  async rebase(_p: string, _o: string): Promise<RebaseResult> {
    return { success: true, hasConflicts: false };
  }
  async rebaseBranch(_p: string, _b: string, _o: string): Promise<RebaseResult> {
    return { success: true, hasConflicts: false };
  }
  async restackBranch(_p: string, _b: string, _old: string, _new: string): Promise<RebaseResult> {
    return { success: true, hasConflicts: false };
  }
  async abortRebase(_p: string): Promise<void> {}
  async merge(_p: string, _s: string): Promise<MergeResult> {
    return { success: true };
  }
  async mergeWithStrategy(_p: string, _s: string, _t: string, _strategy: "theirs"): Promise<MergeResult> {
    return { success: true };
  }
  async rollbackFailedMerge(_p: string, _before: string): Promise<void> {}
  async getHeadId(_p: string): Promise<string> { return 'abc123'; }
  async resolveRef(_p: string, _r: string): Promise<string> { return 'abc123'; }
  async getRefCommitTimestamp(_p: string, _r: string): Promise<number | null> { return null; }
  async fetch(_p: string): Promise<void> {}
  async diff(_p: string, _f: string, _t: string): Promise<string> { return ''; }
  async getChangedFiles(_p: string, _f: string, _t: string): Promise<string[]> { return []; }
  async getModifiedFiles(_p: string): Promise<string[]> { return []; }
  async getConflictingFiles(_p: string): Promise<string[]> { return []; }
  async status(_p: string): Promise<string> { return ''; }
  async cleanWorkingTree(_p: string): Promise<void> {}
  async mergeWithoutCommit(_p: string, _s: string, _t: string): Promise<MergeResult> {
    return { success: true };
  }
  async commitNoEdit(_p: string): Promise<void> {}
  async abortMerge(_p: string): Promise<void> {}
  async stageFile(_p: string, _f: string): Promise<void> {}
  async stageFiles(_p: string, _files: string[]): Promise<void> {}
  async checkoutFile(_p: string, _r: string, _f: string): Promise<void> {}
  async showFile(_p: string, _r: string, _f: string): Promise<string> { return ''; }
  async resetHard(_p: string, _r: string): Promise<void> {}
  async removeFile(_p: string, _f: string): Promise<void> {}
  async rebaseContinue(_p: string): Promise<void> {}
  async removeFromIndex(_p: string, _f: string): Promise<void> {}
  async applyPatchToIndex(_p: string, _patch: string): Promise<void> {}
  async getMergeBase(_p: string, _r1: string, _r2: string): Promise<string> { return ''; }
  async getUntrackedFiles(_p: string): Promise<string[]> { return []; }
  async isAncestor(_p: string, _a: string, _d: string): Promise<boolean> { return true; }
  getFinalizeCommands(_vars: import('../types.js').FinalizeTemplateVars): FinalizeCommands {
    return {
      stageCommand: 'git add -A',
      commitCommand: 'git commit -m "test"',
      pushCommand: 'git push origin main',
      integrateTargetCommand: 'git rebase origin/main',
      branchVerifyCommand: 'git rev-parse HEAD',
      cleanCommand: 'git worktree remove /tmp',
      restoreTrackedStateCommand: 'git restore --source=HEAD --staged --worktree -- .beads/issues.jsonl',
    };
  }
}

// ── Interface structural tests ─────────────────────────────────────────────────

describe("VcsBackend interface", () => {
  it("MockVcsBackend fully implements VcsBackend", () => {
    const mock: VcsBackend = new MockVcsBackend();
    expect(mock.name).toBe('git');
  });

  it("VcsBackend can have name='jujutsu'", () => {
    const jj: VcsBackend = new JujutsuBackend('/tmp');
    expect(jj.name).toBe('jujutsu');
  });
});

// ── VcsBackendFactory.resolveBackend ─────────────────────────────────────────

describe("VcsBackendFactory.resolveBackend", () => {
  const tempDirs: string[] = [];

  afterEach(() => {
    for (const d of tempDirs) {
      rmSync(d, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("returns 'git' when config.backend is 'git'", () => {
    const resolved = VcsBackendFactory.resolveBackend({ backend: 'git' }, '/any');
    expect(resolved).toBe('git');
  });

  it("returns 'jujutsu' when config.backend is 'jujutsu'", () => {
    const resolved = VcsBackendFactory.resolveBackend({ backend: 'jujutsu' }, '/any');
    expect(resolved).toBe('jujutsu');
  });

  it("detects 'git' when 'auto' and .git directory exists (no .jj)", () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-vcs-factory-")));
    tempDirs.push(dir);
    // Create .git directory — should resolve to git (no .jj present)
    mkdirSync(join(dir, '.git'));
    const resolved = VcsBackendFactory.resolveBackend({ backend: 'auto' }, dir);
    expect(resolved).toBe('git');
  });

  it("detects 'jujutsu' when 'auto' and .jj directory is present", () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-vcs-factory-jj-")));
    tempDirs.push(dir);
    mkdirSync(join(dir, '.jj'));
    const resolved = VcsBackendFactory.resolveBackend({ backend: 'auto' }, dir);
    expect(resolved).toBe('jujutsu');
  });
});

// ── VcsBackendFactory.create (async) ─────────────────────────────────────────

describe("VcsBackendFactory.create", () => {
  it("creates a GitBackend for backend='git'", async () => {
    const backend = await VcsBackendFactory.create({ backend: 'git' }, '/tmp');
    expect(backend.name).toBe('git');
    expect(backend).toBeInstanceOf(GitBackend);
  });

  it("creates a JujutsuBackend for backend='jujutsu'", async () => {
    const backend = await VcsBackendFactory.create({ backend: 'jujutsu' }, '/tmp');
    expect(backend.name).toBe('jujutsu');
    expect(backend).toBeInstanceOf(JujutsuBackend);
  });
});

// ── VcsBackendFactory.fromEnv ─────────────────────────────────────────────────

describe("VcsBackendFactory.fromEnv", () => {
  it("creates GitBackend when env value is undefined", async () => {
    const backend = await VcsBackendFactory.fromEnv('/tmp', undefined);
    expect(backend.name).toBe('git');
  });

  it("creates GitBackend when env value is 'git'", async () => {
    const backend = await VcsBackendFactory.fromEnv('/tmp', 'git');
    expect(backend.name).toBe('git');
  });

  it("creates JujutsuBackend when env value is 'jujutsu'", async () => {
    const backend = await VcsBackendFactory.fromEnv('/tmp', 'jujutsu');
    expect(backend.name).toBe('jujutsu');
  });

  it("falls back to GitBackend for unrecognized env value", async () => {
    const backend = await VcsBackendFactory.fromEnv('/tmp', 'svn');
    expect(backend.name).toBe('git');
  });
});

// ── Backend instanceof checks ─────────────────────────────────────────────────

describe("GitBackend satisfies VcsBackend", () => {
  it("has correct name", () => {
    const b = new GitBackend('/tmp');
    expect(b.name).toBe('git');
  });

  it("has all required methods", () => {
    const b = new GitBackend('/tmp');
    expect(typeof b.getRepoRoot).toBe('function');
    expect(typeof b.getMainRepoRoot).toBe('function');
    expect(typeof b.detectDefaultBranch).toBe('function');
    expect(typeof b.getCurrentBranch).toBe('function');
    expect(typeof b.checkoutBranch).toBe('function');
    expect(typeof b.branchExists).toBe('function');
    expect(typeof b.branchExistsOnRemote).toBe('function');
    expect(typeof b.deleteBranch).toBe('function');
    expect(typeof b.createWorkspace).toBe('function');
    expect(typeof b.removeWorkspace).toBe('function');
    expect(typeof b.listWorkspaces).toBe('function');
    expect(typeof b.stageAll).toBe('function');
    expect(typeof b.commit).toBe('function');
    expect(typeof b.push).toBe('function');
    expect(typeof b.pull).toBe('function');
    expect(typeof b.saveWorktreeState).toBe('function');
    expect(typeof b.restoreWorktreeState).toBe('function');
    expect(typeof b.rebase).toBe('function');
    expect(typeof b.rebaseBranch).toBe('function');
    expect(typeof b.restackBranch).toBe('function');
    expect(typeof b.abortRebase).toBe('function');
    expect(typeof b.merge).toBe('function');
    expect(typeof b.mergeWithStrategy).toBe('function');
    expect(typeof b.rollbackFailedMerge).toBe('function');
    expect(typeof b.getHeadId).toBe('function');
    expect(typeof b.resolveRef).toBe('function');
    expect(typeof b.fetch).toBe('function');
    expect(typeof b.diff).toBe('function');
    expect(typeof b.getChangedFiles).toBe('function');
    expect(typeof b.getRefCommitTimestamp).toBe('function');
    expect(typeof b.getModifiedFiles).toBe('function');
    expect(typeof b.getConflictingFiles).toBe('function');
    expect(typeof b.status).toBe('function');
    expect(typeof b.cleanWorkingTree).toBe('function');
    expect(typeof b.applyPatchToIndex).toBe('function');
    expect(typeof b.getFinalizeCommands).toBe('function');
  });
});

describe("JujutsuBackend satisfies VcsBackend", () => {
  it("has correct name", () => {
    const b = new JujutsuBackend('/tmp');
    expect(b.name).toBe('jujutsu');
  });

  it("has all required methods", () => {
    const b = new JujutsuBackend('/tmp');
    expect(typeof b.getRepoRoot).toBe('function');
    expect(typeof b.getMainRepoRoot).toBe('function');
    expect(typeof b.detectDefaultBranch).toBe('function');
    expect(typeof b.getCurrentBranch).toBe('function');
    expect(typeof b.checkoutBranch).toBe('function');
    expect(typeof b.branchExists).toBe('function');
    expect(typeof b.branchExistsOnRemote).toBe('function');
    expect(typeof b.deleteBranch).toBe('function');
    expect(typeof b.createWorkspace).toBe('function');
    expect(typeof b.removeWorkspace).toBe('function');
    expect(typeof b.listWorkspaces).toBe('function');
    expect(typeof b.stageAll).toBe('function');
    expect(typeof b.commit).toBe('function');
    expect(typeof b.push).toBe('function');
    expect(typeof b.pull).toBe('function');
    expect(typeof b.saveWorktreeState).toBe('function');
    expect(typeof b.restoreWorktreeState).toBe('function');
    expect(typeof b.rebase).toBe('function');
    expect(typeof b.rebaseBranch).toBe('function');
    expect(typeof b.restackBranch).toBe('function');
    expect(typeof b.abortRebase).toBe('function');
    expect(typeof b.merge).toBe('function');
    expect(typeof b.mergeWithStrategy).toBe('function');
    expect(typeof b.rollbackFailedMerge).toBe('function');
    expect(typeof b.getHeadId).toBe('function');
    expect(typeof b.resolveRef).toBe('function');
    expect(typeof b.fetch).toBe('function');
    expect(typeof b.diff).toBe('function');
    expect(typeof b.getChangedFiles).toBe('function');
    expect(typeof b.getRefCommitTimestamp).toBe('function');
    expect(typeof b.getModifiedFiles).toBe('function');
    expect(typeof b.getConflictingFiles).toBe('function');
    expect(typeof b.status).toBe('function');
    expect(typeof b.cleanWorkingTree).toBe('function');
    expect(typeof b.applyPatchToIndex).toBe('function');
    expect(typeof b.getFinalizeCommands).toBe('function');
  });
});
