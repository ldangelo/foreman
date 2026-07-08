import http from "node:http";
import { randomUUID } from "node:crypto";
import { basename, resolve } from "node:path";
import { ElixirServerClient, type ElixirProject, type ElixirRun } from "../lib/elixir-server-client.js";
import { ElixirServerManager } from "../lib/elixir-server-manager.js";
import { resetAction } from "../cli/commands/reset.js";

export type McpTransport = "stdio" | "http";

type JsonRpcRequest = {
  jsonrpc?: "2.0";
  id?: string | number | null;
  method?: string;
  params?: Record<string, unknown>;
};

type JsonRpcResponse = {
  jsonrpc: "2.0";
  id: string | number | null;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
};

type ToolSpec = {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  handler: (args: Record<string, unknown>) => Promise<unknown>;
  futureUseCases?: string[];
  compact?: boolean;
};

type McpProjectSummary = {
  id: string;
  name: string;
  path: string;
  status: string;
};

type McpRunSummary = {
  run_id: string;
  date: string | null;
  status: string | null;
};

export type ForemanMcpOptions = {
  transport?: McpTransport;
  host?: string;
  port?: number;
  serverUrl?: string;
  authToken?: string;
  mcpAuthToken?: string;
  autoStart?: boolean;
};

const okSchema = { type: "object", properties: {}, additionalProperties: false } as const;
const MCP_MAX_STRING_CHARS = 1_200;
const MCP_MAX_ARRAY_ITEMS = 40;
const MCP_MAX_OBJECT_KEYS = 80;
const MCP_MAX_DEPTH = 6;

type McpCompactOptions = {
  maxStringChars?: number;
  maxArrayItems?: number;
  maxObjectKeys?: number;
  maxDepth?: number;
};

export function compactMcpPayload(value: unknown, options: McpCompactOptions = {}): unknown {
  const limits = {
    maxStringChars: options.maxStringChars ?? MCP_MAX_STRING_CHARS,
    maxArrayItems: options.maxArrayItems ?? MCP_MAX_ARRAY_ITEMS,
    maxObjectKeys: options.maxObjectKeys ?? MCP_MAX_OBJECT_KEYS,
    maxDepth: options.maxDepth ?? MCP_MAX_DEPTH,
  };

  const compact = (current: unknown, depth: number): unknown => {
    if (current === null || current === undefined) return current;
    if (typeof current === "string") return truncateString(current, limits.maxStringChars);
    if (typeof current !== "object") return current;
    if (depth >= limits.maxDepth) return summarizeNestedValue(current);

    if (Array.isArray(current)) {
      const kept = current.slice(0, limits.maxArrayItems).map((item) => compact(item, depth + 1));
      if (current.length > kept.length) {
        kept.push({ _mcp_truncated: `${current.length - kept.length} additional item(s) omitted` });
      }
      return kept;
    }

    const entries = Object.entries(current as Record<string, unknown>);
    const result: Record<string, unknown> = {};
    for (const [key, entryValue] of entries.slice(0, limits.maxObjectKeys)) {
      result[key] = compact(entryValue, depth + 1);
    }
    if (entries.length > limits.maxObjectKeys) {
      result._mcp_truncated = `${entries.length - limits.maxObjectKeys} additional key(s) omitted`;
    }
    return result;
  };

  return compact(value, 0);
}

function normalizeMcpProject(project: ElixirProject): McpProjectSummary {
  const path = resolve(project.path);
  const configuredName = typeof project.config?.name === "string" ? project.config.name : undefined;
  return {
    id: project.project_id ?? project.id ?? basename(path),
    name: project.name ?? configuredName ?? basename(path),
    path,
    status: project.status ?? "active",
  };
}

function summarizeMcpRun(run: ElixirRun): McpRunSummary {
  return {
    run_id: String(run.run_id ?? run.id ?? ""),
    date: runDate(run),
    status: typeof run.status === "string" ? run.status : null,
  };
}

