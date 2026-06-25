export type ForemanServerCommand = {
  command_id: string;
  command_type: string;
  schema_version?: number;
  payload?: Record<string, unknown>;
  metadata?: Record<string, unknown>;
};

export type ForemanServerOk = {
  ok: true;
  events: string[];
  projection_version: number;
  correlation_id: string;
};

export type ForemanServerError = {
  ok: false;
  error: {
    code: "VALIDATION_FAILED" | "CONFLICT" | "UNAUTHORIZED" | "UNSUPPORTED" | "INTERNAL";
    message: string;
    details: Record<string, unknown>;
    retryable: boolean;
    correlation_id?: string;
  };
};

export type ForemanServerResponse = ForemanServerOk | ForemanServerError;

export type ElixirProject = {
  project_id?: string;
  id?: string;
  name?: string;
  path: string;
  status?: string;
  default_branch?: string;
  github_url?: string;
  config?: Record<string, unknown>;
  health?: Record<string, unknown>;
  updated_at?: string;
  last_sync_at?: string;
};

export type ElixirTask = {
  task_id?: string;
  id?: string;
  project_id?: string;
  title?: string;
  description?: string | null;
  task_type?: string;
  type?: string;
  priority?: number;
  status?: string;
  external_id?: string | null;
  updated_at?: string;
  created_at?: string;
  closed_at?: string | null;
  approved_at?: string | null;
  annotations?: Array<{ body: string; author?: string; created_at?: string }>;
  dependencies?: string[];
  run_id?: string | null;
};

export type ElixirRun = Record<string, unknown> & {
  run_id?: string;
  id?: string;
  project_id?: string;
  task_id?: string;
  status?: string;
};

export type ElixirInboxMessage = Record<string, unknown> & {
  message_id?: string;
  run_id?: string;
  project_id?: string;
  unread?: boolean;
};

export type ElixirSchedulerSkip = Record<string, unknown> & {
  task_id?: string;
  project_id?: string;
  reason?: string;
  task_title?: string;
  task_project_id?: string;
};

export type ElixirEvent = Record<string, unknown> & {
  event_id?: string;
  run_id?: string;
  project_id?: string;
  type?: string;
  event_type?: string;
};

export class ElixirServerClient {
  constructor(
    private readonly baseUrl: string,
    private readonly authToken?: string,
  ) {}

  async sendCommand(command: ForemanServerCommand): Promise<ForemanServerResponse> {
    const response = await fetch(new URL("/api/v1/commands", this.baseUrl), {
      method: "POST",
      headers: this.headers(command),
      body: JSON.stringify({ schema_version: 1, payload: {}, metadata: {}, ...command }),
    });

    const body = (await response.json()) as ForemanServerResponse;
    if (!body.ok || response.ok) return body;

    return {
      ok: false,
      error: {
        code: "INTERNAL",
        message: `unexpected Foreman server status ${response.status}`,
        details: body,
        retryable: false,
        correlation_id: command.metadata?.correlation_id as string | undefined,
      },
    };
  }

  async listProjects(): Promise<ElixirProject[]> {
    const body = await this.getJson<{ ok: true; projects: ElixirProject[] }>("/api/v1/projects");
    return body.projects;
  }

  async listTasks(): Promise<ElixirTask[]> {
    const body = await this.getJson<{ ok: true; tasks: ElixirTask[] }>("/api/v1/tasks");
    return body.tasks;
  }

  async getTask(taskId: string): Promise<ElixirTask | null> {
    const response = await fetch(new URL(`/api/v1/tasks/${encodeURIComponent(taskId)}`, this.baseUrl), {
      method: "GET",
      headers: this.headers({ command_id: `task-get-${taskId}`, command_type: "task.get" }),
    });
    if (response.status === 404) return null;
    const body = await response.json() as { ok: true; task: ElixirTask } | ForemanServerError;
    if (response.ok && body.ok) return body.task;
    throw new Error(!body.ok ? body.error.message : `unexpected Foreman server status ${response.status}`);
  }

