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

	pi.on("session_start", async (_event, ctx) => {
		try {
			await registerDiscoveredTools(ctx);
		} catch (error) {
			ctx.ui.notify(`Foreman MCP unavailable at ${MCP_URL}: ${error instanceof Error ? error.message : String(error)}`, "warning");
		}
	});
}
