/**
 * VCS Backend abstraction for Foreman — main entry point.
 *
 * Exports:
 *   - VcsBackend        — interface that every backend must implement
 *   - VcsBackendFactory — factory for creating the correct backend instance
 *   - GitBackend        — git implementation (introspection fully implemented; rest Phase B)
 *   - JujutsuBackend    — jj implementation (stub in Phase A, full in Phase B)
 *   - All shared types  — re-exported from ./types.js
 *
 * @module src/lib/vcs/index
 */

import { existsSync } from 'node:fs';
import { join } from 'node:path';
import type { VcsBackend } from './backend.js';
import type { VcsConfig } from './types.js';
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
} from './types.js';

// Re-export the VcsBackend interface
export type { VcsBackend } from './backend.js';

// Re-export all shared types so consumers can import from the single entry point.
export type {
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
} from './types.js';

// Re-export the concrete GitBackend.
export { GitBackend } from './git-backend.js';

// ── JujutsuBackend stub ──────────────────────────────────────────────────────

/**
 * Phase-A stub for JujutsuBackend.
 * Full implementation is deferred to Phase B.
 */
export class JujutsuBackend implements VcsBackend {
  readonly projectPath: string;

  constructor(projectPath: string) {
    this.projectPath = projectPath;
  }

  async getRepoRoot(_path: string): Promise<string> {
    throw new Error('JujutsuBackend.getRepoRoot: not yet implemented (Phase B)');
  }
  async getMainRepoRoot(_path: string): Promise<string> {
    throw new Error('JujutsuBackend.getMainRepoRoot: not yet implemented (Phase B)');
  }
  async detectDefaultBranch(_repoPath: string): Promise<string> {
    throw new Error('JujutsuBackend.detectDefaultBranch: not yet implemented (Phase B)');
  }
  async getCurrentBranch(_repoPath: string): Promise<string> {
    throw new Error('JujutsuBackend.getCurrentBranch: not yet implemented (Phase B)');
  }
  async checkoutBranch(_repoPath: string, _branchName: string): Promise<void> {
    throw new Error('JujutsuBackend.checkoutBranch: not yet implemented (Phase B)');
  }
  async branchExists(_repoPath: string, _branchName: string): Promise<boolean> {
    throw new Error('JujutsuBackend.branchExists: not yet implemented (Phase B)');
  }
  async branchExistsOnRemote(_repoPath: string, _branchName: string): Promise<boolean> {
    throw new Error('JujutsuBackend.branchExistsOnRemote: not yet implemented (Phase B)');
  }
  async deleteBranch(
    _repoPath: string,
    _branchName: string,
    _opts?: DeleteBranchOptions,
  ): Promise<DeleteBranchResult> {
    throw new Error('JujutsuBackend.deleteBranch: not yet implemented (Phase B)');
  }
  async createWorkspace(
    _repoPath: string,
    _seedId: string,
    _baseBranch?: string,
    _setupSteps?: string[],
    _setupCache?: string,
  ): Promise<WorkspaceResult> {
    throw new Error('JujutsuBackend.createWorkspace: not yet implemented (Phase B)');
  }
  async removeWorkspace(_repoPath: string, _workspacePath: string): Promise<void> {
    throw new Error('JujutsuBackend.removeWorkspace: not yet implemented (Phase B)');
  }
  async listWorkspaces(_repoPath: string): Promise<Workspace[]> {
    throw new Error('JujutsuBackend.listWorkspaces: not yet implemented (Phase B)');
  }
  async stageAll(_workspacePath: string): Promise<void> {
    throw new Error('JujutsuBackend.stageAll: not yet implemented (Phase B)');
  }
  async commit(_workspacePath: string, _message: string): Promise<string> {
    throw new Error('JujutsuBackend.commit: not yet implemented (Phase B)');
  }
  async getHeadId(_workspacePath: string): Promise<string> {
    throw new Error('JujutsuBackend.getHeadId: not yet implemented (Phase B)');
  }
  async push(_workspacePath: string, _branchName: string, _opts?: PushOptions): Promise<void> {
    throw new Error('JujutsuBackend.push: not yet implemented (Phase B)');
  }
  async pull(_workspacePath: string, _branchName: string): Promise<void> {
    throw new Error('JujutsuBackend.pull: not yet implemented (Phase B)');
  }
  async fetch(_workspacePath: string): Promise<void> {
    throw new Error('JujutsuBackend.fetch: not yet implemented (Phase B)');
  }
  async rebase(_workspacePath: string, _onto: string): Promise<RebaseResult> {
    throw new Error('JujutsuBackend.rebase: not yet implemented (Phase B)');
  }
  async abortRebase(_workspacePath: string): Promise<void> {
    throw new Error('JujutsuBackend.abortRebase: not yet implemented (Phase B)');
  }
  async merge(
    _repoPath: string,
    _branchName: string,
    _targetBranch?: string,
  ): Promise<MergeResult> {
    throw new Error('JujutsuBackend.merge: not yet implemented (Phase B)');
  }
  async getConflictingFiles(_workspacePath: string): Promise<string[]> {
    throw new Error('JujutsuBackend.getConflictingFiles: not yet implemented (Phase B)');
  }
  async diff(_repoPath: string, _from: string, _to: string): Promise<string> {
    throw new Error('JujutsuBackend.diff: not yet implemented (Phase B)');
  }
  async getModifiedFiles(_workspacePath: string, _base: string): Promise<string[]> {
    throw new Error('JujutsuBackend.getModifiedFiles: not yet implemented (Phase B)');
  }
  async cleanWorkingTree(_workspacePath: string): Promise<void> {
    throw new Error('JujutsuBackend.cleanWorkingTree: not yet implemented (Phase B)');
  }
  async status(_workspacePath: string): Promise<string> {
    throw new Error('JujutsuBackend.status: not yet implemented (Phase B)');
  }
  getFinalizeCommands(_vars: FinalizeTemplateVars): FinalizeCommands {
    throw new Error('JujutsuBackend.getFinalizeCommands: not yet implemented (Phase B)');
  }
}