function runDate(run: ElixirRun): string | null {
  for (const key of ["updated_at", "created_at", "started_at", "completed_at"]) {
    const value = run[key];
    if (typeof value === "string" && value.length > 0) return value;
  }

  const toolEvents = run.tool_events;
  if (Array.isArray(toolEvents)) {
    for (const index of [0, toolEvents.length - 1]) {
      const event = toolEvents[index];
      if (event && typeof event === "object" && "observed_at" in event && typeof event.observed_at === "string" && event.observed_at.length > 0) {
        return event.observed_at;
      }
    }
  }

  return null;
}

function truncateString(value: string, maxChars: number): string {
  if (value.length <= maxChars) return value;
  const omitted = value.length - maxChars;
  return `${value.slice(0, maxChars)}… [truncated ${omitted} chars]`;
}

function summarizeNestedValue(value: object): unknown {
  if (Array.isArray(value)) return { _mcp_truncated: `nested array omitted (${value.length} item(s))` };
  return { _mcp_truncated: `nested object omitted (${Object.keys(value).length} key(s))` };
}

export class ForemanMcpServer {
  private readonly manager: ElixirServerManager;
  private readonly client: ElixirServerClient;
  private readonly autoStart: boolean;
  private readonly tools: ToolSpec[];

  constructor(private readonly opts: ForemanMcpOptions = {}) {
    this.manager = new ElixirServerManager({ authToken: opts.authToken });
    const baseUrl = opts.serverUrl ?? this.manager.url;
    this.client = new ElixirServerClient(baseUrl, opts.authToken ?? process.env.FOREMAN_SERVER_AUTH_TOKEN);
    this.autoStart = opts.autoStart ?? true;
    this.tools = this.buildTools();
  }

  async handle(request: JsonRpcRequest): Promise<JsonRpcResponse | null> {
    if (!request.id && request.method?.startsWith("notifications/")) return null;
    const id = request.id ?? null;
    try {
      switch (request.method) {
        case "initialize":
          return this.result(id, {
            protocolVersion: "2024-11-05",
            capabilities: { tools: {} },
            serverInfo: { name: "foreman-mcp", version: "0.1.0" },
          });
        case "tools/list":
          return this.result(id, {
            tools: this.tools.map(({ name, description, inputSchema, futureUseCases }) => ({
              name,
              description: futureUseCases?.length
                ? `${description}\n\nFuture use cases: ${futureUseCases.join("; ")}`
                : description,
              inputSchema,
            })),
          });
        case "tools/call":
          return this.result(id, await this.callTool(request.params ?? {}));
        case "ping":
          return this.result(id, {});
        default:
          return this.error(id, -32601, `Method not found: ${request.method ?? "<missing>"}`);
      }
    } catch (error) {
      return this.error(id, -32000, error instanceof Error ? error.message : String(error));
    }
  }

