import { describe, it, expect } from 'vitest';
import type {
  Workspace,
  WorkspaceResult,
  MergeResult,
  RebaseResult,
  DeleteBranchOptions,
  DeleteBranchResult,
  PushOptions,
  FinalizeTemplateVars,
  FinalizeCommands,
  VcsConfig,
} from '../types.js';

// ── AC-I-002-1: Workspace can replace Worktree from git.ts ──────────────

describe('Workspace type', () => {
  it('has all fields required by Worktree (backward compat)', () => {
    const ws: Workspace = {
      path: '/tmp/worktrees/bd-deoi',
      branch: 'foreman/bd-deoi',
      head: 'abc123def456',
      bare: false,
    };
    expect(ws.path).toBe('/tmp/worktrees/bd-deoi');
    expect(ws.branch).toBe('foreman/bd-deoi');
    expect(ws.head).toBe('abc123def456');
    expect(ws.bare).toBe(false);
  });

  it('accepts a jj change ID as head', () => {
    const ws: Workspace = {
      path: '/tmp/jj-workspace',
      branch: 'trunk()',
      head: 'yklonqvs',   // jj short change ID
      bare: false,
    };
    expect(ws.head).toBe('yklonqvs');
  });

  it('accepts a jj bookmark name as branch', () => {
    const ws: Workspace = {
      path: '/tmp/jj-workspace',
      branch: 'my-bookmark',
      head: 'abc',
      bare: false,
    };
    expect(ws.branch).toBe('my-bookmark');
  });

  it('bare field is required and boolean', () => {
    const ws: Workspace = { path: '/', branch: 'main', head: 'a1b2c3', bare: false };
    expect(typeof ws.bare).toBe('boolean');
  });
});

// ── WorkspaceResult ─────────────────────────────────────────────────────

describe('WorkspaceResult type', () => {
  it('has workspacePath and branchName', () => {
    const result: WorkspaceResult = {
      workspacePath: '/tmp/worktrees/bd-deoi',
      branchName: 'foreman/bd-deoi',
    };
    expect(result.workspacePath).toContain('bd-deoi');
    expect(result.branchName).toBe('foreman/bd-deoi');
  });
});

// ── MergeResult ─────────────────────────────────────────────────────────

describe('MergeResult type', () => {
  it('success:true has no conflicts', () => {
    const result: MergeResult = { success: true };
    expect(result.success).toBe(true);
    expect(result.conflicts).toBeUndefined();
  });

  it('success:false can have conflicts array', () => {
    const result: MergeResult = {
      success: false,
      conflicts: ['src/lib/git.ts', 'package.json'],
    };
    expect(result.conflicts).toHaveLength(2);
  });

  it('conflicts field is optional', () => {
    const minimal: MergeResult = { success: false };
    expect(minimal.conflicts).toBeUndefined();
  });
});

// ── RebaseResult ────────────────────────────────────────────────────────

describe('RebaseResult type', () => {
  it('clean rebase has no conflicting files', () => {
    const result: RebaseResult = { success: true, hasConflicts: false };
    expect(result.conflictingFiles).toBeUndefined();
  });

  it('conflict rebase includes conflictingFiles', () => {
    const result: RebaseResult = {
      success: false,
      hasConflicts: true,
      conflictingFiles: ['src/lib/git.ts'],
    };
    expect(result.hasConflicts).toBe(true);
    expect(result.conflictingFiles).toContain('src/lib/git.ts');
  });

  it('conflictingFiles is optional', () => {
    const result: RebaseResult = { success: false, hasConflicts: true };
    expect(result.conflictingFiles).toBeUndefined();
  });
});

// ── DeleteBranchOptions ─────────────────────────────────────────────────

describe('DeleteBranchOptions type', () => {
  it('both fields are optional', () => {
    const opts: DeleteBranchOptions = {};
    expect(opts.force).toBeUndefined();
    expect(opts.targetBranch).toBeUndefined();
  });

  it('accepts force and targetBranch', () => {
    const opts: DeleteBranchOptions = { force: true, targetBranch: 'dev' };
    expect(opts.force).toBe(true);
    expect(opts.targetBranch).toBe('dev');
  });
});

// ── DeleteBranchResult ──────────────────────────────────────────────────

describe('DeleteBranchResult type', () => {
  it('has required boolean fields', () => {
    const result: DeleteBranchResult = { deleted: true, wasFullyMerged: true };
    expect(typeof result.deleted).toBe('boolean');
    expect(typeof result.wasFullyMerged).toBe('boolean');
  });

  it('can represent a force-deleted unmerged branch', () => {
    const result: DeleteBranchResult = { deleted: true, wasFullyMerged: false };
    expect(result.deleted).toBe(true);
    expect(result.wasFullyMerged).toBe(false);
  });
});

// ── PushOptions ─────────────────────────────────────────────────────────

describe('PushOptions type', () => {
  it('all fields are optional', () => {
    const opts: PushOptions = {};
    expect(opts.force).toBeUndefined();
    expect(opts.allowNew).toBeUndefined();
  });

  it('accepts jj-specific allowNew', () => {
    const opts: PushOptions = { allowNew: true };
    expect(opts.allowNew).toBe(true);
  });

  it('accepts force push', () => {
    const opts: PushOptions = { force: true };
    expect(opts.force).toBe(true);
  });
});

// ── FinalizeTemplateVars ────────────────────────────────────────────────

