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

import { httpBatchLink } from "@trpc/client";
import { createTRPCUntypedClient } from "@trpc/client";
import { join } from "node:path";
import { homedir } from "node:os";
import { appRouter } from "../daemon/router.js";

/** AppRouter type — use `typeof appRouter` to extract. */
export type AppRouter = typeof appRouter;

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
async function unixSocketFetch(
  input: RequestInfo | URL,
  init?: RequestInit,
): Promise<Response> {
  const url = input instanceof URL ? input : new URL(String(input));
  const isUnix = url.protocol === "unix+http:";

  if (!isUnix) {
    // Fall back to native fetch for HTTP URLs.
    return fetch(url, init);
  }

  // Decode socket path and tRPC path from the URL.
  // Format: unix+http://<socket-path>/<tRPC-path>
  // e.g.  unix+http:///home/user/.foreman/daemon.sock/trpc/projects.list/batch
  const socketPath = url.hostname + url.pathname.split("/")[0];
  const trpcPath = "/" + url.pathname.split("/").slice(1).join("/");
  const method = (init?.method as string | undefined) ?? "GET";
  const headers = buildHeaders(init?.headers);
  const body =
    init?.body != null
      ? typeof init.body === "string"
        ? init.body
        : init.body instanceof Uint8Array
          ? init.body
          : init.body instanceof ReadableStream
            ? init.body
            : JSON.stringify(init.body)
      : undefined;

  return new Promise<Response>((resolve, reject) => {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const http = require("http") as typeof import("node:http");

    const options: import("node:http").RequestOptions = {
      socketPath,
      path: trpcPath,
      method,
      headers,
    };

    const req = http.request(options, (res) => {
      // Collect response body.
      const chunks: Buffer[] = [];
      res.on("data", (chunk: Buffer) => chunks.push(chunk));
      res.on("end", () => {
        const bodyBuffer = Buffer.concat(chunks);
        const responseHeaders: Record<string, string> = {};
        for (const [k, v] of Object.entries(res.headers)) {
          if (v !== undefined) {
            responseHeaders[k] = Array.isArray(v) ? v.join(", ") : v;
          }
        }

        resolve(
          new Response(bodyBuffer, {
            status: res.statusCode ?? 200,
            headers: responseHeaders,
          }),
        );
      });
    });

    req.on("error", (err) => reject(err));

    if (body !== undefined) {
      if (typeof body === "string") {
        req.write(body, "utf-8");
      } else if (body instanceof Uint8Array) {
        req.write(body);
      } else {
        // ReadableStream — not supported for Unix socket HTTP without streaming.
        req.end();
      }
    } else {
      req.end();
    }
  });
}

/** Convert HeadersInit to a flat Record<string, string>. */
function buildHeaders(
  headers: HeadersInit | null | undefined,
): Record<string, string> {
  if (!headers) return {};
  if (headers instanceof Headers) {
    const out: Record<string, string> = {};
    headers.forEach((v, k) => {
      out[k] = v;
    });
    return out;
  }
  if (Array.isArray(headers)) {
    return Object.fromEntries(headers as [string, string][]);
  }
  return headers as Record<string, string>;
}

// ---------------------------------------------------------------------------
// TrpcClient
// ---------------------------------------------------------------------------

export interface TrpcClientOptions {
  /** Path to the Unix socket. Defaults to ~/.foreman/daemon.sock. */
  socketPath?: string;
  /** HTTP fallback URL when Unix socket is not available. */
  httpUrl?: string;
  /** Abort signal to cancel in-flight requests. */
  signal?: AbortSignal;
}

/** A fully-typed tRPC client for ForemanDaemon. */
export interface TrpcClient {
  /** Typed proxy to the daemon's procedures. */
  readonly projects: TRPCProjectsClient;
}

/** Projects sub-router client. */
export interface TRPCProjectsClient {
  list(input?: {
    status?: "active" | "paused" | "archived";
    search?: string;
  }): Promise<unknown>;
  get(input: { id: string }): Promise<unknown>;
  add(input: {
    githubUrl: string;
    name?: string;
    defaultBranch?: string;
    status?: "active" | "paused" | "archived";
  }): Promise<unknown>;
  update(
    input: {
      id: string;
      updates: {
        name?: string;
        path?: string;
        status?: "active" | "paused" | "archived";
      };
    },
  ): Promise<unknown>;
  remove(input: {
    id: string;
    force?: boolean;
  }): Promise<unknown>;
  sync(input: { id: string }): Promise<unknown>;
}

/**
 * Create a tRPC client that connects to ForemanDaemon.
 *
 * @example
 * const client = createTrpcClient();
 * const projects = await client.projects.list({ status: "active" });
 */
export function createTrpcClient(
  options: TrpcClientOptions = {},
): TrpcClient {
  const socketPath = options.socketPath ?? DEFAULT_SOCKET_PATH;

  // Build the Unix-socket URL for httpBatchLink.
  // Format: unix+http://<socket-path>/
  const socketUrl = `unix+http://${socketPath}/`;

  const untypedClient = createTRPCUntypedClient<AppRouter>({
    links: [
      httpBatchLink({
        url: socketUrl,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        fetch: unixSocketFetch as any,
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
    },
  };
}
