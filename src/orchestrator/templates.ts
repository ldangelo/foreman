import type { BeadInfo, ModelSelection } from "./types.js";

/**
 * Generate the AGENTS.md content placed in each worker worktree.
 *
 * This file provides context for all agents in the pipeline — the explorer,
 * developer, QA, and reviewer all read this to understand the task.
 */
export function workerAgentMd(
  bead: BeadInfo,
  worktreePath: string,
  model: ModelSelection,
): string {
  const description = bead.description ?? "(no description provided)";

  return `# Agent Task

## Task Details
**Bead ID:** ${bead.id}
**Title:** ${bead.title}
**Description:** ${description}
**Model:** ${model}
**Worktree:** ${worktreePath}

## Pipeline
This task is processed by a pipeline of specialized agents:
1. **Explorer** — reads the codebase, produces EXPLORER_REPORT.md
2. **Developer** — implements the changes based on the explorer report
3. **QA** — runs tests, verifies correctness, produces QA_REPORT.md
4. **Reviewer** — independent code review, produces REVIEW.md
5. **Finalize** — commits, pushes, closes the bead

Each agent should read this file for task context. If an explorer report
exists (EXPLORER_REPORT.md), read it for codebase understanding.

## Rules
- Stay focused on THIS task only
- Follow existing codebase patterns and conventions
- Do not modify files outside your scope
- If blocked, write a note to BLOCKED.md explaining why
`;
}
