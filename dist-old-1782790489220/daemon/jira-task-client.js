import { JiraApiClient, } from "./jira-api-client.js";
function mapIssue(jiraIssue) {
    return {
        id: jiraIssue.key,
        title: jiraIssue.fields.summary,
        status: jiraIssue.fields.status?.name?.toLowerCase() ?? "open",
        type: jiraIssue.fields.issuetype?.name?.toLowerCase() ?? "task",
        priority: jiraIssue.fields.priority?.name ?? "medium",
        assignee: null,
        parent: null,
        created_at: jiraIssue.fields.created ?? "",
        updated_at: jiraIssue.fields.updated ?? "",
        labels: jiraIssue.fields.labels ?? [],
    };
}
/**
 * JiraTaskClient implements ITaskClient for Jira.
 * This allows sentinel to file bugs in Jira instead of GitHub when Jira is configured.
 */
export class JiraTaskClient {
    client;
    projectKey;
    lifecycle;
    cachedProjectStatuses = null;
    constructor(config) {
        this.client = new JiraApiClient({
            apiUrl: config.apiUrl,
            email: config.email,
            apiToken: config.apiToken,
            apiVersion: config.apiVersion ?? "cloud",
        });
        this.projectKey = config.projectKey;
        this.lifecycle = config.lifecycle ?? { autoDetect: true };
    }
    /**
     * Detect lifecycle stages from project statuses.
     * Uses Jira's status categories (TODO, IN_PROGRESS, DONE) for auto-detection.
     */
    async detectLifecycle() {
        if (this.cachedProjectStatuses) {
            return this.inferLifecycleFromStatuses(this.cachedProjectStatuses);
        }
        try {
            this.cachedProjectStatuses = await this.client.getProjectStatuses(this.projectKey);
            return this.inferLifecycleFromStatuses(this.cachedProjectStatuses);
        }
        catch {
            // Return sensible defaults if we can't fetch statuses
            return {
                startStatuses: ["To Do", "Open", "Backlog", "Ready", "Ready for Development"],
                inProgressStatuses: ["In Progress", "In Review", "QA", "Testing", "Code Review"],
                doneStatuses: ["Done", "Closed", "Resolved"],
                autoDetect: false,
            };
        }
    }
    /**
     * Infer lifecycle stages from project status data.
     * Maps Jira status categories to our lifecycle stages.
     */
    inferLifecycleFromStatuses(statuses) {
        const startStatuses = new Set();
        const inProgressStatuses = new Set();
        const doneStatuses = new Set();
        for (const issueType of statuses) {
            for (const status of issueType.statuses) {
                const category = status.statusCategory?.key;
                const name = status.name;
                if (category === "new" || category === "undefined") {
                    // "To Do" category - these are start statuses
                    startStatuses.add(name);
                }
                else if (category === "indeterminate") {
                    // "In Progress" category - these are in-progress statuses
                    inProgressStatuses.add(name);
                }
                else if (category === "done") {
                    // "Done" category
                    doneStatuses.add(name);
                }
                else {
                    // Fallback: categorize by name patterns
                    const lowerName = name.toLowerCase();
                    if (lowerName.includes("to do") || lowerName.includes("open") || lowerName.includes("backlog") || lowerName.includes("ready")) {
                        startStatuses.add(name);
                    }
                    else if (lowerName.includes("progress") || lowerName.includes("review") || lowerName.includes("testing") || lowerName.includes("qa")) {
                        inProgressStatuses.add(name);
                    }
                    else if (lowerName.includes("done") || lowerName.includes("closed") || lowerName.includes("resolved")) {
                        doneStatuses.add(name);
                    }
                }
            }
        }
        return {
            startStatuses: Array.from(startStatuses),
            inProgressStatuses: Array.from(inProgressStatuses),
            doneStatuses: Array.from(doneStatuses),
            autoDetect: true,
        };
    }
    /**
     * Get the effective lifecycle config (from cache or detection).
     */
    async getLifecycle() {
        // If explicit config was provided, use it
        if (!this.lifecycle.autoDetect) {
            return this.lifecycle;
        }
        // Otherwise auto-detect
        return this.detectLifecycle();
    }
    /**
     * Create a new issue in Jira.
     */
    async create(title, opts) {
        const result = await this.client.createIssue({
            projectKey: this.projectKey,
            issueType: opts?.type ?? "Bug",
            summary: title,
            description: opts?.description,
            labels: opts?.labels,
            priority: opts?.priority,
        });
        // Fetch the created issue to get full details
        const issue = await this.client.getIssue(result.key);
        return mapIssue(issue);
    }
    /**
     * List issues in the project with optional filters.
     */
    async list(opts) {
        const jqlParts = [`project = ${this.projectKey}`];
        if (opts?.status) {
            const statusMap = {
                open: '"To Do" OR "Open" OR "Backlog"',
                in_progress: '"In Progress"',
                done: '"Done" OR "Closed" OR "Resolved"',
                closed: '"Done" OR "Closed" OR "Resolved"',
            };
            const statusClause = statusMap[opts.status.toLowerCase()];
            if (statusClause) {
                jqlParts.push(`status IN (${statusClause})`);
            }
            else {
                jqlParts.push(`status = "${opts.status}"`);
            }
        }
        if (opts?.type) {
            jqlParts.push(`issuetype = "${opts.type}"`);
        }
        const jql = jqlParts.join(" AND ");
        const result = await this.client.search(jql, { maxResults: 100 });
        return result.issues.map(mapIssue);
    }
    /**
     * Return open issues that are ready to work on.
     */
    async ready() {
        const jql = `project = ${this.projectKey} AND status IN ("To Do", "Open", "Backlog") ORDER BY created ASC`;
        const result = await this.client.search(jql, { maxResults: 50 });
        return result.issues.map(mapIssue);
    }
    /**
     * Get full details for an issue.
     */
    async show(id) {
        const issue = await this.client.getIssue(id);
        return {
            status: issue.fields.status?.name?.toLowerCase() ?? "open",
            description: issue.fields.description ?? null,
            notes: null,
        };
    }
    /**
     * Claim an issue — transition it from start status to in-progress.
     *
     * This is the key integration point for Sentinel: when Sentinel picks up
     * an issue from the ready queue, it calls claim() to transition it to
     * a working status.
     *
     * Returns the updated issue, or throws if no valid transition exists.
     */
    async claim(id) {
        const lifecycle = await this.getLifecycle();
        const transitions = await this.client.getIssueTransitions(id);
        // Find a transition that moves to an in-progress status
        const inProgressNames = new Set((lifecycle.inProgressStatuses ?? ["In Progress"]).map((s) => s.toLowerCase()));
        // First, try to find a direct transition to in-progress
        const transitionToInProgress = transitions.find((t) => inProgressNames.has(t.to.name.toLowerCase()));
        if (transitionToInProgress) {
            await this.client.transitionIssue(id, transitionToInProgress.id);
            const updatedIssue = await this.client.getIssue(id);
            return mapIssue(updatedIssue);
        }
        // If no direct transition, find any available transition
        if (transitions.length > 0) {
            // Prefer transitions that don't go to done
            const doneNames = new Set((lifecycle.doneStatuses ?? ["Done", "Closed"]).map((s) => s.toLowerCase()));
            const nonDoneTransition = transitions.find((t) => !doneNames.has(t.to.name.toLowerCase())) ?? transitions[0];
            await this.client.transitionIssue(id, nonDoneTransition.id);
            const updatedIssue = await this.client.getIssue(id);
            return mapIssue(updatedIssue);
        }
        // No transitions available — issue is already in a terminal state
        const issue = await this.client.getIssue(id);
        return mapIssue(issue);
    }
    /**
     * Release an issue — transition it back to a start status or close it.
     * Useful when Sentinel is done with an issue.
     */
    async release(id, close = false) {
        const lifecycle = await this.getLifecycle();
        const transitions = await this.client.getIssueTransitions(id);
        if (close) {
            // Find a transition to done
            const doneNames = new Set((lifecycle.doneStatuses ?? ["Done", "Closed", "Resolved"]).map((s) => s.toLowerCase()));
            const doneTransition = transitions.find((t) => doneNames.has(t.to.name.toLowerCase()));
            if (doneTransition) {
                await this.client.transitionIssue(id, doneTransition.id);
                const updatedIssue = await this.client.getIssue(id);
                return mapIssue(updatedIssue);
            }
        }
        else {
            // Find a transition back to start status
            const startNames = new Set((lifecycle.startStatuses ?? ["To Do", "Backlog"]).map((s) => s.toLowerCase()));
            const startTransition = transitions.find((t) => startNames.has(t.to.name.toLowerCase()));
            if (startTransition) {
                await this.client.transitionIssue(id, startTransition.id);
                const updatedIssue = await this.client.getIssue(id);
                return mapIssue(updatedIssue);
            }
        }
        // Fallback: return the issue as-is if no transition available
        const issue = await this.client.getIssue(id);
        return mapIssue(issue);
    }
    /**
    /**
     * Update fields on an issue.
     */
    async update(_id, _opts) {
        throw new Error("JiraTaskClient.update() not yet implemented");
    }
    /**
     * Close an issue.
     */
    async close(_id, _reason) {
        throw new Error("JiraTaskClient.close() not yet implemented");
    }
    /**
     * Authenticate and verify connection.
     */
    async authenticate() {
        await this.client.authenticate();
    }
}
/**
 * Create a JiraTaskClient from project config.
 */
export async function createJiraTaskClientFromConfig(projectConfig) {
    const apiUrl = projectConfig.apiUrl;
    const email = projectConfig.email;
    const apiToken = projectConfig.apiToken;
    const projectKey = projectConfig.projects?.[0]?.key;
    if (!apiUrl || !email || !apiToken || !projectKey) {
        return null;
    }
    const client = new JiraTaskClient({
        apiUrl,
        email,
        apiToken,
        projectKey,
    });
    // Verify connection
    try {
        await client.authenticate();
        return client;
    }
    catch {
        return null;
    }
}
//# sourceMappingURL=jira-task-client.js.map