/**
 * VCS Backend abstraction for Foreman — main entry point.
 *
 * Exports:
 *   - VcsBackend        — interface that every backend must implement
 *   - VcsBackendFactory — factory for creating the correct backend instance
 *   - GitBackend        — git implementation (introspection fully implemented; rest Phase B)
 *   - JujutsuBackend    — jj implementation (Phase D: full implementation)
 *   - All shared types  — re-exported from ./types.js
 *
 * @module src/lib/vcs/index
 */

import { existsSync } from 'node:fs';
import { join } from 'node:path';
import type { VcsBackend } from './backend.js';
import type { VcsConfig } from './types.js';
import { JujutsuBackend as JujutsuBackendImpl } from './jujutsu-backend.js';

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

// Re-export the concrete JujutsuBackend (Phase D: full implementation).
export { JujutsuBackend } from './jujutsu-backend.js';

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
        return new JujutsuBackendImpl(projectPath);

      case 'auto': {
        // .jj/ takes precedence — handles colocated git+jj repositories
        if (existsSync(join(projectPath, '.jj'))) {
          return new JujutsuBackendImpl(projectPath);
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