  async listRuns(projectId?: string): Promise<ElixirRun[]> {
    const params = new URLSearchParams();
    if (projectId) params.set("project_id", projectId);
    const query = params.toString();
    const body = await this.getJson<{ ok: true; runs: ElixirRun[] }>(`/api/v1/runs${query ? `?${query}` : ""}`);
    return body.runs;
  }

  async getRun(runId: string): Promise<ElixirRun | null> {
    const runs = await this.listRuns();
    return runs.find((run) => run.run_id === runId || run.id === runId) ?? null;
  }

  async listSchedulerSkips(projectId?: string): Promise<ElixirSchedulerSkip[]> {
    const params = new URLSearchParams();
    if (projectId) params.set("project_id", projectId);
    const query = params.toString();
    const body = await this.getJson<{ ok: true; skips: ElixirSchedulerSkip[]; count: number }>(`/api/v1/scheduler/skips${query ? `?${query}` : ""}`);
    return body.skips;
  }

  async listInbox(opts: { runId?: string; projectId?: string; limit?: number; unread?: boolean } = {}): Promise<ElixirInboxMessage[]> {
    const params = new URLSearchParams();
    if (opts.runId) params.set("run_id", opts.runId);
    if (opts.projectId) params.set("project_id", opts.projectId);
    if (opts.limit !== undefined) params.set("limit", String(opts.limit));
    if (opts.unread !== undefined) params.set("unread", String(opts.unread));
    const query = params.toString();
    const body = await this.getJson<{ ok: true; inbox: ElixirInboxMessage[] }>(`/api/v1/inbox${query ? `?${query}` : ""}`);
    return body.inbox;
  }

  async listEvents(opts: { runId?: string; projectId?: string; limit?: number } = {}): Promise<ElixirEvent[]> {
    const params = new URLSearchParams();
    if (opts.runId) params.set("run_id", opts.runId);
    if (opts.projectId) params.set("project_id", opts.projectId);
    if (opts.limit !== undefined) params.set("limit", String(opts.limit));
    const query = params.toString();
    const body = await this.getJson<{ ok: true; events: ElixirEvent[] }>(`/api/v1/events${query ? `?${query}` : ""}`);
    return body.events;
  }

  async getRunLogs(runId: string, view: "compact" | "plain" | "raw" = "compact"): Promise<unknown> {
    const body = await this.getJson<{ ok: true; logs: unknown }>(`/api/v1/runs/${encodeURIComponent(runId)}/logs?view=${view}`);
    return body.logs;
  }

  async getRunReport(runId: string): Promise<unknown> {
    const body = await this.getJson<{ ok: true; report: unknown }>(`/api/v1/runs/${encodeURIComponent(runId)}/report`);
    return body.report;
  }

  async getDebugTimeline(runId: string): Promise<unknown> {
    const body = await this.getJson<{ ok: true; debug: unknown }>(`/api/v1/runs/${encodeURIComponent(runId)}/debug`);
    return body.debug;
  }

  private async getJson<T>(path: string): Promise<T> {
    const response = await fetch(new URL(path, this.baseUrl), {
      method: "GET",
      headers: this.headers({ command_id: `read-${path}`, command_type: "read" }),
    });
    const body = await response.json() as T | ForemanServerError;
    if (response.ok && (body as { ok?: boolean }).ok !== false) return body as T;
    throw new Error(!(body as ForemanServerError).ok ? (body as ForemanServerError).error.message : `unexpected Foreman server status ${response.status}`);
  }

  private headers(command: ForemanServerCommand): Record<string, string> {
    const headers: Record<string, string> = {
      "content-type": "application/json",
    };

    const correlationId = command.metadata?.correlation_id;
    if (typeof correlationId === "string") headers["x-correlation-id"] = correlationId;
    if (this.authToken) headers.authorization = `Bearer ${this.authToken}`;

    return headers;
  }
}
