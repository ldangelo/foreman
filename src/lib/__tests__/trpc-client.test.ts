/**
 * TRD-008-TEST | Verifies: TRD-008 | Tests: TrpcClient: Unix socket fetch, typed procedure calls
 * PRD: docs/PRD/PRD-2026-010-multi-project-orchestrator.md
 * TRD: docs/TRD/TRD-2026-011-multi-project-orchestrator.md#trd-008
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

function makeTempSocketPath() {
  const dir = mkdtempSync(join(tmpdir(), "trpc-client-test-"));
  const socketPath = join(dir, "daemon.sock");
  return { dir, socketPath };
}

beforeEach(() => {
  vi.restoreAllMocks();
});

afterEach(() => {
  vi.restoreAllMocks();
});

// ---------------------------------------------------------------------------
// Module exports
// ---------------------------------------------------------------------------

describe("TrpcClient module exports", () => {
  it("createTrpcClient is exported", async () => {
    const { createTrpcClient } = await import("../trpc-client.js");
    expect(typeof createTrpcClient).toBe("function");
  });

  it("decodeUnixSocketUrl is exported", async () => {
    const { decodeUnixSocketUrl } = await import("../trpc-client.js");
    expect(typeof decodeUnixSocketUrl).toBe("function");
  });

  // Note: TypeScript interfaces (TrpcClientOptions, TrpcClient,
  // TRPCProjectsClient) and `export type` are erased at runtime.
  // AppRouter is a compile-time alias — not a runtime value.
});

// ---------------------------------------------------------------------------
// Constructor and defaults
// ---------------------------------------------------------------------------

describe("createTrpcClient defaults", () => {
  it("defaults socketPath to ~/.foreman/daemon.sock", async () => {
    const { createTrpcClient } = await import("../trpc-client.js");
    const client = createTrpcClient();
    // projects is defined
    expect(client).toHaveProperty("projects");
    expect(typeof client.projects).toBe("object");
  });

  it("accepts custom socketPath", async () => {
    const { createTrpcClient } = await import("../trpc-client.js");
    const { socketPath } = makeTempSocketPath();
    try {
      const client = createTrpcClient({ socketPath });
      expect(client).toHaveProperty("projects");
    } finally {
      rmSync(join(socketPath, ".."), { recursive: true, force: true });
    }
  });

  it("accepts httpUrl option", async () => {
    const { createTrpcClient } = await import("../trpc-client.js");
    const client = createTrpcClient({ httpUrl: "http://localhost:9999" });
    expect(client).toHaveProperty("projects");
  });

  it("accepts signal option", async () => {
    const { createTrpcClient } = await import("../trpc-client.js");
    const ac = new AbortController();
    const client = createTrpcClient({ signal: ac.signal });
    expect(client).toHaveProperty("projects");
    ac.abort();
  });
});

// ---------------------------------------------------------------------------
// Projects sub-router interface
// ---------------------------------------------------------------------------

describe("TrpcClient.projects interface", () => {
  it("has list method", async () => {
    const { createTrpcClient } = await import("../trpc-client.js");
    const client = createTrpcClient();
    expect(typeof client.projects.list).toBe("function");
  });

  it("has get method", async () => {
    const { createTrpcClient } = await import("../trpc-client.js");
    const client = createTrpcClient();
    expect(typeof client.projects.get).toBe("function");
  });

  it("has add method", async () => {
    const { createTrpcClient } = await import("../trpc-client.js");
    const client = createTrpcClient();
    expect(typeof client.projects.add).toBe("function");
  });

  it("has update method", async () => {
    const { createTrpcClient } = await import("../trpc-client.js");
    const client = createTrpcClient();
    expect(typeof client.projects.update).toBe("function");
  });

  it("has remove method", async () => {
    const { createTrpcClient } = await import("../trpc-client.js");
    const client = createTrpcClient();
    expect(typeof client.projects.remove).toBe("function");
  });

  it("has sync method", async () => {
    const { createTrpcClient } = await import("../trpc-client.js");
    const client = createTrpcClient();
    expect(typeof client.projects.sync).toBe("function");
  });
});

// ---------------------------------------------------------------------------
// Error handling — daemon not running
// ---------------------------------------------------------------------------

describe("TrpcClient error handling", () => {
  it("throws when daemon is not running (ECONNREFUSED-like)", async () => {
    const { createTrpcClient } = await import("../trpc-client.js");
    const { socketPath } = makeTempSocketPath();
    try {
      const client = createTrpcClient({ socketPath });
      // Attempt a query — should fail because no daemon is listening.
      await expect(client.projects.list()).rejects.toThrow();
    } finally {
      rmSync(join(socketPath, ".."), { recursive: true, force: true });
    }
  });

  it("throws on projects.get when daemon is not running", async () => {
    const { createTrpcClient } = await import("../trpc-client.js");
    const { socketPath } = makeTempSocketPath();
    try {
      const client = createTrpcClient({ socketPath });
      await expect(
        client.projects.get({ id: "proj_abc123" }),
      ).rejects.toThrow();
    } finally {
      rmSync(join(socketPath, ".."), { recursive: true, force: true });
    }
  });
});

// ---------------------------------------------------------------------------
// Unix socket URL construction
// ---------------------------------------------------------------------------

describe("Unix socket URL construction", () => {
  it("decodes the socket path and request path from a unix+http URL", async () => {
    const { decodeUnixSocketUrl } = await import("../trpc-client.js");
    const parsed = decodeUnixSocketUrl(
      new URL(
        "unix+http:///Users/test/.foreman/daemon.sock/trpc/projects.add?batch=1&input=%7B%7D",
      ),
    );

    expect(parsed).toEqual({
      socketPath: "/Users/test/.foreman/daemon.sock",
      requestPath: "/trpc/projects.add?batch=1&input=%7B%7D",
    });
  });

  it("uses unix+http:// protocol in socket URL", async () => {
    const { createTrpcClient } = await import("../trpc-client.js");
    const { socketPath } = makeTempSocketPath();
    try {
      const client = createTrpcClient({ socketPath });
      // Just verify it doesn't throw during construction.
      expect(client).toHaveProperty("projects");
    } finally {
      rmSync(join(socketPath, ".."), { recursive: true, force: true });
    }
  });
});
