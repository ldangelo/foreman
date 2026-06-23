import http from "node:http";
import { randomUUID } from "node:crypto";
import { existsSync, statSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { ElixirServerClient } from "../lib/elixir-server-client.js";
import { ElixirServerManager } from "../lib/elixir-server-manager.js";

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
    const data = compactMcpData(await tool.handler(args));
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
        description: "Read scheduler state, including active runs, stale runs, repaired stale runs, and scheduler skips.",
        inputSchema: {
          type: "object",
          properties: { project_id: { type: "string" } },
          additionalProperties: false,
        },
        futureUseCases: ["remote operator dashboards", "capacity alerts", "stale-run automation"],
        handler: async (args) => {
          const [scheduler, skips] = await Promise.all([
            this.getJson("/api/v1/scheduler"),
            this.client.listSchedulerSkips(args.project_id as string | undefined),
          ]);
          return { scheduler, skips, skip_count: skips.length };
        },
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
            .filter((project) => !status || project.status === status)
            .filter((project) => !search || [project.project_id, project.id, project.name, project.path].some((value) => value?.toLowerCase().includes(search)));
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
        name: "foreman.runs.list",
        description: "List recent runs from the Elixir run projection.",
        inputSchema: {
          type: "object",
          properties: { project_id: { type: "string" }, project: { type: "string" }, status: { type: "array", items: { type: "string" } }, limit: { type: "number", default: 20 } },
          additionalProperties: false,
        },
        futureUseCases: ["remote run monitor", "cost/capacity reporting", "replay/debug launchers"],
        handler: async (args) => {
          const projectId = await this.resolveProjectId(args).catch(() => undefined);
          const statuses = arrayOfStrings(args.status);
          return (await this.client.listRuns())
            .filter((run) => !projectId || run.project_id === projectId)
            .filter((run) => !statuses?.length || (typeof run.status === "string" && statuses.includes(run.status)))
            .slice(0, numberParam(args, "limit", 20));
        },
      },
      {
        name: "foreman.runs.logs",
        description: "Show event-backed logs for one run, or tail logs for recent runs when run_id is omitted.",
        inputSchema: {
          type: "object",
          properties: { run_id: { type: "string" }, project_id: { type: "string" }, project: { type: "string" }, view: { type: "string", enum: ["compact", "plain", "raw"] }, limit: { type: "number", default: 100 }, runs: { type: "number", default: 20 } },
          additionalProperties: false,
        },
        futureUseCases: ["operator debugging", "run log tailing", "support bundles"],
        handler: async (args) => {
          const requestedView = optionalString(args.view);
          const view = requestedView === "raw" ? "raw" : requestedView === "plain" ? "plain" : "compact";
          const limit = boundedNumberParam(args, "limit", 50, 1, view === "raw" ? 20 : 50);
          const runId = optionalString(args.run_id);
          if (runId) return await this.runLogBundle(runId, view, limit);

          const projectId = await this.resolveProjectId(args).catch(() => undefined);
          const runs = (await this.client.listRuns())
            .filter((run) => !projectId || run.project_id === projectId)
            .slice(0, boundedNumberParam(args, "runs", 5, 1, 10));

          const logs = [];
          for (const run of runs) {
            const id = run.run_id ?? run.id;
            if (!id) continue;
            logs.push({ run_id: id, task_id: run.task_id, status: run.status, logs: await this.runLogBundle(id, view, limit) });
          }
          return logs;
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
          const limit = boundedNumberParam(args, "limit", 25, 1, 50);
          const inbox = await this.client.listInbox({ runId, projectId, limit, unread: args.unread === true });

          if (runId) {
            const derived = await this.runInboxMessages(runId, limit);
            return mergeInbox(inbox, derived, limit);
          }

          const runs = (await this.client.listRuns())
            .filter((run) => !projectId || run.project_id === projectId)
            .slice(0, boundedNumberParam(args, "runs", 5, 1, 10));
          const derived = [];
          for (const run of runs) {
            const id = run.run_id ?? run.id;
            if (!id) continue;
            derived.push(...await this.runInboxMessages(id, Math.max(1, Math.ceil(limit / Math.max(1, runs.length)))));
          }
          return mergeInbox(inbox, derived, limit);
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
          return this.client.listEvents({ runId, projectId, limit: boundedNumberParam(args, "limit", 25, 1, 50) });
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

  private async runLogBundle(runId: string, view: "compact" | "plain" | "raw", limit: number): Promise<unknown> {
    const files = await tailRunLogFiles(runId, limit);
    const eventLogs = tailRunLogs(await this.client.getRunLogs(runId, view), limit, view);
    return { run_id: runId, source: files.length ? "files+events" : "events", files, events: eventLogs };
  }

  private async runInboxMessages(runId: string, limit: number): Promise<Array<Record<string, unknown>>> {
    const [fileMessages, eventMessages] = await Promise.all([
      tailRunInboxFromFiles(runId, limit),
      this.client.listEvents({ runId, limit }).then((events) => eventsToInboxMessages(events)).catch(() => []),
    ]);
    return mergeInbox(fileMessages, eventMessages, limit);
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

function boundedNumberParam(args: Record<string, unknown>, name: string, fallback: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, numberParam(args, name, fallback)));
}

function objectParam(args: Record<string, unknown>, name: string, fallback: Record<string, unknown>): Record<string, unknown> {
  const value = args[name];
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : fallback;
}

function arrayOfStrings(value: unknown): string[] | undefined {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : undefined;
}

async function tailRunLogFiles(runId: string, limit: number): Promise<Array<Record<string, unknown>>> {
  const files = [];
  for (const suffix of ["log", "err", "out"] as const) {
    const path = runLogPath(runId, suffix);
    if (!existsSync(path)) continue;
    const stat = statSync(path);
    const text = await readFile(path, "utf8");
    const lines = text.split("\n").filter((line) => line.length > 0);
    files.push({
      type: suffix,
      path,
      size: stat.size,
      mtime: stat.mtime.toISOString(),
      lines: lines.slice(-limit).map((line) => compactLogLine(line)),
      tailed: lines.length > limit,
      total_lines: lines.length,
    });
  }
  return files;
}

async function tailRunInboxFromFiles(runId: string, limit: number): Promise<Array<Record<string, unknown>>> {
  const messages: Array<Record<string, unknown>> = [];
  for (const suffix of ["err", "out"] as const) {
    const path = runLogPath(runId, suffix);
    if (!existsSync(path)) continue;
    const stat = statSync(path);
    const text = await readFile(path, "utf8");
    const lines = text.split("\n").filter((line) => line.trim().length > 0).slice(-Math.max(limit * 5, 50));
    lines.forEach((line, index) => {
      const parsed = tryParseJson(line);
      const message = compactLogLine(typeof parsed?.message === "string" ? parsed.message : line);
      if (!message.trim()) return;
      messages.push({
        message_id: `log-${runId}-${suffix}-${index}`,
        run_id: runId,
        from: suffix === "err" ? "worker stderr" : "worker stdout",
        to: "operator",
        direction: "worker_to_operator",
        body: message,
        created_at: typeof parsed?.timestamp === "string" ? parsed.timestamp : stat.mtime.toISOString(),
        source: `log.${suffix}`,
        level: parsed?.level,
      });
    });
  }
  return messages.slice(-limit);
}

function runLogPath(runId: string, suffix: "log" | "err" | "out"): string {
  return join(homedir(), ".foreman", "logs", `${runId}.${suffix}`);
}

function compactLogLine(line: string, max = 500): string {
  const text = line.replace(/\s+/g, " ").trim();
  return text.length > max ? `${text.slice(0, max)}… [truncated ${text.length - max} chars]` : text;
}

function compactMcpData(value: unknown, depth = 0): unknown {
  if (typeof value === "string") return compactLogLine(value, 1000);
  if (Array.isArray(value)) return value.slice(0, 100).map((item) => compactMcpData(item, depth + 1));
  if (!value || typeof value !== "object" || depth > 6) return value;
  const out: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value as Record<string, unknown>)) out[key] = compactMcpData(item, depth + 1);
  return out;
}

