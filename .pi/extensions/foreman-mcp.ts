import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const DEFAULT_URL = "http://127.0.0.1:4777/mcp";
const MCP_URL = process.env.FOREMAN_MCP_URL ?? DEFAULT_URL;
const MCP_AUTH_TOKEN = process.env.FOREMAN_MCP_AUTH_TOKEN;

type JsonRpcResponse = {
	jsonrpc?: string;
	id?: number;
	result?: any;
	error?: { code?: number; message?: string; data?: unknown };
};

type McpTool = {
	name: string;
	description?: string;
	inputSchema?: Record<string, unknown>;
};

function piToolName(mcpName: string): string {
	return mcpName.replace(/[^a-zA-Z0-9_]/g, "_").replace(/_+/g, "_").toLowerCase();
}

function normalizeSchema(schema: unknown): Record<string, unknown> {
	if (!schema || typeof schema !== "object") {
		return { type: "object", properties: {}, additionalProperties: false };
	}
	const raw = schema as Record<string, unknown>;
	return {
		type: "object",
		properties: {},
		additionalProperties: false,
		...raw,
	};
}

async function rpc(method: string, params: unknown, signal?: AbortSignal): Promise<JsonRpcResponse> {
	const headers: Record<string, string> = { "content-type": "application/json" };
	if (MCP_AUTH_TOKEN) headers.authorization = `Bearer ${MCP_AUTH_TOKEN}`;

	const response = await fetch(MCP_URL, {
		method: "POST",
		headers,
		body: JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method, params }),
		signal,
	});

	const text = await response.text();
	if (!response.ok) {
		throw new Error(`Foreman MCP HTTP ${response.status}: ${text.slice(0, 500)}`);
	}
	return JSON.parse(text) as JsonRpcResponse;
}

async function listTools(signal?: AbortSignal): Promise<McpTool[]> {
	const response = await rpc("tools/list", {}, signal);
	if (response.error) throw new Error(response.error.message ?? "Foreman MCP tools/list failed");
	return (response.result?.tools ?? []) as McpTool[];
}

async function callTool(name: string, args: Record<string, unknown>, signal?: AbortSignal): Promise<JsonRpcResponse> {
	const response = await rpc("tools/call", { name, arguments: args ?? {} }, signal);
	if (response.error) throw new Error(response.error.message ?? `Foreman MCP tool failed: ${name}`);
	return response;
}

function textFromMcpResult(response: JsonRpcResponse): string {
	const content = response.result?.content;
	if (Array.isArray(content) && content.length > 0) {
		return content
			.map((item: any) => {
				if (item?.type === "text") return String(item.text ?? "");
				return JSON.stringify(item);
			})
			.join("\n");
	}
	return JSON.stringify(response.result ?? response, null, 2);
}

function structured(response: JsonRpcResponse): any {
	return response.result?.structuredContent ?? tryJson(textFromMcpResult(response));
}

function tryJson(text: string): any {
	try {
		return JSON.parse(text);
	} catch {
		return text;
	}
}

function firstLine(value: unknown, max = 110): string {
	const line = String(value ?? "").replace(/\s+/g, " ").trim();
	return line.length > max ? `${line.slice(0, max - 1)}…` : line;
}

