/**
 * TRD-001-TEST: VcsBackend interface verification.
 *
 * Verifies that:
 * 1. A class implementing VcsBackend must provide all required methods.
 * 2. The interface correctly groups methods into the 6 functional categories.
 * 3. Return types are correct (Promise<T> for async ops, sync for getFinalizeCommands).
 * 4. Both GitBackend and JujutsuBackend export from the correct module.
 *
 * These tests are structural/compilation checks; runtime behaviour is tested in
 * git-backend.test.ts and factory.test.ts.
 */

import { describe, it, expect } from 'vitest';
import type { VcsBackend } from '../backend.js';
import type {
  Workspace,
  WorkspaceResult,
  MergeResult,
  RebaseResult,
  DeleteBranchResult,
  FinalizeCommands,
  FinalizeTemplateVars,
} from '../types.js';
import { GitBackend } from '../git-backend.js';
import { JujutsuBackend } from '../index.js';

// ── Compile-time: mock implementation ───────────────────────────────────────

/**
 * A minimal mock that satisfies the VcsBackend interface.
 * If any method is removed from this class, TypeScript will emit a compile error,
 * proving that the interface enforces the full method surface.
 */
class MockVcsBackend implements VcsBackend {
  // Repository Introspection
  async getRepoRoot(_path: string): Promise<string> { return ''; }
  async getMainRepoRoot(_path: string): Promise<string> { return ''; }
  async detectDefaultBranch(_repoPath: string): Promise<string> { return 'main'; }
  async getCurrentBranch(_repoPath: string): Promise<string> { return 'main'; }

  // Branch / Bookmark Operations
  async checkoutBranch(_repoPath: string, _branchName: string): Promise<void> { /* stub */ }
  async branchExists(_repoPath: string, _branchName: string): Promise<boolean> { return false; }
  async branchExistsOnRemote(_repoPath: string, _branchName: string): Promise<boolean> { return false; }
  async deleteBranch(): Promise<DeleteBranchResult> { return { deleted: false, wasFullyMerged: false }; }

  // Workspace Management
  async createWorkspace(): Promise<WorkspaceResult> { return { workspacePath: '', branchName: '' }; }
  async removeWorkspace(_repoPath: string, _workspacePath: string): Promise<void> { /* stub */ }
  async listWorkspaces(_repoPath: string): Promise<Workspace[]> { return []; }

  // Commit & Sync
  async stageAll(_workspacePath: string): Promise<void> { /* stub */ }
  async commit(_workspacePath: string, _message: string): Promise<string> { return ''; }
  async getHeadId(_workspacePath: string): Promise<string> { return ''; }
  async push(): Promise<void> { /* stub */ }
  async pull(_workspacePath: string, _branchName: string): Promise<void> { /* stub */ }
  async fetch(_workspacePath: string): Promise<void> { /* stub */ }
  async rebase(_workspacePath: string, _onto: string): Promise<RebaseResult> {
    return { success: true, hasConflicts: false };
  }
  async abortRebase(_workspacePath: string): Promise<void> { /* stub */ }

  // Merge Operations
  async merge(): Promise<MergeResult> { return { success: true }; }

  // Diff, Conflict & Status
  async getConflictingFiles(_workspacePath: string): Promise<string[]> { return []; }
  async diff(_repoPath: string, _from: string, _to: string): Promise<string> { return ''; }
  async getModifiedFiles(_workspacePath: string, _base: string): Promise<string[]> { return []; }
  async cleanWorkingTree(_workspacePath: string): Promise<void> { /* stub */ }
  async status(_workspacePath: string): Promise<string> { return ''; }

  // Finalize Command Generation (sync — no Promise)
  getFinalizeCommands(_vars: FinalizeTemplateVars): FinalizeCommands {
    return {
      stageCommand: '',
      commitCommand: '',
      pushCommand: '',
      rebaseCommand: '',
      branchVerifyCommand: '',
      cleanCommand: '',
    };
  }
}

// ── Tests ────────────────────────────────────────────────────────────────────

