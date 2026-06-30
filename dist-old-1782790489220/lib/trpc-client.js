/**
 * TrpcClient — typed tRPC client that connects to ForemanDaemon via Unix socket.
 *
 * Primary transport: Unix socket at ~/.foreman/daemon.sock
 * Fallback transport: localhost:3847 (HTTP)
 *
 * The daemon serves tRPC over HTTP through Fastify, so we use httpBatchLink
 * with a custom fetch implementation that connects via Unix socket.
 *
 * @module lib/trpc-client
 */
import { httpBatchLink, createTRPCUntypedClient } from "@trpc/client";
import * as http from "node:http";
import { join } from "node:path";
import { homedir } from "node:os";
import { foremanBackendMode } from "./backend-mode.js";
// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const DEFAULT_SOCKET_PATH = join(homedir(), ".foreman", "daemon.sock");
// ---------------------------------------------------------------------------
// Unix socket fetch
// ---------------------------------------------------------------------------
/**
 * Custom `fetch` implementation that routes requests over a Unix socket.
 *
 * Parses the URL as: `unix+http://<socket-path>/<tRpcPath>`
 * Extracts the socket path and the tRPC path, then uses Node's `http`
 * module to make the request over the Unix socket.
 *
 * Falls back to a regular HTTP fetch when the URL does not use the
 * `unix+http://` scheme.
 */
async function unixSocketFetch(input, init) {
    const url = input instanceof URL ? input : new URL(String(input));
    const isUnix = url.protocol === "unix+http:";
    if (!isUnix) {
        // Fall back to native fetch for HTTP URLs.
        return fetch(url, init);
    }
    const { socketPath, requestPath: trpcPath } = decodeUnixSocketUrl(url);
    const method = init?.method ?? "GET";
    const headers = buildHeaders(init?.headers);
    const body = init?.body != null
        ? typeof init.body === "string"
            ? init.body
            : init.body instanceof Uint8Array
                ? init.body
                : init.body instanceof ReadableStream
                    ? await readStreamBody(init.body)
                    : JSON.stringify(init.body)
        : undefined;
    return new Promise((resolve, reject) => {
        const options = {
            socketPath,
            path: trpcPath,
            method,
            headers,
        };
        const req = http.request(options, (res) => {
            // Collect response body.
            const chunks = [];
            res.on("data", (chunk) => chunks.push(chunk));
            res.on("end", () => {
                const bodyBuffer = Buffer.concat(chunks);
                const responseHeaders = {};
                for (const [k, v] of Object.entries(res.headers)) {
                    if (v !== undefined) {
                        responseHeaders[k] = Array.isArray(v) ? v.join(", ") : v;
                    }
                }
                resolve(new Response(bodyBuffer, {
                    status: res.statusCode ?? 200,
                    headers: responseHeaders,
                }));
            });
        });
        req.on("error", (err) => reject(err));
        if (body !== undefined) {
            if (typeof body === "string") {
                req.end(body, "utf-8");
            }
            else if (body instanceof Uint8Array) {
                req.end(body);
            }
            else {
                req.end();
            }
        }
        else {
            req.end();
        }
    });
}
export function decodeUnixSocketUrl(url) {
    // Format: unix+http:///<absolute-socket-path>/<tRPC-path>
    // e.g. unix+http:///home/user/.foreman/daemon.sock/projects.list?batch=1
    const socketMarker = ".sock";
    const socketEnd = url.pathname.indexOf(socketMarker);
    if (socketEnd === -1) {
        throw new Error(`Invalid unix socket URL (missing ${socketMarker}): ${url.href}`);
    }
    const socketPath = url.pathname.slice(0, socketEnd + socketMarker.length);
    const rawRequestPath = url.pathname.slice(socketEnd + socketMarker.length) || "/";
    return {
        socketPath,
        requestPath: `${rawRequestPath}${url.search}`,
    };
}
async function readStreamBody(stream) {
    const reader = stream.getReader();
    const chunks = [];
    let totalLength = 0;
    while (true) {
        const { done, value } = await reader.read();
        if (done)
            break;
        if (!value)
            continue;
        chunks.push(value);
        totalLength += value.length;
    }
    const body = new Uint8Array(totalLength);
    let offset = 0;
    for (const chunk of chunks) {
        body.set(chunk, offset);
        offset += chunk.length;
    }
    return body;
}
/** Convert HeadersInit to a flat Record<string, string>. */
function buildHeaders(headers) {
    if (!headers)
        return {};
    if (headers instanceof Headers) {
        const out = {};
        headers.forEach((v, k) => {
            out[k] = v;
        });
        return out;
    }
    if (Array.isArray(headers)) {
        return Object.fromEntries(headers);
    }
    return headers;
}
/**
 * Create a tRPC client that connects to ForemanDaemon.
 *
 * @example
 * const client = createTrpcClient();
 * const projects = await client.projects.list({ status: "active" });
 */
