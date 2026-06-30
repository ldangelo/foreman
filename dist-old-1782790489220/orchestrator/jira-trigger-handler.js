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
import { isDebounced, setDebounced } from "../daemon/jira-debounce-store.js";
import { emitJiraTriggerEvent, } from "./jira-trigger-event.js";
// ── JiraTriggerHandler ─────────────────────────────────────────────────────────
export class JiraTriggerHandler {
    adapter;
    jiraProjectId;
    defaultWorkflow;
    constructor(adapter, jiraProjectId, defaultWorkflow = "default") {
        this.adapter = adapter;
        this.jiraProjectId = jiraProjectId;
        this.defaultWorkflow = defaultWorkflow;
    }
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
    async handleTransition(context) {
        const { issue, projectConfig, jiraProjectId, source, foremanTag } = context;
        const externalId = `jira:${issue.key}`;
        const workflowName = this.mapWorkflow(issue, projectConfig);
        const projectId = this.resolveProjectId();
        // If foremanTag is configured, only dispatch if issue has the tag
        // If foremanTag is not set/empty, dispatch all issues (backward compatible)
        const issueLabels = issue.fields.labels ?? [];
        const shouldDispatch = !foremanTag || foremanTag.trim() === "" ||
            issueLabels.some((label) => label === foremanTag || label === "foreman:dispatch");
        if (!shouldDispatch) {
            this.#emitEvent({
                eventType: "jira:trigger",
                timestamp: new Date().toISOString(),
                source,
                projectKey: projectConfig.key,
                issueKey: issue.key,
                issueSummary: issue.fields.summary,
                issueType: issue.fields.issuetype.name,
                currentStatus: issue.fields.status.name,
                transition: { from: "", to: issue.fields.status.name },
                workflowName,
                taskId: undefined,
                externalId,
                triggered: false,
                skipReason: undefined,
            });
            console.log(`[JiraTriggerHandler] Skipped ${issue.key}: missing foremanTag "${foremanTag}"`);
            return {
                triggered: false,
                reason: "no_foreman_tag",
                workflowName,
                externalId,
            };
        }
        if (await this.isAlreadyTriggered(externalId, projectId)) {
            this.#emitEvent({
                eventType: "jira:trigger",
                timestamp: new Date().toISOString(),
                source,
                projectKey: projectConfig.key,
                issueKey: issue.key,
                issueSummary: issue.fields.summary,
                issueType: issue.fields.issuetype.name,
                currentStatus: issue.fields.status.name,
                transition: { from: "", to: issue.fields.status.name },
                workflowName,
                taskId: undefined,
                externalId,
                triggered: false,
                skipReason: "already_triggered",
            });
            return {
                triggered: false,
                reason: "already_triggered",
                workflowName,
                externalId,
            };
        }
        // Check debounce (REQ-006)
        const debounceSeconds = projectConfig.debounceWindowSeconds ?? 60;
        if (debounceSeconds > 0) {
            const debounced = await isDebounced(jiraProjectId, issue.key, debounceSeconds);
            if (debounced) {
                this.#emitEvent({
                    eventType: "jira:trigger",
                    timestamp: new Date().toISOString(),
                    source,
                    projectKey: projectConfig.key,
                    issueKey: issue.key,
                    issueSummary: issue.fields.summary,
                    issueType: issue.fields.issuetype.name,
                    currentStatus: issue.fields.status.name,
                    transition: { from: "", to: issue.fields.status.name },
                    workflowName,
                    taskId: undefined,
                    externalId,
                    triggered: false,
                    skipReason: "debounced",
                });
                return {
                    triggered: false,
                    reason: "debounced",
                    workflowName,
                    externalId,
                };
            }
        }
        // Create the task
        const taskId = await this.createTask(issue, projectConfig, externalId, workflowName);
        // Record trigger in debounce store
        if (debounceSeconds > 0) {
            await setDebounced(jiraProjectId, issue.key, issue.fields.status.name);
        }
        console.log(`[JiraTriggerHandler] Triggered: ${issue.key} → ${workflowName} (task: ${taskId}, source: ${source})`);
        // Emit success event
        this.#emitEvent({
            eventType: "jira:trigger",
            timestamp: new Date().toISOString(),
            source,
            projectKey: projectConfig.key,
            issueKey: issue.key,
            issueSummary: issue.fields.summary,
            issueType: issue.fields.issuetype.name,
            currentStatus: issue.fields.status.name,
            transition: { from: "", to: issue.fields.status.name },
            workflowName,
            taskId,
            externalId,
            triggered: true,
        });
        return {
            triggered: true,
            taskId,
            workflowName,
            externalId,
        };
    }
    /**
     * Emit an observability event.
     */
    #emitEvent(event) {
        emitJiraTriggerEvent(event);
    }
    /**
     * Check if an external ID has already been triggered.
     *
     * Looks up existing tasks by external_id.
     */
    async isAlreadyTriggered(externalId, projectId) {
        const existing = await this.adapter.getTaskByExternalId(projectId, externalId);
        return existing !== null;
    }
    /**
     * Map a Jira issue to the appropriate Foreman workflow name.
     *
     * Uses the issueTypeWorkflowMap from the project config.
     * Falls back to the configured default or "default" workflow.
     */
    mapWorkflow(issue, projectConfig) {
        const issueType = issue.fields.issuetype.name;
        const workflow = projectConfig.issueTypeWorkflowMap[issueType];
        if (workflow) {
            console.log(`[JiraTriggerHandler] Mapped ${issueType} → ${workflow}`);
            return workflow;
        }
        // Fall back to "default" mapping if configured
        const defaultWf = projectConfig.issueTypeWorkflowMap["default"];
        if (defaultWf) {
            return defaultWf;
        }
        return this.defaultWorkflow;
    }
    /**
     * Create a Foreman task for the Jira issue.
     *
     * The task title is the Jira issue summary.
     * The description includes Jira metadata and a link to the issue.
     * The external_id is set to "jira:<issueKey>" for uniqueness tracking.
     */
    async createTask(issue, projectConfig, externalId, workflowName) {
        const projectId = this.resolveProjectId();
        const jiraUrl = this.buildIssueUrl(issue);
        const title = issue.fields.summary;
        const description = [
            `# Jira Issue: ${issue.key}`,
            ``,
            `**Type:** ${issue.fields.issuetype.name}`,
            `**Status:** ${issue.fields.status.name}`,
            `**Project:** ${issue.fields.project.key}`,
            `**URL:** ${jiraUrl}`,
            ``,
            `## Summary`,
            ``,
            issue.fields.summary,
            ``,
            `*This task was automatically created from a Jira status transition to "${issue.fields.status.name}".*`,
        ].join("\n");
        const task = await this.adapter.createTask(projectId, {
            title,
            description,
            type: this.normalizeIssueType(issue.fields.issuetype.name),
            priority: 2,
            status: "ready",
            externalId,
            labels: [
                `jira-workflow:${workflowName}`,
                `jira-type:${issue.fields.issuetype.name.toLowerCase()}`,
            ],
        });
        return task.id;
    }
    /**
     * Build the Jira issue URL from the issue key.
     * Uses a convention-based URL since the project-level apiUrl isn't available here.
     */
    buildIssueUrl(issue) {
        // Convention: Jira Cloud URLs follow /browse/<KEY> pattern
        // The actual base URL would come from JiraConfig, but we can't access it here
        // For now, use the standard Atlassian pattern with the issue key
        return `https://jira.atlassian.com/browse/${issue.key}`;
    }
    /**
     * Normalize Jira issue type to Foreman task type.
     */
    normalizeIssueType(issueType) {
        const mapping = {
            Epic: "epic",
            Story: "story",
            Task: "task",
            Bug: "bug",
            Subtask: "task",
            Improvement: "task",
        };
        return mapping[issueType] ?? "task";
    }
    /**
     * Resolve the current project ID from the environment.
     */
    resolveProjectId() {
        const projectId = process.env.FOREMAN_PROJECT_ID;
        if (!projectId) {
            throw new Error("FOREMAN_PROJECT_ID environment variable is required for Jira trigger handling");
        }
        return projectId;
    }
}
//# sourceMappingURL=jira-trigger-handler.js.map