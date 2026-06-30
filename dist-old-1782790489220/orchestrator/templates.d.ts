import type { SeedInfo, ModelSelection } from "./types.js";
/**
 * Generate the TASK.md content placed in each worker worktree.
 *
 * This file provides context for all agents in the pipeline — the explorer,
 * developer, QA, and reviewer all read this to understand the task.
 *
 * Named TASK.md (not AGENTS.md) to avoid overwriting the project's AGENTS.md
 * when worktree branches are merged back to main.
 */
export declare function workerAgentMd(seed: SeedInfo, worktreePath: string, model: ModelSelection): string;
//# sourceMappingURL=templates.d.ts.map