  async startHttp(host = "127.0.0.1", port = 4777): Promise<http.Server> {
    const server = http.createServer(async (req, res) => {
      res.setHeader("access-control-allow-origin", "*");
      res.setHeader("access-control-allow-headers", "content-type, authorization");
      res.setHeader("access-control-allow-methods", "GET, POST, OPTIONS");
      if (req.method === "OPTIONS") return void res.writeHead(204).end();
      if (req.method === "GET" && req.url === "/health") {
        res.setHeader("content-type", "application/json");
        return void res.end(JSON.stringify({ ok: true, name: "foreman-mcp" }));
      }
      if (req.method !== "POST" || (req.url !== "/mcp" && req.url !== "/")) {
        return void res.writeHead(404).end("not found");
      }
      if (!this.authorizeHttpRequest(req)) {
        res.writeHead(401, { "content-type": "application/json" });
        return void res.end(JSON.stringify(this.error(null, -32001, "Unauthorized MCP request")));
      }
      try {
        const body = await readRequestBody(req);
        const payload = JSON.parse(body) as JsonRpcRequest | JsonRpcRequest[];
        const responses = Array.isArray(payload)
          ? (await Promise.all(payload.map((item) => this.handle(item)))).filter(Boolean)
          : await this.handle(payload);
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify(responses));
      } catch (error) {
        res.writeHead(400, { "content-type": "application/json" });
        res.end(JSON.stringify(this.error(null, -32700, error instanceof Error ? error.message : String(error))));
      }
    });
    await new Promise<void>((resolve) => server.listen(port, host, resolve));
    return server;
  }

  startStdio(): void {
    const reader = new McpStdioFramer(async (request) => {
      const response = await this.handle(request);
      if (response) writeMcpFrame(process.stdout, response);
    });
    process.stdin.on("data", (chunk) => reader.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)));
  }

  private async callTool(params: Record<string, unknown>): Promise<unknown> {
    const name = stringParam(params, "name");
    const args = objectParam(params, "arguments", {});
    const tool = this.tools.find((candidate) => candidate.name === name);
    if (!tool) throw new Error(`Unknown Foreman MCP tool: ${name}`);
    const rawData = await tool.handler(args);
    const data = tool.compact === false ? rawData : compactMcpPayload(rawData);
    return {
      content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
      structuredContent: data,
    };
  }

  private buildTools(): ToolSpec[] {
    return [
      {
        name: "foreman.smoke.status",
        description: "One-call operator smoke check: health, scheduler, active project tasks, and recent non-closed tasks.",
        inputSchema: {
          type: "object",
          properties: { project_id: { type: "string" }, project: { type: "string" }, limit: { type: "number", default: 12 } },
          additionalProperties: false,
        },
        futureUseCases: ["agent startup checks", "remote runbooks", "dashboard summary cards"],
        handler: async (args) => {
          const scheduler = await this.getJson("/api/v1/scheduler");
          const health = await this.elixirHealth();
          const projectId = await this.resolveProjectId(args).catch(() => undefined);
          if (!projectId) return { health, scheduler, project: null };
          const activeStatuses = ["ready", "approved", "in-progress", "in_progress", "open", "explorer", "developer", "qa", "reviewer", "finalize"];
          const tasks = await this.client.listTasks();
          const projectTasks = tasks.filter((task) => !projectId || task.project_id === projectId);
          const active = projectTasks.filter((task) => task.status && activeStatuses.includes(task.status));
          const recentOpen = projectTasks
            .filter((task) => !["closed", "merged", "completed", "done"].includes(task.status ?? ""))
            .slice(0, numberParam(args, "limit", 12));
          return { health, scheduler, project_id: projectId, active_count: active.length, active, recent_open: recentOpen };
        },
      },
      {
        name: "foreman.health",
        description: "Return MCP and Elixir server health in one compact object.",
        inputSchema: okSchema,
        futureUseCases: ["remote client readiness checks", "CI preflight gates", "agent startup context"],
        handler: async () => ({ mcp: { ok: true }, elixir: await this.elixirHealth() }),
      },
      {
        name: "foreman.scheduler.status",
        description: "Read scheduler state, including active and stale active runs.",
        inputSchema: okSchema,
        futureUseCases: ["remote operator dashboards", "capacity alerts", "stale-run automation"],
        handler: async () => this.getJson("/api/v1/scheduler"),
      },
      {
        name: "foreman.scheduler.tick",
        description: "Manually run one scheduler tick. Use for smoke tests and controlled dispatch.",
        inputSchema: { type: "object", properties: {}, additionalProperties: false },
        futureUseCases: ["human-approved dispatch", "remote scheduler control", "dry-run scheduling once API supports it"],
        handler: async () => this.postJson("/api/v1/scheduler/tick", undefined),
      },
      {
        name: "foreman.projects.list",
        description: "List registered Elixir projects.",
        inputSchema: {
          type: "object",
          properties: { status: { type: "string", enum: ["active", "paused", "archived"] }, search: { type: "string" } },
          additionalProperties: false,
        },
        futureUseCases: ["multi-tenant remote Foreman", "project-scoped auth", "project health rollups"],
        handler: async (args) => {
          const status = optionalString(args.status);
          const search = optionalString(args.search)?.toLowerCase();
          return (await this.client.listProjects())
            .map(normalizeMcpProject)
            .filter((project) => status ? project.status === status : project.status !== "archived")
            .filter((project) => !search || project.name.toLowerCase().includes(search));
        },
      },
      {
        name: "foreman.tasks.list",
        description: "List tasks from the Elixir task projection.",
        inputSchema: {
          type: "object",
          properties: {
            project_id: { type: "string" },
            project: { type: "string", description: "Project name or id; project_id wins." },
            status: { type: "array", items: { type: "string" } },
            limit: { type: "number", default: 50 },
          },
          additionalProperties: false,
        },
        futureUseCases: ["natural-language backlog triage", "remote task approval", "cross-project board views"],
        handler: async (args) => {
          const projectId = await this.resolveProjectId(args).catch(() => undefined);
          const statuses = arrayOfStrings(args.status);
          return (await this.client.listTasks())
            .filter((task) => !projectId || task.project_id === projectId)
            .filter((task) => !statuses?.length || (task.status !== undefined && statuses.includes(task.status)))
            .slice(0, numberParam(args, "limit", 50));
        },
      },
      {
        name: "foreman.tasks.get",
        description: "Get one task by id from the Elixir task projection.",
        inputSchema: {
          type: "object",
          required: ["task_id"],
          properties: { task_id: { type: "string" }, project_id: { type: "string" }, project: { type: "string" } },
          additionalProperties: false,
        },
        futureUseCases: ["task-context injection for remote agents", "debug bundles", "workflow routing explainers"],
        handler: async (args) => {
          return this.client.getTask(stringParam(args, "task_id"));
        },
      },
      {
        name: "foreman.tasks.update",
        description: "Update task status/title/description through the Elixir command boundary.",
        inputSchema: {
          type: "object",
          required: ["task_id"],
          properties: {
            task_id: { type: "string" },
            project_id: { type: "string" },
            status: { type: "string" },
            title: { type: "string" },
            description: { type: "string" },
          },
          additionalProperties: false,
        },
        futureUseCases: ["remote approvals", "human-in-the-loop state changes", "policy-gated mutations"],
        handler: async (args) => this.client.sendCommand({
          command_id: `mcp-task-update-${Date.now()}-${randomUUID()}`,
          command_type: "task.update",
          payload: args,
          metadata: { source: "foreman-mcp" },
        }),
      },
      {
        name: "foreman.tasks.approve",
        description: "Approve an open task through the Elixir command boundary, moving it to ready for dispatch.",
        inputSchema: {
          type: "object",
          required: ["task_id"],
          properties: {
            task_id: { type: "string" },
            project_id: { type: "string" },
          },
          additionalProperties: false,
        },
        futureUseCases: ["operator task triage", "human-in-the-loop approvals", "controlled scheduler dispatch"],
        handler: async (args) => this.client.sendCommand({
          command_id: `mcp-task-approve-${Date.now()}-${randomUUID()}`,
          command_type: "task.approve",
          payload: args,
          metadata: { source: "foreman-mcp" },
        }),
      },
      {
        name: "foreman.tasks.reset",
        description: "Reset a task through the local Foreman reset flow: stop stale workers, clean worktree/branch/log artifacts, mark ready, and tick the scheduler.",
        inputSchema: {
          type: "object",
          required: ["task_id"],
          properties: {
            task_id: { type: "string" },
            project_id: { type: "string", description: "Registered project id; used when project is omitted." },
            project: { type: "string", description: "Registered project name/id/path." },
            project_path: { type: "string", description: "Absolute project path for advanced/scripted use." },
            reason: { type: "string" },
            dry_run: { type: "boolean", default: false },
            keep_worktree: { type: "boolean", default: false },
          },
          additionalProperties: false,
        },
        futureUseCases: ["remote stale-worker recovery", "operator-approved reruns", "agent-driven recovery runbooks"],
        handler: async (args) => {
          const code = await resetAction(stringParam(args, "task_id"), {
            project: optionalString(args.project) ?? optionalString(args.project_id),
            projectPath: optionalString(args.project_path),
            reason: optionalString(args.reason),
            dryRun: args.dry_run === true,
            keepWorktree: args.keep_worktree === true,
          });
          return { ok: code === 0, exit_code: code };
        },
      },
      {
        name: "foreman.runs.list",
        description: "List recent runs from the Elixir run projection as lightweight summaries.",
        inputSchema: {
          type: "object",
          properties: { project_id: { type: "string" }, project: { type: "string" }, status: { type: "array", items: { type: "string" } }, limit: { type: "number", default: 20 } },
          additionalProperties: false,
        },
        futureUseCases: ["remote run monitor", "cost/capacity reporting", "replay/debug launchers"],
        handler: async (args) => {
          const projectId = await this.resolveProjectId(args).catch(() => undefined);
          const statuses = arrayOfStrings(args.status);
          return (await this.client.listRuns({ projectId }))
            .filter((run) => !statuses?.length || (typeof run.status === "string" && statuses.includes(run.status)))
            .slice(0, numberParam(args, "limit", 20))
            .map(summarizeMcpRun);
        },
      },
      {
        name: "foreman.runs.inspect",
        description: "Return the full Elixir run payload for one run id.",
        inputSchema: {
          type: "object",
          required: ["run_id"],
          properties: { run_id: { type: "string" } },
          additionalProperties: false,
        },
        futureUseCases: ["focused run debugging", "support bundle generation", "payload inspection without list bloat"],
        compact: false,
        handler: async (args) => {
          const runId = stringParam(args, "run_id");
          const run = (await this.client.listRuns()).find((candidate) => candidate.run_id === runId || candidate.id === runId);
          if (!run) throw new Error(`Run not found: ${runId}`);
          return run;
        },
      },
      {
        name: "foreman.inbox.list",
        description: "List agent inbox messages for a run or project.",
        inputSchema: {
          type: "object",
          properties: { project_id: { type: "string" }, project: { type: "string" }, run_id: { type: "string" }, limit: { type: "number", default: 50 }, unread: { type: "boolean" } },
          additionalProperties: false,
        },
        futureUseCases: ["remote agent collaboration", "operator notification feeds", "threaded message UIs"],
        handler: async (args) => {
          const runId = optionalString(args.run_id);
          const projectId = await this.resolveProjectId(args).catch(() => undefined);
          return this.client.listInbox({ runId, projectId, limit: numberParam(args, "limit", 50), unread: args.unread === true });
        },
      },
      {
        name: "foreman.events.list",
        description: "List lifecycle events for a run or project.",
        inputSchema: {
          type: "object",
          properties: { project_id: { type: "string" }, project: { type: "string" }, run_id: { type: "string" }, limit: { type: "number", default: 50 } },
          additionalProperties: false,
        },
        futureUseCases: ["activity feed unification", "audit export", "remote timeline visualization"],
        handler: async (args) => {
          const runId = optionalString(args.run_id);
          const projectId = await this.resolveProjectId(args).catch(() => undefined);
          return this.client.listEvents({ runId, projectId, limit: numberParam(args, "limit", 50) });
        },
      },
      {
        name: "foreman.debug.timeline",
        description: "Return the Elixir debug timeline for a run.",
        inputSchema: { type: "object", required: ["run_id"], properties: { run_id: { type: "string" } }, additionalProperties: false },
        futureUseCases: ["remote trace dashboards", "agent failure diagnosis", "support bundle generation"],
        handler: async (args) => this.client.getDebugTimeline(stringParam(args, "run_id")),
      },
    ];
  }

  private result(id: string | number | null, result: unknown): JsonRpcResponse {
    return { jsonrpc: "2.0", id, result };
  }

  private error(id: string | number | null, code: number, message: string, data?: unknown): JsonRpcResponse {
    return { jsonrpc: "2.0", id, error: { code, message, data } };
  }

  private async ensureElixir(): Promise<void> {
    if (!this.autoStart) return;
    await this.manager.ensureRunning();
  }

  private async elixirHealth(): Promise<unknown> {
    if (this.autoStart) await this.manager.ensureRunning();
    return this.manager.health();
  }

  private async getJson(path: string): Promise<unknown> {
    await this.ensureElixir();
    const response = await fetch(new URL(path, this.opts.serverUrl ?? this.manager.url), { headers: this.headers() });
    return response.json();
  }

  private async postJson(path: string, body: unknown): Promise<unknown> {
    await this.ensureElixir();
    const response = await fetch(new URL(path, this.opts.serverUrl ?? this.manager.url), {
      method: "POST",
      headers: { ...this.headers(), "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return response.json();
  }

  private headers(): Record<string, string> {
    const token = this.opts.authToken ?? process.env.FOREMAN_SERVER_AUTH_TOKEN;
    return token ? { authorization: `Bearer ${token}` } : {};
  }

  private authorizeHttpRequest(req: http.IncomingMessage): boolean {
    const token = this.opts.mcpAuthToken ?? process.env.FOREMAN_MCP_AUTH_TOKEN;
    if (!token) return true;
    const header = req.headers.authorization;
    return header === `Bearer ${token}`;
  }

  private async resolveProjectId(args: Record<string, unknown>): Promise<string> {
    const direct = optionalString(args.project_id);
    if (direct) return direct;
    const selector = optionalString(args.project);
    const projects = await this.client.listProjects();
    const match = selector
      ? projects.find((project) => project.project_id === selector || project.id === selector || project.name === selector || project.path === selector || project.path.includes(selector))
      : projects[0];
    const projectId = match?.project_id ?? match?.id;
    if (!projectId) throw new Error("Project not found; pass project_id or project");
    return projectId;
  }
}

class McpStdioFramer {
  private buffer = Buffer.alloc(0);

  constructor(private readonly onMessage: (message: JsonRpcRequest) => void | Promise<void>) {}

  push(chunk: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (true) {
      const headerEnd = this.buffer.indexOf("\r\n\r\n");
      if (headerEnd === -1) return;
      const header = this.buffer.slice(0, headerEnd).toString("utf8");
      const match = /content-length:\s*(\d+)/i.exec(header);
      if (!match) throw new Error("Invalid MCP frame: missing Content-Length");
      const length = Number(match[1]);
      const bodyStart = headerEnd + 4;
      const bodyEnd = bodyStart + length;
      if (this.buffer.length < bodyEnd) return;
      const body = this.buffer.slice(bodyStart, bodyEnd).toString("utf8");
      this.buffer = this.buffer.slice(bodyEnd);
      void this.onMessage(JSON.parse(body) as JsonRpcRequest);
    }
  }
}

function writeMcpFrame(stream: NodeJS.WritableStream, message: JsonRpcResponse): void {
  const body = JSON.stringify(message);
  stream.write(`Content-Length: ${Buffer.byteLength(body, "utf8")}\r\n\r\n${body}`);
}

function readRequestBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk) => chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function stringParam(args: Record<string, unknown>, name: string): string {
  const value = args[name];
  if (typeof value !== "string" || value.length === 0) throw new Error(`Missing required string param '${name}'`);
  return value;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function numberParam(args: Record<string, unknown>, name: string, fallback: number): number {
  const value = args[name];
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function objectParam(args: Record<string, unknown>, name: string, fallback: Record<string, unknown>): Record<string, unknown> {
  const value = args[name];
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : fallback;
}

function arrayOfStrings(value: unknown): string[] | undefined {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : undefined;
}
