/**
 * Lead Agent Prompt — generates the prompt for the Engineering Lead session.
 *
 * The lead is a single Claude session that orchestrates a team of sub-agents
 * (Explorer, Developer, QA, Reviewer) using Claude Code's built-in Agent tool.
 * Sub-agents work collaboratively in the same worktree, communicating via
 * report files (EXPLORER_REPORT.md, DEVELOPER_REPORT.md, QA_REPORT.md, REVIEW.md).
 */
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
export declare function leadPrompt(opts: LeadPromptOptions): string;
//# sourceMappingURL=lead-prompt.d.ts.map