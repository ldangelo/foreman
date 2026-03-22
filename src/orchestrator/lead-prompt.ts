/**
 * Lead Agent Prompt — generates the prompt for the Engineering Lead session.
 *
 * The lead is a single Claude session that orchestrates a team of sub-agents
 * (Explorer, Developer, QA, Reviewer) using Claude Code's built-in Agent tool.
 * Sub-agents work collaboratively in the same worktree, communicating via
 * report files (EXPLORER_REPORT.md, DEVELOPER_REPORT.md, QA_REPORT.md, REVIEW.md).
 */

import { loadAndInterpolate } from "./template-loader.js";
import { loadPrompt } from "../lib/prompt-loader.js";

export interface LeadPromptOptions {
  seedId: string;
  seedTitle: string;
  seedDescription: string;
  seedComments?: string;
  skipExplore?: boolean;
  skipReview?: boolean;
  /** Absolute path to project root (contains .foreman/). When provided, uses unified loader. */
  projectRoot?: string;
  /** Workflow name (e.g. "default"). Defaults to "default". */
  workflow?: string;
}

/**
 * Internal helper: resolve a lead prompt phase using unified loader when
 * projectRoot is available, otherwise fall back to bundled template-loader.
 */
function resolveLeadPrompt(
  phase: string,
  vars: Record<string, string | undefined>,
  legacyFilename: string,
  projectRoot: string | undefined,
  workflow: string,
): string {
  if (projectRoot) {
    return loadPrompt(phase, vars, workflow, projectRoot);
  }
  return loadAndInterpolate(legacyFilename, vars as Record<string, string>);
}

export function leadPrompt(opts: LeadPromptOptions): string {
  const {
    seedId,
    seedTitle,
    seedDescription,
    seedComments,
    skipExplore,
    skipReview,
    projectRoot,
    workflow = "default",
  } = opts;
  const commentsSection = seedComments
    ? `\n## Additional Context\n${seedComments}\n`
    : "";

  const explorerSection = skipExplore
    ? `### Explorer — SKIPPED (--skip-explore)`
    : resolveLeadPrompt(
        "lead-explorer",
        { seedId, seedTitle, seedDescription, commentsSection },
        "lead-prompt-explorer.md",
        projectRoot,
        workflow,
      );

  const reviewerSection = skipReview
    ? `### Reviewer — SKIPPED (--skip-review)`
    : resolveLeadPrompt(
        "lead-reviewer",
        { seedId, seedTitle, seedDescription },
        "lead-prompt-reviewer.md",
        projectRoot,
        workflow,
      );

  return resolveLeadPrompt(
    "lead",
    {
      seedId,
      seedTitle,
      seedDescription,
      commentsSection,
      explorerSection,
      reviewerSection,
    },
    "lead-prompt.md",
    projectRoot,
    workflow,
  );
}