function parseArgs(args: string): Record<string, string | boolean> {
	const out: Record<string, string | boolean> = {};
	const parts = args.trim().match(/(?:[^\s"]+|"[^"]*")+/g) ?? [];
	let positional = 0;
	for (let index = 0; index < parts.length; index += 1) {
		const part = parts[index].replace(/^"|"$/g, "");
		if (part.startsWith("--")) {
			const [rawKey, inlineValue] = part.slice(2).split("=", 2);
			const next = parts[index + 1]?.replace(/^"|"$/g, "");
			if (inlineValue !== undefined) out[rawKey] = inlineValue;
			else if (next && !next.startsWith("--")) {
				out[rawKey] = next;
				index += 1;
			} else out[rawKey] = true;
		} else {
			out[String(positional)] = part;
			positional += 1;
		}
	}
	return out;
}

function numberArg(value: unknown, fallback: number): number {
	const n = Number(value);
	return Number.isFinite(n) && n > 0 ? n : fallback;
}

function taskId(task: any): string {
	return task?.task_id ?? task?.id ?? "<unknown>";
}

function runId(run: any): string {
	return run?.run_id ?? run?.id ?? "<unknown>";
}

function formatTaskList(tasks: any[], heading: string): string {
	if (!tasks.length) return `${heading}\n(no tasks)`;
	return [heading, ...tasks.map((task) => {
		const type = task.task_type ?? task.type ?? "task";
		const priority = task.priority ?? "?";
		return `- ${taskId(task)} [${task.status ?? "?"}, ${type}, p${priority}] ${firstLine(task.title)}`;
	})].join("\n");
}

function formatRuns(runs: any[], heading = "Foreman runs"): string {
	if (!runs.length) return `${heading}\n(no runs)`;
	return [heading, ...runs.map((run) => `- ${runId(run)} [${run.status ?? "?"}] task=${run.task_id ?? "?"} phase=${run.current_phase ?? "-"}`)].join("\n");
}

function formatInbox(messages: any[], heading = "Foreman inbox"): string {
	if (!messages.length) return `${heading}\n(no messages)`;
	return [heading, ...messages.map((msg) => `- ${msg.created_at ?? ""} ${msg.run_id ?? "-"} ${msg.from ?? "?"}->${msg.to ?? "?"}: ${firstLine(msg.body ?? msg.message ?? msg.summary)}`)].join("\n");
}

function formatEvents(events: any[], heading = "Foreman events"): string {
	if (!events.length) return `${heading}\n(no events)`;
	return [heading, ...events.map((event) => `- ${event.occurred_at ?? ""} ${event.type ?? event.event_type ?? "?"} run=${event.run_id ?? "-"} task=${event.task_id ?? "-"}`)].join("\n");
}

function summarizeHealth(data: any): string {
	return [
		"Foreman health",
		`- MCP: ${data?.mcp?.ok ? "ok" : "fail"}`,
		`- Elixir: ${data?.elixir?.ok ? "ok" : "fail"}`,
		`- active_projects: ${data?.elixir?.body?.active_projects?.length ?? "?"}`,
	].join("\n");
}

function show(pi: ExtensionAPI, content: string, details?: unknown): void {
	pi.sendMessage({ customType: "foreman", content, display: true, details });
}

export default function foremanMcpExtension(pi: ExtensionAPI) {
	const registered = new Set<string>();

	async function registerDiscoveredTools(ctx?: any): Promise<number> {
		const tools = await listTools();
		let count = 0;

		for (const tool of tools) {
			const name = piToolName(tool.name);
			if (registered.has(name)) continue;
			registered.add(name);
			count += 1;

			pi.registerTool({
				name,
				label: tool.name,
				description: tool.description ?? `Call Foreman MCP tool ${tool.name}`,
				promptSnippet: `Call Foreman MCP tool ${tool.name}`,
				promptGuidelines: [`Use ${name} for Foreman MCP ${tool.name} operations.`],
				parameters: normalizeSchema(tool.inputSchema) as any,
				async execute(_toolCallId, params, signal) {
					const response = await callTool(tool.name, params as Record<string, unknown>, signal);
					return {
						content: [{ type: "text", text: textFromMcpResult(response) }],
						details: { mcpTool: tool.name, response },
					};
				},
			});
		}

		ctx?.ui?.notify?.(`Foreman MCP: registered ${count} new tool(s)`, "info");
		return count;
	}

	pi.registerTool({
		name: "foreman_mcp_refresh",
		label: "Foreman MCP Refresh",
		description: "Discover and register Foreman MCP tools from the local Foreman MCP HTTP server.",
		promptSnippet: "Refresh/register Foreman MCP tools",
		promptGuidelines: ["Use foreman_mcp_refresh if Foreman MCP tools are missing after server restart."],
		parameters: { type: "object", properties: {}, additionalProperties: false } as any,
		async execute(_toolCallId, _params, signal, _onUpdate, ctx) {
			const count = await registerDiscoveredTools(ctx);
			return {
				content: [{ type: "text", text: `Foreman MCP refresh OK. Registered ${count} new tool(s). URL: ${MCP_URL}` }],
				details: { url: MCP_URL, registeredNew: count },
			};
		},
	});

	pi.registerTool({
		name: "foreman_mcp_call",
		label: "Foreman MCP Call",
		description: "Generic fallback caller for any Foreman MCP tool by original MCP name.",
		promptSnippet: "Call a Foreman MCP tool by original name",
		promptGuidelines: ["Use foreman_mcp_call only when a specific foreman_* MCP bridge tool is unavailable."],
		parameters: {
			type: "object",
			properties: {
				name: { type: "string", description: "Original MCP tool name, e.g. foreman.health" },
				arguments: { description: "MCP tool arguments object" },
			},
			required: ["name"],
			additionalProperties: false,
		} as any,
		async execute(_toolCallId, params, signal) {
			const response = await callTool(params.name, params.arguments ?? {}, signal);
			return {
				content: [{ type: "text", text: textFromMcpResult(response) }],
				details: { mcpTool: params.name, response },
			};
		},
	});

	pi.registerCommand("foreman-mcp-refresh", {
		description: "Discover and register Foreman MCP tools",
		handler: async (_args, ctx) => {
			try {
				await registerDiscoveredTools(ctx);
			} catch (error) {
				ctx.ui.notify(`Foreman MCP refresh failed: ${error instanceof Error ? error.message : String(error)}`, "error");
			}
		},
	});

	pi.registerCommand("foreman-health", {
		description: "Show Foreman MCP/Elixir health",
		handler: async (_args, ctx) => {
			try {
				const data = structured(await callTool("foreman.health", {}));
				show(pi, summarizeHealth(data), data);
			} catch (error) {
				ctx.ui.notify(`Foreman health failed: ${error instanceof Error ? error.message : String(error)}`, "error");
			}
		},
	});

	pi.registerCommand("foreman-smoke", {
		description: "Show Foreman smoke status (usage: /foreman-smoke [project] [limit])",
		handler: async (args, ctx) => {
			try {
				const parsed = parseArgs(args);
				const project = parsed.project ?? parsed["0"] ?? "foreman";
				const limit = numberArg(parsed.limit ?? parsed["1"], 12);
				const data = structured(await callTool("foreman.smoke.status", { project, limit }));
				const lines = [
					"Foreman smoke",
					`- health: ${data?.health?.ok ? "ok" : "fail"}`,
					`- scheduler auto_tick: ${data?.scheduler?.scheduler?.auto_tick ?? "?"}`,
					`- active_count: ${data?.active_count ?? 0}`,
					formatTaskList(data?.recent_open ?? [], "recent open"),
				];
				show(pi, lines.join("\n"), data);
			} catch (error) {
				ctx.ui.notify(`Foreman smoke failed: ${error instanceof Error ? error.message : String(error)}`, "error");
			}
		},
	});

	pi.registerCommand("foreman-tasks", {
		description: "List Foreman tasks (usage: /foreman-tasks [status=open|closed|all] [limit])",
		getArgumentCompletions: (prefix: string) => ["open", "closed", "all", "--status", "--limit", "--project"].filter((value) => value.startsWith(prefix)).map((value) => ({ value, label: value })),
		handler: async (args, ctx) => {
			try {
				const parsed = parseArgs(args);
				const status = String(parsed.status ?? parsed["0"] ?? "open");
				const limit = numberArg(parsed.limit ?? parsed["1"], 50);
				const project = parsed.project ?? "foreman";
				const toolArgs: Record<string, unknown> = { project, limit };
				if (status !== "all") toolArgs.status = [status];
				const tasks = structured(await callTool("foreman.tasks.list", toolArgs));
				show(pi, formatTaskList(Array.isArray(tasks) ? tasks : [], `Foreman tasks (${status})`), tasks);
			} catch (error) {
				ctx.ui.notify(`Foreman tasks failed: ${error instanceof Error ? error.message : String(error)}`, "error");
			}
		},
	});

	pi.registerCommand("foreman-task", {
		description: "Show one Foreman task (usage: /foreman-task <task-id>)",
		handler: async (args, ctx) => {
			const id = args.trim().split(/\s+/)[0];
			if (!id) return ctx.ui.notify("Usage: /foreman-task <task-id>", "warning");
			try {
				const task = structured(await callTool("foreman.tasks.get", { task_id: id }));
				if (!task) return show(pi, `Foreman task ${id}\n(not found)`);
				show(pi, [
					`Foreman task ${taskId(task)}`,
					`- status: ${task.status ?? "?"}`,
					`- type: ${task.task_type ?? task.type ?? "?"}`,
					`- priority: ${task.priority ?? "?"}`,
					`- run: ${task.run_id ?? "-"}`,
					`- title: ${task.title ?? ""}`,
					`- desc: ${firstLine(task.description, 500)}`,
				].join("\n"), task);
			} catch (error) {
				ctx.ui.notify(`Foreman task failed: ${error instanceof Error ? error.message : String(error)}`, "error");
			}
		},
	});

	pi.registerCommand("foreman-runs", {
		description: "List Foreman runs (usage: /foreman-runs [status|all] [limit])",
		handler: async (args, ctx) => {
			try {
				const parsed = parseArgs(args);
				const status = String(parsed.status ?? parsed["0"] ?? "all");
				const limit = numberArg(parsed.limit ?? parsed["1"], 20);
				const toolArgs: Record<string, unknown> = { project: parsed.project ?? "foreman", limit };
				if (status !== "all") toolArgs.status = [status];
				const runs = structured(await callTool("foreman.runs.list", toolArgs));
				show(pi, formatRuns(Array.isArray(runs) ? runs : [], `Foreman runs (${status})`), runs);
			} catch (error) {
				ctx.ui.notify(`Foreman runs failed: ${error instanceof Error ? error.message : String(error)}`, "error");
			}
		},
	});

	pi.registerCommand("foreman-inbox", {
		description: "List Foreman inbox messages (usage: /foreman-inbox [run-id] [limit])",
		handler: async (args, ctx) => {
			try {
				const parsed = parseArgs(args);
				const first = String(parsed["0"] ?? "");
				const limit = numberArg(parsed.limit ?? parsed["1"], 20);
				const toolArgs: Record<string, unknown> = { limit };
				if (parsed.project || !first) toolArgs.project = parsed.project ?? "foreman";
				if (parsed.run_id || first.startsWith("run-") || first.length > 20) toolArgs.run_id = parsed.run_id ?? first;
				const messages = structured(await callTool("foreman.inbox.list", toolArgs));
				show(pi, formatInbox(Array.isArray(messages) ? messages : []), messages);
			} catch (error) {
				ctx.ui.notify(`Foreman inbox failed: ${error instanceof Error ? error.message : String(error)}`, "error");
			}
		},
	});

	pi.registerCommand("foreman-events", {
		description: "List Foreman lifecycle events (usage: /foreman-events [run-id] [limit])",
		handler: async (args, ctx) => {
			try {
				const parsed = parseArgs(args);
				const first = String(parsed["0"] ?? "");
				const limit = numberArg(parsed.limit ?? parsed["1"], 20);
				const toolArgs: Record<string, unknown> = { limit };
				if (parsed.project || !first) toolArgs.project = parsed.project ?? "foreman";
				if (parsed.run_id || first.startsWith("run-") || first.length > 20) toolArgs.run_id = parsed.run_id ?? first;
				const events = structured(await callTool("foreman.events.list", toolArgs));
				show(pi, formatEvents(Array.isArray(events) ? events : []), events);
			} catch (error) {
				ctx.ui.notify(`Foreman events failed: ${error instanceof Error ? error.message : String(error)}`, "error");
			}
		},
	});

	pi.registerCommand("foreman-scheduler", {
		description: "Show Foreman scheduler status",
		handler: async (_args, ctx) => {
			try {
				const data = structured(await callTool("foreman.scheduler.status", {}));
				const scheduler = data?.scheduler ?? data;
				show(pi, [
					"Foreman scheduler",
					`- auto_tick: ${scheduler?.auto_tick ?? "?"}`,
					`- max_concurrent: ${scheduler?.max_concurrent ?? "?"}`,
					`- active_runs: ${scheduler?.last_tick?.active_runs ?? 0}`,
					`- stale_active_runs: ${scheduler?.last_tick?.stale_active_runs?.length ?? 0}`,
				].join("\n"), data);
			} catch (error) {
				ctx.ui.notify(`Foreman scheduler failed: ${error instanceof Error ? error.message : String(error)}`, "error");
			}
		},
	});

	pi.registerCommand("foreman-tick", {
		description: "Run one Foreman scheduler tick",
		handler: async (_args, ctx) => {
			try {
				const data = structured(await callTool("foreman.scheduler.tick", {}));
				const scheduler = data?.scheduler ?? data;
				show(pi, [
					"Foreman scheduler tick",
					`- claimed: ${scheduler?.claimed?.length ?? 0}`,
					`- skipped: ${scheduler?.skipped?.length ?? 0}`,
					`- active_runs: ${scheduler?.active_runs ?? "?"}`,
				].join("\n"), data);
			} catch (error) {
				ctx.ui.notify(`Foreman tick failed: ${error instanceof Error ? error.message : String(error)}`, "error");
			}
		},
	});

	pi.on("session_start", async (_event, ctx) => {
		try {
			await registerDiscoveredTools(ctx);
		} catch (error) {
			ctx.ui.notify(`Foreman MCP unavailable at ${MCP_URL}: ${error instanceof Error ? error.message : String(error)}`, "warning");
		}
	});
}