export function createTrpcClient(options = {}) {
    if (!options.httpUrl && !options.socketPath && foremanBackendMode() === "elixir") {
        throw new Error("Elixir backend parity gap: this command still uses the legacy Node daemon tRPC API. Use an Elixir-routed command or set FOREMAN_BACKEND=node for explicit legacy operation.");
    }
    const socketPath = options.socketPath ?? DEFAULT_SOCKET_PATH;
    // Build the Unix-socket URL for httpBatchLink.
    // Format: unix+http://<socket-path>/trpc
    const socketUrl = `unix+http://${socketPath}/trpc`;
    const untypedClient = createTRPCUntypedClient({
        links: [
            httpBatchLink({
                url: socketUrl,
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                fetch: unixSocketFetch,
            }),
        ],
    });
    // Return a typed interface over the untyped client.
    return {
        projects: {
            list: (input) => untypedClient.query("projects.list", input),
            get: (input) => untypedClient.query("projects.get", input),
            add: (input) => untypedClient.mutation("projects.add", input),
            update: (input) => untypedClient.mutation("projects.update", input),
            remove: (input) => untypedClient.mutation("projects.remove", input),
            sync: (input) => untypedClient.mutation("projects.sync", input),
            stats: (input) => untypedClient.query("projects.stats", input),
            listNeedsHuman: (input) => untypedClient.query("projects.listNeedsHuman", input),
        },
        tasks: {
            list: (input) => untypedClient.query("tasks.list", input),
            get: (input) => untypedClient.query("tasks.get", input),
            create: (input) => untypedClient.mutation("tasks.create", input),
            update: (input) => untypedClient.mutation("tasks.update", input),
            delete: (input) => untypedClient.mutation("tasks.delete", input),
            addNote: (input) => untypedClient.mutation("tasks.addNote", input),
            listNotes: (input) => untypedClient.query("tasks.listNotes", input),
            claim: (input) => untypedClient.mutation("tasks.claim", input),
            approve: (input) => untypedClient.mutation("tasks.approve", input),
            close: (input) => untypedClient.mutation("tasks.close", input),
            reset: (input) => untypedClient.mutation("tasks.reset", input),
            retry: (input) => untypedClient.mutation("tasks.retry", input),
            addDependency: (input) => untypedClient.mutation("tasks.addDependency", input),
            listDependencies: (input) => untypedClient.query("tasks.listDependencies", input),
            removeDependency: (input) => untypedClient.mutation("tasks.removeDependency", input),
            getPrState: (input) => untypedClient.query("tasks.getPrState", input),
        },
        runs: {
            create: (input) => untypedClient.mutation("runs.create", input),
            list: (input) => untypedClient.query("runs.list", input),
            listActive: (input) => untypedClient.query("runs.listActive", input),
            get: (input) => untypedClient.query("runs.get", input),
            getProgress: (input) => untypedClient.query("runs.getProgress", input),
            updateStatus: (input) => untypedClient.mutation("runs.updateStatus", input),
            finalize: (input) => untypedClient.mutation("runs.finalize", input),
            logEvent: (input) => untypedClient.mutation("runs.logEvent", input),
            listEvents: (input) => untypedClient.query("runs.listEvents", input),
            sendMessage: (input) => untypedClient.mutation("runs.sendMessage", input),
            listMessages: (input) => untypedClient.query("runs.listMessages", input),
        },
        mail: {
            send: (input) => untypedClient.mutation("mail.send", input),
            list: (input) => untypedClient.query("mail.list", input),
            listGlobal: (input) => untypedClient.query("mail.listGlobal", input),
            markRead: (input) => untypedClient.mutation("mail.markRead", input),
            markAllRead: (input) => untypedClient.mutation("mail.markAllRead", input),
            delete: (input) => untypedClient.mutation("mail.delete", input),
        },
        jira: {
            configure: (input) => untypedClient.mutation("jira.configure", input),
            getStatus: (input) => untypedClient.query("jira.getStatus", input),
            testConnection: (input) => untypedClient.query("jira.testConnection", input),
            enableWebhook: (input) => untypedClient.mutation("jira.enableWebhook", input),
            disableWebhook: (input) => untypedClient.mutation("jira.disableWebhook", input),
        },
    };
}
//# sourceMappingURL=trpc-client.js.map