describe('VcsBackend interface', () => {
  it('MockVcsBackend satisfies VcsBackend interface at compile time', () => {
    const backend: VcsBackend = new MockVcsBackend();
    expect(backend).toBeDefined();
  });

  it('has 4 repository introspection methods', () => {
    const backend = new MockVcsBackend();
    expect(typeof backend.getRepoRoot).toBe('function');
    expect(typeof backend.getMainRepoRoot).toBe('function');
    expect(typeof backend.detectDefaultBranch).toBe('function');
    expect(typeof backend.getCurrentBranch).toBe('function');
  });

  it('has 4 branch/bookmark operation methods', () => {
    const backend = new MockVcsBackend();
    expect(typeof backend.checkoutBranch).toBe('function');
    expect(typeof backend.branchExists).toBe('function');
    expect(typeof backend.branchExistsOnRemote).toBe('function');
    expect(typeof backend.deleteBranch).toBe('function');
  });

  it('has 3 workspace management methods', () => {
    const backend = new MockVcsBackend();
    expect(typeof backend.createWorkspace).toBe('function');
    expect(typeof backend.removeWorkspace).toBe('function');
    expect(typeof backend.listWorkspaces).toBe('function');
  });

  it('has 8 commit & sync methods', () => {
    const backend = new MockVcsBackend();
    expect(typeof backend.stageAll).toBe('function');
    expect(typeof backend.commit).toBe('function');
    expect(typeof backend.getHeadId).toBe('function');
    expect(typeof backend.push).toBe('function');
    expect(typeof backend.pull).toBe('function');
    expect(typeof backend.fetch).toBe('function');
    expect(typeof backend.rebase).toBe('function');
    expect(typeof backend.abortRebase).toBe('function');
  });

  it('has 1 merge operation method', () => {
    const backend = new MockVcsBackend();
    expect(typeof backend.merge).toBe('function');
  });

  it('has 5 diff/conflict/status methods', () => {
    const backend = new MockVcsBackend();
    expect(typeof backend.getConflictingFiles).toBe('function');
    expect(typeof backend.diff).toBe('function');
    expect(typeof backend.getModifiedFiles).toBe('function');
    expect(typeof backend.cleanWorkingTree).toBe('function');
    expect(typeof backend.status).toBe('function');
  });

  it('has 1 finalize command generation method', () => {
    const backend = new MockVcsBackend();
    expect(typeof backend.getFinalizeCommands).toBe('function');
  });

  it('async methods return Promises', async () => {
    const backend = new MockVcsBackend();
    // Spot-check a few Promise-returning methods
    await expect(backend.getRepoRoot('/')).resolves.toBeDefined();
    await expect(backend.branchExists('/', 'main')).resolves.toBe(false);
    await expect(backend.listWorkspaces('/')).resolves.toEqual([]);
  });

  it('getFinalizeCommands is synchronous and returns all 6 command fields', () => {
    const backend = new MockVcsBackend();
    const vars: FinalizeTemplateVars = {
      seedId: 'bd-test',
      seedTitle: 'Test task',
      baseBranch: 'dev',
      worktreePath: '/tmp/worktrees/bd-test',
    };
    const cmds = backend.getFinalizeCommands(vars);
    // Must not be a Promise
    expect(cmds).not.toBeInstanceOf(Promise);
    // Must have all 6 fields
    expect(typeof cmds.stageCommand).toBe('string');
    expect(typeof cmds.commitCommand).toBe('string');
    expect(typeof cmds.pushCommand).toBe('string');
    expect(typeof cmds.rebaseCommand).toBe('string');
    expect(typeof cmds.branchVerifyCommand).toBe('string');
    expect(typeof cmds.cleanCommand).toBe('string');
  });
});

// ── GitBackend implements VcsBackend ─────────────────────────────────────────

describe('GitBackend satisfies VcsBackend interface', () => {
  it('can be assigned to a VcsBackend variable', () => {
    const backend: VcsBackend = new GitBackend('/tmp');
    expect(backend).toBeInstanceOf(GitBackend);
  });

  it('exposes all interface methods', () => {
    const backend = new GitBackend('/tmp');
    // Introspection
    expect(typeof backend.getRepoRoot).toBe('function');
    expect(typeof backend.getMainRepoRoot).toBe('function');
    expect(typeof backend.detectDefaultBranch).toBe('function');
    expect(typeof backend.getCurrentBranch).toBe('function');
    // Branches
    expect(typeof backend.checkoutBranch).toBe('function');
    expect(typeof backend.branchExists).toBe('function');
    expect(typeof backend.branchExistsOnRemote).toBe('function');
    expect(typeof backend.deleteBranch).toBe('function');
    // Workspaces
    expect(typeof backend.createWorkspace).toBe('function');
    expect(typeof backend.removeWorkspace).toBe('function');
    expect(typeof backend.listWorkspaces).toBe('function');
    // Commit & Sync
    expect(typeof backend.stageAll).toBe('function');
    expect(typeof backend.commit).toBe('function');
    expect(typeof backend.getHeadId).toBe('function');
    expect(typeof backend.push).toBe('function');
    expect(typeof backend.pull).toBe('function');
    expect(typeof backend.fetch).toBe('function');
    expect(typeof backend.rebase).toBe('function');
    expect(typeof backend.abortRebase).toBe('function');
    // Merge
    expect(typeof backend.merge).toBe('function');
    // Diff/Status
    expect(typeof backend.getConflictingFiles).toBe('function');
    expect(typeof backend.diff).toBe('function');
    expect(typeof backend.getModifiedFiles).toBe('function');
    expect(typeof backend.cleanWorkingTree).toBe('function');
    expect(typeof backend.status).toBe('function');
    // Finalize
    expect(typeof backend.getFinalizeCommands).toBe('function');
  });

  it('Phase-B stub methods throw descriptive errors', async () => {
    const backend = new GitBackend('/tmp');
    await expect(backend.checkoutBranch('/tmp', 'main')).rejects.toThrow(/Phase B/);
    await expect(backend.stageAll('/tmp')).rejects.toThrow(/Phase B/);
    await expect(backend.merge('/tmp', 'feature')).rejects.toThrow(/Phase B/);
    expect(() => backend.getFinalizeCommands({
      seedId: 'bd-x', seedTitle: 'X', baseBranch: 'dev', worktreePath: '/tmp',
    })).toThrow(/Phase B/);
  });
});

// ── JujutsuBackend satisfies VcsBackend ──────────────────────────────────────

describe('JujutsuBackend satisfies VcsBackend interface', () => {
  it('can be assigned to a VcsBackend variable', () => {
    const backend: VcsBackend = new JujutsuBackend('/tmp');
    expect(backend).toBeInstanceOf(JujutsuBackend);
  });

  it('all methods throw "not yet implemented" for Phase A', async () => {
    const backend = new JujutsuBackend('/tmp');
    await expect(backend.getRepoRoot('/tmp')).rejects.toThrow(/Phase B/);
    await expect(backend.getCurrentBranch('/tmp')).rejects.toThrow(/Phase B/);
    await expect(backend.merge('/tmp', 'feature')).rejects.toThrow(/Phase B/);
  });
});