// ── VcsBackendFactory ────────────────────────────────────────────────────────

/**
 * Factory for creating the appropriate VcsBackend instance.
 *
 * Usage:
 * ```ts
 * const backend = await VcsBackendFactory.create(config, projectPath);
 * ```
 *
 * Auto-detection precedence (when backend === 'auto'):
 * 1. `.jj/` directory found → JujutsuBackend (handles colocated git+jj repos)
 * 2. `.git/` directory found → GitBackend
 * 3. Neither found → throws descriptive error
 */
export class VcsBackendFactory {
  /**
   * Create a VcsBackend instance based on the provided configuration.
   *
   * @param config      - VCS configuration (from .foreman/config.yaml)
   * @param projectPath - absolute path to the project root for auto-detection
   * @returns           - the appropriate VcsBackend implementation
   * @throws            - when auto-detection fails or an unknown backend is specified
   */
  static async create(config: VcsConfig, projectPath: string): Promise<VcsBackend> {
    const { backend } = config;

    switch (backend) {
      case 'git': {
        const { GitBackend } = await import('./git-backend.js');
        return new GitBackend(projectPath);
      }

      case 'jujutsu':
        return new JujutsuBackend(projectPath);

      case 'auto': {
        // .jj/ takes precedence — handles colocated git+jj repositories
        if (existsSync(join(projectPath, '.jj'))) {
          return new JujutsuBackend(projectPath);
        }
        if (existsSync(join(projectPath, '.git'))) {
          const { GitBackend } = await import('./git-backend.js');
          return new GitBackend(projectPath);
        }
        throw new Error(
          `No VCS detected in ${projectPath}. Expected .git/ or .jj/ directory.`,
        );
      }

      default: {
        // TypeScript exhaustiveness guard — should never reach here at runtime
        const _exhaustive: never = backend;
        throw new Error(
          `Unknown VCS backend: "${String(_exhaustive)}". Valid values are: git, jujutsu, auto.`,
        );
      }
    }
  }
}