function tryParseJson(line: string): Record<string, unknown> | null {
  try {
    const parsed = JSON.parse(line) as unknown;
    return parsed && typeof parsed === "object" ? parsed as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

function eventsToInboxMessages(events: Array<Record<string, unknown>>): Array<Record<string, unknown>> {
  return events.map((event) => ({
    message_id: `event-${event.event_id ?? event.sequence ?? randomUUID()}`,
    run_id: event.run_id,
    task_id: event.task_id,
    project_id: event.project_id,
    from: "foreman",
    to: "operator",
    direction: "event_to_operator",
    body: eventInboxBody(event),
    created_at: event.occurred_at,
    source: "event",
    event_type: event.event_type ?? event.type,
  }));
}

function eventInboxBody(event: Record<string, unknown>): string {
  const type = String(event.event_type ?? event.type ?? "Event");
  const payload = event.payload && typeof event.payload === "object" ? event.payload as Record<string, unknown> : {};
  const phase = payload.phase_id ? ` ${payload.phase_id}` : "";
  const reason = payload.reason ?? payload.error;
  return `${type}${phase}${reason ? `: ${String(reason)}` : ""}`;
}

function mergeInbox(...args: unknown[]): Array<Record<string, unknown>> {
  const limit = typeof args.at(-1) === "number" ? args.pop() as number : 50;
  const all = (args as Array<unknown>)
    .flatMap((items) => Array.isArray(items) ? items : [])
    .filter((item): item is Record<string, unknown> => item !== null && typeof item === "object");
  const seen = new Set<string>();
  const deduped = [];
  for (const item of all) {
    const key = String(item.message_id ?? `${item.run_id}:${item.created_at}:${item.body}`);
    if (seen.has(key)) continue;
    seen.add(key);
    deduped.push(item);
  }
  return deduped
    .sort((a, b) => String(b.created_at ?? "").localeCompare(String(a.created_at ?? "")))
    .slice(0, limit);
}

function isMessageUpdateLog(entry: unknown): boolean {
  const record = entry && typeof entry === "object" ? entry as Record<string, unknown> : null;
  return record?.type === "message_update" || record?.stream === "message_update" || record?.sub_type === "message_update";
}

export function tailRunLogs(logs: unknown, limit: number, view: "compact" | "plain" | "raw" = "compact"): unknown {
  const filterNoise = view === "plain";
  if (Array.isArray(logs)) {
    const entries = filterNoise ? logs.filter((entry) => !isMessageUpdateLog(entry)) : logs;
    return entries.slice(-limit);
  }
  if (logs && typeof logs === "object") {
    const record = logs as Record<string, unknown>;
    if (Array.isArray(record.entries)) {
      const entries = filterNoise ? record.entries.filter((entry) => !isMessageUpdateLog(entry)) : record.entries;
      return { ...record, mode: view, entries: entries.slice(-limit), tailed: entries.length > limit, total_entries: entries.length };
    }
  }
  return logs;
}