describe('FinalizeTemplateVars type', () => {
  it('has all required fields', () => {
    const vars: FinalizeTemplateVars = {
      seedId: 'bd-deoi',
      seedTitle: 'Define Shared VCS Types',
      baseBranch: 'dev',
      worktreePath: '/tmp/worktrees/bd-deoi',
    };
    expect(vars.seedId).toBe('bd-deoi');
    expect(vars.baseBranch).toBe('dev');
  });
});

// ── AC-I-002-2: FinalizeCommands has all 6 required fields ──────────────

describe('FinalizeCommands type', () => {
  it('has all 6 required fields', () => {
    const cmds: FinalizeCommands = {
      stageCommand: 'git add -A',
      commitCommand: 'git commit -m "feat: implement task"',
      pushCommand: 'git push origin foreman/bd-deoi',
      rebaseCommand: 'git rebase origin/dev',
      branchVerifyCommand: 'git ls-remote --heads origin foreman/bd-deoi',
      cleanCommand: 'git worktree remove /tmp/worktrees/bd-deoi',
    };
    // Verify all 6 are present and string-typed
    expect(typeof cmds.stageCommand).toBe('string');
    expect(typeof cmds.commitCommand).toBe('string');
    expect(typeof cmds.pushCommand).toBe('string');
    expect(typeof cmds.rebaseCommand).toBe('string');
    expect(typeof cmds.branchVerifyCommand).toBe('string');
    expect(typeof cmds.cleanCommand).toBe('string');
  });

  it('accepts empty strings for no-op commands (e.g. jj auto-staging)', () => {
    const cmds: FinalizeCommands = {
      stageCommand: '',    // jj auto-stages
      commitCommand: 'jj commit -m "feat: implement task"',
      pushCommand: 'jj git push --allow-new',
      rebaseCommand: 'jj rebase -d main',
      branchVerifyCommand: 'jj bookmark list',
      cleanCommand: 'jj workspace forget foreman-bd-deoi',
    };
    expect(cmds.stageCommand).toBe('');
  });
});

// ── VcsConfig ───────────────────────────────────────────────────────────

describe('VcsConfig type', () => {
  it('backend is required and must be git | jujutsu | auto', () => {
    const cfgGit: VcsConfig = { backend: 'git' };
    const cfgJj: VcsConfig = { backend: 'jujutsu' };
    const cfgAuto: VcsConfig = { backend: 'auto' };
    expect(cfgGit.backend).toBe('git');
    expect(cfgJj.backend).toBe('jujutsu');
    expect(cfgAuto.backend).toBe('auto');
  });

  it('git and jujutsu sub-configs are optional', () => {
    const cfg: VcsConfig = { backend: 'auto' };
    expect(cfg.git).toBeUndefined();
    expect(cfg.jujutsu).toBeUndefined();
  });

  it('accepts git useTown option', () => {
    const cfg: VcsConfig = { backend: 'git', git: { useTown: true } };
    expect(cfg.git?.useTown).toBe(true);
  });

  it('accepts jujutsu minVersion option', () => {
    const cfg: VcsConfig = { backend: 'jujutsu', jujutsu: { minVersion: '0.25.0' } };
    expect(cfg.jujutsu?.minVersion).toBe('0.25.0');
  });

  it('useTown and minVersion are optional within sub-configs', () => {
    const cfg: VcsConfig = { backend: 'git', git: {} };
    expect(cfg.git?.useTown).toBeUndefined();
  });
});

// ── AC-I-002-3: Both GitBackend and JujutsuBackend can use all types ─────

describe('Type compatibility across backends', () => {
  it('Workspace works for a git backend scenario', () => {
    // Simulating what GitBackend.createWorkspace() would return
    const gitWorkspace: Workspace = {
      path: '/tmp/worktrees/bd-deoi',
      branch: 'foreman/bd-deoi',
      head: '7c3d2e1f4a8b',   // git SHA
      bare: false,
    };
    const result: WorkspaceResult = {
      workspacePath: gitWorkspace.path,
      branchName: gitWorkspace.branch,
    };
    expect(result.branchName).toBe('foreman/bd-deoi');
  });

  it('Workspace works for a jujutsu backend scenario', () => {
    // Simulating what JujutsuBackend.createWorkspace() would return
    const jjWorkspace: Workspace = {
      path: '/tmp/jj-workspace/bd-deoi',
      branch: 'foreman/bd-deoi',   // jj bookmark name
      head: 'yklonqvs',             // jj short change ID
      bare: false,
    };
    expect(jjWorkspace.head.length).toBeLessThan(40);  // jj IDs are shorter than git SHAs
  });

  it('MergeResult is usable by both backends', () => {
    const gitMerge: MergeResult = { success: true };
    const jjMerge: MergeResult = { success: false, conflicts: ['src/lib/git.ts'] };
    expect(gitMerge.success).toBe(true);
    expect(jjMerge.conflicts).toBeDefined();
  });

  it('PushOptions allowNew is usable by jj, ignorable by git', () => {
    // Both backends accept the same PushOptions shape
    const gitPushOpts: PushOptions = { force: false };
    const jjPushOpts: PushOptions = { force: false, allowNew: true };
    expect(gitPushOpts.allowNew).toBeUndefined();  // git ignores it
    expect(jjPushOpts.allowNew).toBe(true);
  });
});
