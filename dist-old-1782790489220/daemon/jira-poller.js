/**
 * Jira Issues Poller — background daemon that monitors Jira status transitions
 * and dispatches Foreman workflows when issues enter configured start statuses.
 */
// ── JiraIssuesPoller ───────────────────────────────────────────────────────────
/**
 * Background poller that periodically fetches issues from configured Jira projects,
 * detects status transitions to configured startStatus values, and invokes the
 * transition callback.
 *
 * State for each tracked issue is persisted to the `jira_issue_states` database table
 * so transitions are not re-triggered on sentinel restart.
 */
export class JiraIssuesPoller {
    adapter;
    client;
    jiraConfig;
    onTransition;
    _foremanTag;
    _interval = null;
    _running = false;
    _stopped = false;
    /**
     * In-memory state for all tracked issues.
     * Loaded from DB on start, updated on each poll cycle.
     * Key: `jiraProjectKey:issueKey`
     */
    _state = new Map();
    constructor(adapter, client, jiraConfig, onTransition, foremanTag) {
        this.adapter = adapter;
        this.client = client;
        this.jiraConfig = jiraConfig;
        this.onTransition = onTransition;
        this._foremanTag = foremanTag;
    }
    /** Start the background polling loop. Idempotent — safe to call on already-running poller. */
    start() {
        if (this._running || this._stopped)
            return;
        this._running = true;
        // Load persisted state from DB before starting
        void this.loadState().catch((err) => {
            console.error("[JiraIssuesPoller] Failed to load state:", err instanceof Error ? err.message : String(err));
        });
        // Run once immediately, then on interval
        void this.pollAll().catch((err) => {
            console.error("[JiraIssuesPoller] Initial poll failed:", err instanceof Error ? err.message : String(err));
        });
        const intervalMs = parseInt(process.env.FOREMAN_JIRA_POLL_INTERVAL_MS ?? "", 10) ||
            (this.jiraConfig.pollIntervalSeconds ?? 60_000);
        const effectiveInterval = Math.max(intervalMs, 30_000); // minimum 30 seconds
        this._interval = setInterval(() => {
            if (!this._running)
                return;
            void this.pollAll().catch((err) => {
                console.error("[JiraIssuesPoller] Poll cycle failed:", err instanceof Error ? err.message : String(err));
            });
        }, effectiveInterval);
        console.log(`[JiraIssuesPoller] Started (interval: ${effectiveInterval}ms, projects: ${this.jiraConfig.projects.length})`);
    }
    /** Stop the polling loop. Cannot be restarted — create a new instance. */
    stop() {
        if (!this._running)
            return;
        this._running = false;
        if (this._interval) {
            clearInterval(this._interval);
            this._interval = null;
        }
        this._stopped = true;
        console.log("[JiraIssuesPoller] Stopped");
    }
    get running() {
        return this._running;
    }
    // -------------------------------------------------------------------------
    // Main polling logic
    // -------------------------------------------------------------------------
    /**
     * Poll all configured Jira projects for status transitions.
     */
    async pollAll() {
        const summary = { projects: 0, issues: 0, transitions: 0, errors: 0 };
        for (const projectConfig of this.jiraConfig.projects) {
            try {
                const result = await this.pollProject(projectConfig);
                summary.projects++;
                summary.issues += result.issues;
                summary.transitions += result.transitions;
            }
            catch (err) {
                console.error(`[JiraIssuesPoller] Error polling project "${projectConfig.key}":`, err instanceof Error ? err.message : String(err));
                summary.errors++;
            }
        }
        return summary;
    }
    /**
     * Poll a single Jira project for issues in startStatus.
     *
     * Builds a JQL query for all issues in the project's startStatus values,
     * fetches current state from Jira, detects transitions, persists state,
     * and invokes the onTransition callback.
     */
    async pollProject(projectConfig) {
        // Build JQL to find issues in startStatus
        const statusConditions = projectConfig.startStatus
            .map((s) => `status = "${s}"`)
            .join(" OR ");
        const jql = `project = "${projectConfig.key}" AND (${statusConditions}) ORDER BY updated DESC`;
        const maxResults = 100;
        let searchResult;
        let retryCount = 0;
        const maxRetries = 3;
        while (retryCount < maxRetries) {
            try {
                searchResult = await this.client.search(jql, { maxResults });
                break; // Success
            }
            catch (err) {
                const isRateLimit = err instanceof Error && err.message.includes("429");
                if (isRateLimit && retryCount < maxRetries - 1) {
                    retryCount++;
                    const delayMs = Math.pow(2, retryCount) * 1000; // Exponential backoff: 2s, 4s, 8s
                    console.warn(`[JiraIssuesPoller] Rate limited, retrying in ${delayMs}ms (attempt ${retryCount}/${maxRetries})`);
                    await new Promise((resolve) => setTimeout(resolve, delayMs));
                    continue;
                }
                // Log as CRITICAL for non-retryable errors
                console.error(`[JiraIssuesPoller][CRITICAL] JQL search failed for project ${projectConfig.key}:`, err instanceof Error ? err.message : String(err));
                throw err;
            }
        }
        if (!searchResult) {
            throw new Error(`Failed to fetch issues after ${maxRetries} attempts`);
        }
        let transitions = 0;
        for (const issue of searchResult.issues) {
            const stateKey = `${projectConfig.key}:${issue.key}`;
            const currentStatus = issue.fields.status.name;
            const previousState = this._state.get(stateKey);
            if (previousState) {
                // Issue was previously tracked — check if it moved from a non-start status
                const wasInStartStatus = projectConfig.startStatus.includes(previousState.lastKnownStatus);
                const isInStartStatus = projectConfig.startStatus.includes(currentStatus);
                if (isInStartStatus && !wasInStartStatus) {
                    // Transition: non-start → start, this is new trigger
                    transitions++;
                    await this.onTransition(issue, projectConfig, this._foremanTag);
                }
                // If it was already in startStatus, no trigger (AC-003-4)
                // If moving within startStatus, no trigger (AC-003-2)
            }
            else {
                // Issue not previously tracked — check if it's currently in startStatus
                if (projectConfig.startStatus.includes(currentStatus)) {
                    // Already in startStatus on first poll — do not trigger (AC-003-4)
                    console.log(`[JiraIssuesPoller] Skipping ${issue.key}: already in startStatus on first poll`);
                }
            }
            // Update in-memory state
            this._state.set(stateKey, {
                lastKnownStatus: currentStatus,
                lastUpdatedAt: issue.fields.updated,
            });
        }
        // Persist state changes to database
        await this.saveState(projectConfig.key);
        return { issues: searchResult.issues.length, transitions };
    }
    // -------------------------------------------------------------------------
    // State persistence
    // -------------------------------------------------------------------------
    /**
     * Load issue state from the database into memory.
     * Exposed for testing purposes.
     */
    async loadState() {
        try {
            const rows = await this.adapter.getJiraIssueStates();
            for (const row of rows) {
                const key = `${row.project_key}:${row.issue_key}`;
                this._state.set(key, {
                    lastKnownStatus: row.last_known_status,
                    lastUpdatedAt: row.last_updated_at,
                });
            }
            console.log(`[JiraIssuesPoller] Loaded ${rows.length} issue states from DB`);
        }
        catch {
            console.warn("[JiraIssuesPoller] Failed to load state from DB, starting fresh");
        }
    }
    /**
     * Persist current issue state to the database.
     * Uses upsert semantics — inserts or updates each tracked issue.
     * Called after every poll cycle and on graceful shutdown.
     */
    async saveState(projectKey) {
        const entries = Array.from(this._state.entries()).filter(([k]) => k.startsWith(`${projectKey}:`));
        for (const [key, state] of entries) {
            const [, issueKey] = key.split(":");
            try {
                await this.adapter.upsertJiraIssueState({
                    jiraProjectKey: projectKey,
                    issueKey,
                    lastKnownStatus: state.lastKnownStatus,
                    lastUpdatedAt: state.lastUpdatedAt,
                });
            }
            catch (err) {
                console.error(`[JiraIssuesPoller] Failed to persist state for ${issueKey}:`, err instanceof Error ? err.message : String(err));
            }
        }
    }
    // -------------------------------------------------------------------------
    // Manual trigger (for on-demand re-poll)
    // -------------------------------------------------------------------------
    /**
     * Manually trigger a poll for a specific project.
     */
    async pollProjectManual(projectConfig) {
        return this.pollProject(projectConfig);
    }
}
//# sourceMappingURL=jira-poller.js.map