import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const HEADROOM_BIN = process.env.HEADROOM_BIN ?? "headroom";
const REQUEST_TIMEOUT_MS = Number(process.env.HEADROOM_MCP_TIMEOUT_MS ?? "30000");

type JsonRpcResponse = {
	jsonrpc?: string;
	id?: number;
	result?: any;
	error?: { code?: number; message?: string; data?: unknown };
};

function clamp(text: string, maxChars = 12000): string {
	if (text.length <= maxChars) return text;
	return `${text.slice(0, maxChars)}\n… [Headroom MCP output truncated: ${text.length - maxChars} chars omitted.]`;
}

function textFromMcpResult(response: JsonRpcResponse): string {
	const content = response.result?.content;
	if (Array.isArray(content)) {
		return clamp(content.map((item: any) => {
			if (item?.type === "text") return String(item.text ?? "");
			return JSON.stringify(item);
		}).join("\n"));
	}
	return clamp(JSON.stringify(response.result ?? response, null, 2));
}

function compactDetails(response: JsonRpcResponse): unknown {
	return response.result?.structuredContent ?? { ok: true, note: "full Headroom MCP response omitted from pi details" };
}

async function callHeadroomTool(name: string, args: Record<string, unknown>, signal?: AbortSignal): Promise<JsonRpcResponse> {
	return new Promise((resolve, reject) => {
		const child = spawn(HEADROOM_BIN, ["mcp", "serve"], {
			stdio: ["pipe", "pipe", "pipe"],
			env: process.env,
		});

		let nextId = 1;
		let initialized = false;
		let done = false;
		let stderr = "";
		const pending = new Map<number, (response: JsonRpcResponse) => void>();

		const cleanup = () => {
			child.kill("SIGTERM");
		};

		const finish = (fn: () => void) => {
			if (done) return;
			done = true;
			clearTimeout(timer);
			cleanup();
			fn();
		};

		const timer = setTimeout(() => {
			finish(() => reject(new Error(`Headroom MCP request timed out after ${REQUEST_TIMEOUT_MS}ms${stderr ? `: ${stderr.slice(-500)}` : ""}`)));
		}, REQUEST_TIMEOUT_MS);

		const abort = () => finish(() => reject(new Error("Headroom MCP request aborted")));
		signal?.addEventListener("abort", abort, { once: true });

		child.stderr.on("data", (chunk) => {
			stderr += String(chunk);
			if (stderr.length > 4000) stderr = stderr.slice(-4000);
		});

		child.on("error", (error) => finish(() => reject(error)));
		child.on("exit", (code) => {
			if (!done && code !== 0) finish(() => reject(new Error(`Headroom MCP exited ${code}${stderr ? `: ${stderr.slice(-800)}` : ""}`)));
		});

		const rl = createInterface({ input: child.stdout });
		rl.on("line", (line) => {
			let response: JsonRpcResponse;
			try {
				response = JSON.parse(line) as JsonRpcResponse;
			} catch {
				return;
			}
			if (typeof response.id === "number") pending.get(response.id)?.(response);
		});

		const send = (method: string, params: unknown): Promise<JsonRpcResponse> => {
			const id = nextId++;
			const request = { jsonrpc: "2.0", id, method, params };
			return new Promise((res) => {
				pending.set(id, res);
				child.stdin.write(`${JSON.stringify(request)}\n`);
			});
		};

		(async () => {
			const init = await send("initialize", {
				protocolVersion: "2024-11-05",
				capabilities: {},
				clientInfo: { name: "pi-headroom-extension", version: "1.0.0" },
			});
			if (init.error) throw new Error(init.error.message ?? "Headroom MCP initialize failed");
			initialized = true;
			child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized", params: {} })}\n`);
			const response = await send("tools/call", { name, arguments: args ?? {} });
			if (response.error) throw new Error(response.error.message ?? `Headroom MCP tool failed: ${name}`);
			finish(() => resolve(response));
		})().catch((error) => {
			finish(() => reject(new Error(`${error instanceof Error ? error.message : String(error)}${!initialized && stderr ? `: ${stderr.slice(-800)}` : ""}`)));
		});
	});
}

export default function headroomMcpExtension(pi: ExtensionAPI) {
	pi.registerTool({
		name: "headroom_compress",
		label: "Headroom Compress",
		description: "Compress large content with Headroom before reasoning over it. Returns compressed text and a retrieval hash.",
		promptSnippet: "Use headroom_compress for large logs, files, search output, or JSON when compression would save context.",
		parameters: {
			type: "object",
			properties: {
				content: { type: "string", description: "Text, JSON, logs, code, or tool output to compress." },
			},
			required: ["content"],
			additionalProperties: false,
		} as any,
		async execute(_toolCallId, params, signal) {
			const response = await callHeadroomTool("headroom_compress", params as Record<string, unknown>, signal);
			return { content: [{ type: "text", text: textFromMcpResult(response) }], details: compactDetails(response) };
		},
	});

	pi.registerTool({
		name: "headroom_retrieve",
		label: "Headroom Retrieve",
		description: "Retrieve original uncompressed Headroom content by hash, optionally filtered by query.",
		promptSnippet: "Use headroom_retrieve when a Headroom compression marker/hash must be expanded.",
		parameters: {
			type: "object",
			properties: {
				hash: { type: "string", description: "Hash key from headroom_compress or a compression marker." },
				query: { type: "string", description: "Optional search query to filter retrieved content." },
			},
			required: ["hash"],
			additionalProperties: false,
		} as any,
		async execute(_toolCallId, params, signal) {
			const response = await callHeadroomTool("headroom_retrieve", params as Record<string, unknown>, signal);
			return { content: [{ type: "text", text: textFromMcpResult(response) }], details: compactDetails(response) };
		},
	});

	pi.registerTool({
		name: "headroom_stats",
		label: "Headroom Stats",
		description: "Show Headroom compression statistics for this session.",
		parameters: { type: "object", properties: {}, additionalProperties: false } as any,
		async execute(_toolCallId, params, signal) {
			const response = await callHeadroomTool("headroom_stats", params as Record<string, unknown>, signal);
			return { content: [{ type: "text", text: textFromMcpResult(response) }], details: compactDetails(response) };
		},
	});

	pi.registerCommand("headroom-status", {
		description: "Show Headroom CLI/MCP status for this project",
		handler: async (_args, ctx) => {
			try {
				const response = await callHeadroomTool("headroom_stats", {});
				ctx.ui.notify(textFromMcpResult(response), "info");
			} catch (error) {
				ctx.ui.notify(`Headroom unavailable: ${error instanceof Error ? error.message : String(error)}`, "error");
			}
		},
	});
}
