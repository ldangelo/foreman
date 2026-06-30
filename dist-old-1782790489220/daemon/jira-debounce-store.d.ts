/**
 * JiraDebounceStore — manages debounce state in PostgreSQL.
 * All debounce tracking uses the jira_issue_states table.
 * No JSON file is used — all state is persisted in the database.
 */
export interface IssueState {
    issueKey: string;
    lastKnownStatus: string;
    lastTriggeredAt: Date | null;
}
export interface DebounceCheckResult {
    isDebounced: boolean;
    lastTriggeredAt: Date | null;
}
/**
 * Check if an issue is currently debounced.
 * Uses jira_issue_states.last_triggered_at to determine if within debounce window.
 */
export declare function isDebounced(jiraProjectId: string, issueKey: string, debounceWindowSeconds: number): Promise<boolean>;
/**
 * Get debounce status for an issue, including the last triggered timestamp.
 */
export declare function getDebounceStatus(jiraProjectId: string, issueKey: string): Promise<DebounceCheckResult>;
/**
 * Set debounce: updates last_triggered_at in jira_issue_states.
 * If the issue doesn't have a row yet, creates one.
 */
export declare function setDebounced(jiraProjectId: string, issueKey: string, status: string): Promise<void>;
/**
 * Update last known status without triggering debounce.
 * Used when polling detects a status change but we're not triggering a workflow.
 */
export declare function updateStatus(jiraProjectId: string, issueKey: string, status: string): Promise<void>;
/**
 * Get the last known status for an issue.
 * Returns null if the issue hasn't been tracked yet.
 */
export declare function getLastKnownStatus(jiraProjectId: string, issueKey: string): Promise<string | null>;
/**
 * Check if transitioning to startStatus is a new transition.
 * Returns true if the issue was not previously in a startStatus.
 */
export declare function isNewTransition(jiraProjectId: string, issueKey: string, startStatus: readonly string[]): Promise<boolean>;
/**
 * Cleanup expired debounce entries.
 * Removes last_triggered_at for entries older than the debounce window.
 * Returns the count of cleaned entries.
 */
export declare function cleanup(debounceWindowSeconds: number): Promise<number>;
/**
 * Get all issue states for a Jira project.
 * Useful for loading state at startup.
 */
export declare function getIssueStates(jiraProjectId: string): Promise<IssueState[]>;
//# sourceMappingURL=jira-debounce-store.d.ts.map