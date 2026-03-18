/**
 * Lead Agent Prompt — generates the prompt for the Engineering Lead session.
 *
 * The lead is a single Claude session that orchestrates a team of sub-agents
 * (Explorer, Developer, QA, Reviewer) using Claude Code's built-in Agent tool.
 * Sub-agents work collaboratively in the same worktree, communicating via
 * report files (EXPLORER_REPORT.md, DEVELOPER_REPORT.md, QA_REPORT.md, REVIEW.md).
 */

import { loadAndInterpolate } from "./template-loader.js";

export interface LeadPromptOptions {
  seedId: string;
  seedTitle: string;
  seedDescription: string;
  skipExplore?: boolean;
  skipReview?: boolean;
}

export function leadPrompt(opts: LeadPromptOptions): string {
  const { seedId, seedTitle, seedDescription, skipExplore, skipReview } = opts;

  const explorerSection = skipExplore
    ? `### Explorer — SKIPPED (--skip-explore)`
    : loadAndInterpolate("lead-prompt-explorer.md", { seedId, seedTitle, seedDescription });

  const reviewerSection = skipReview
    ? `### Reviewer — SKIPPED (--skip-review)`
    : loadAndInterpolate("lead-prompt-reviewer.md", { seedId, seedTitle, seedDescription });

  return loadAndInterpolate("lead-prompt.md", {
    seedId,
    seedTitle,
    seedDescription,
    explorerSection,
    reviewerSection,
  });
}
