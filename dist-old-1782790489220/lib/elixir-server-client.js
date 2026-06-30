export class ElixirServerClient {
    baseUrl;
    authToken;
    constructor(baseUrl, authToken) {
        this.baseUrl = baseUrl;
        this.authToken = authToken;
    }
    async sendCommand(command) {
        const response = await fetch(new URL("/api/v1/commands", this.baseUrl), {
            method: "POST",
            headers: this.headers(command),
            body: JSON.stringify({ schema_version: 1, payload: {}, metadata: {}, ...command }),
        });
        const body = (await response.json());
        if (!body.ok || response.ok)
            return body;
        return {
            ok: false,
            error: {
                code: "INTERNAL",
                message: `unexpected Foreman server status ${response.status}`,
                details: body,
                retryable: false,
                correlation_id: command.metadata?.correlation_id,
            },
        };
    }
    async listProjects() {
        const body = await this.getJson("/api/v1/projects");
        return body.projects;
    }
    async listTasks() {
        const body = await this.getJson("/api/v1/tasks");
        return body.tasks;
    }
    async getTask(taskId) {
        const response = await fetch(new URL(`/api/v1/tasks/${encodeURIComponent(taskId)}`, this.baseUrl), {
            method: "GET",
            headers: this.headers({ command_id: `task-get-${taskId}`, command_type: "task.get" }),
        });
        if (response.status === 404)
            return null;
        const body = await response.json();
        if (response.ok && body.ok)
            return body.task;
        throw new Error(!body.ok ? body.error.message : `unexpected Foreman server status ${response.status}`);
    }
    async listRuns(opts = {}) {
        const params = new URLSearchParams();
        if (opts.projectId)
            params.set("project_id", opts.projectId);
        const query = params.toString();
        const body = await this.getJson(`/api/v1/runs${query ? `?${query}` : ""}`);
        return body.runs;
    }
    async schedulerTick() {
        const response = await fetch(new URL("/api/v1/scheduler/tick", this.baseUrl), {
            method: "POST",
            headers: this.headers({ command_id: "scheduler-tick", command_type: "scheduler.tick" }),
            body: JSON.stringify({}),
        });
        const body = await response.json();
        if (response.ok && body.ok)
            return body.scheduler;
        throw new Error(!body.ok ? body.error.message : `unexpected Foreman server status ${response.status}`);
    }
    async listInbox(opts = {}) {
        const params = new URLSearchParams();
        if (opts.runId)
            params.set("run_id", opts.runId);
        if (opts.projectId)
            params.set("project_id", opts.projectId);
        if (opts.limit !== undefined)
            params.set("limit", String(opts.limit));
        if (opts.unread !== undefined)
            params.set("unread", String(opts.unread));
        const query = params.toString();
        const body = await this.getJson(`/api/v1/inbox${query ? `?${query}` : ""}`);
        return body.inbox;
    }
    async listEvents(opts = {}) {
        const params = new URLSearchParams();
        if (opts.runId)
            params.set("run_id", opts.runId);
        if (opts.projectId)
            params.set("project_id", opts.projectId);
        if (opts.limit !== undefined)
            params.set("limit", String(opts.limit));
        const query = params.toString();
        const body = await this.getJson(`/api/v1/events${query ? `?${query}` : ""}`);
        return body.events;
    }
    async getRunLogs(runId, view = "compact") {
        const body = await this.getJson(`/api/v1/runs/${encodeURIComponent(runId)}/logs?view=${view}`);
        return body.logs;
    }
    async getRunReport(runId) {
        const body = await this.getJson(`/api/v1/runs/${encodeURIComponent(runId)}/report`);
        return body.report;
    }
    async getDebugTimeline(runId) {
        const body = await this.getJson(`/api/v1/runs/${encodeURIComponent(runId)}/debug`);
        return body.debug;
    }
    async getJson(path) {
        const response = await fetch(new URL(path, this.baseUrl), {
            method: "GET",
            headers: this.headers({ command_id: `read-${path}`, command_type: "read" }),
        });
        const body = await response.json();
        if (response.ok && body.ok !== false)
            return body;
        throw new Error(!body.ok ? body.error.message : `unexpected Foreman server status ${response.status}`);
    }
    headers(command) {
        const headers = {
            "content-type": "application/json",
        };
        const correlationId = command.metadata?.correlation_id;
        if (typeof correlationId === "string")
            headers["x-correlation-id"] = correlationId;
        if (this.authToken)
            headers.authorization = `Bearer ${this.authToken}`;
        return headers;
    }
}
//# sourceMappingURL=elixir-server-client.js.map