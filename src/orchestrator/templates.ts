import type { BeadInfo, ModelSelection } from "./types.js";

/**
 * Generate the AGENTS.md content placed in each worker worktree.
 */
export function workerAgentMd(
  bead: BeadInfo,
  worktreePath: string,
  model: ModelSelection,
): string {
  const description = bead.description ?? "(no description provided)";

  return `# Worker Agent

## Your Task
**Bead ID:** ${bead.id}
**Title:** ${bead.title}
**Description:** ${description}
**Model:** ${model}
**Worktree:** ${worktreePath}

## Instructions
1. Implement the task described above
2. Write tests for your implementation
3. Update bd status: \`bd update ${bead.id} --claim\`
4. When complete: \`bd close ${bead.id} --reason 'Completed'\`
5. Commit all changes: \`git add -A && git commit -m '${bead.title} (${bead.id})'\`
6. Push: \`git push -u origin foreman/${bead.id}\`

## Rules
- Stay focused on THIS task only
- Do not modify files outside your scope
- If blocked, update the bead: \`bd update ${bead.id} --notes 'Blocked: reason'\`
`;
}
