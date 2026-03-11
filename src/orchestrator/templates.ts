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

## Agent Team
This task is handled by an Engineering Lead agent that orchestrates a team:
- **Explorer** — reads the codebase, produces EXPLORER_REPORT.md (read-only)
- **Developer** — implements changes and writes tests (read-write)
- **QA** — runs tests, verifies correctness, produces QA_REPORT.md (read-write)
- **Reviewer** — independent code review, produces REVIEW.md (read-only)

The Lead spawns sub-agents to handle each phase and coordinates their work.
Reports (EXPLORER_REPORT.md, QA_REPORT.md, REVIEW.md) are the communication
protocol between agents.

## Rules
- Stay focused on THIS task only
- Follow existing codebase patterns and conventions
- Do not modify files outside your scope
- If blocked, write a note to BLOCKED.md explaining why
`;
}
