/**
 * JiraTriggerHandler — processes detected Jira status transitions and creates
 * Foreman tasks for workflow execution.
 *
 * This handler:
 * - Validates the transition (not debounced, not already triggered)
 * - Maps the Jira issue type to the appropriate Foreman workflow
 * - Creates a Foreman task with Jira metadata
 * - Dispatches the task for execution
 * - Emits JiraTriggerEvent for observability
 */
import type { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import type { JiraProjectConfig } from "../lib/project-config.js";
import type { JiraIssue } from "../daemon/jira-poller.js";
/**
 * Context passed to the trigger handler when a transition is detected.
 */
export interface TriggerContext {
    issue: JiraIssue;
    projectConfig: JiraProjectConfig;
    jiraProjectId: string;
    source: "poll" | "webhook";
    /** Label that triggers automatic dispatch. Issues without this label are imported but not auto-dispatched. */
    foremanTag?: string;
}
/**
 * Result of handling a trigger.
 */
export interface TriggerResult {
    /** Whether a workflow was triggered */
    triggered: boolean;
    /** Human-readable reason if no trigger occurred */
    reason?: string;
    /** Created task ID */
    taskId?: string;
    /** Workflow that was triggered */
    workflowName: string;
    /** External ID for the Jira issue */
    externalId: string;
}
export declare class JiraTriggerHandler {
    #private;
    private readonly adapter;
    private readonly jiraProjectId;
    private readonly defaultWorkflow;
    constructor(adapter: PostgresAdapter, jiraProjectId: string, defaultWorkflow?: string);
    /**
     * Process a detected Jira status transition.
     *
     * Steps:
     * 1. Generate external ID
     * 2. Check if already triggered (uniqueness)
     * 3. Check if debounced
     * 4. Map issue type to workflow
     * 5. Create task with Jira metadata
     * 6. Emit observability event
     */
    handleTransition(context: TriggerContext): Promise<TriggerResult>;
    /**
     * Check if an external ID has already been triggered.
     *
     * Looks up existing tasks by external_id.
     */
    isAlreadyTriggered(externalId: string, projectId: string): Promise<boolean>;
    /**
     * Map a Jira issue to the appropriate Foreman workflow name.
     *
     * Uses the issueTypeWorkflowMap from the project config.
     * Falls back to the configured default or "default" workflow.
     */
    mapWorkflow(issue: JiraIssue, projectConfig: JiraProjectConfig): string;
    /**
     * Create a Foreman task for the Jira issue.
     *
     * The task title is the Jira issue summary.
     * The description includes Jira metadata and a link to the issue.
     * The external_id is set to "jira:<issueKey>" for uniqueness tracking.
     */
    createTask(issue: JiraIssue, projectConfig: JiraProjectConfig, externalId: string, workflowName: string): Promise<string>;
    /**
     * Build the Jira issue URL from the issue key.
     * Uses a convention-based URL since the project-level apiUrl isn't available here.
     */
    buildIssueUrl(issue: JiraIssue): string;
    /**
     * Normalize Jira issue type to Foreman task type.
     */
    normalizeIssueType(issueType: string): string;
    /**
     * Resolve the current project ID from the environment.
     */
    resolveProjectId(): string;
}
//# sourceMappingURL=jira-trigger-handler.d.ts.map