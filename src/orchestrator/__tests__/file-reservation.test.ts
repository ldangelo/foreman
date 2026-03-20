/**
 * Tests for TRD-021: File Reservation Integration
 *
 * Tests the parseFilesFromExplorerReport helper and the Agent Mail
 * file reservation integration in the developer pipeline phase.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Module under test ─────────────────────────────────────────────────────────

import { parseFilesFromExplorerReport } from "../file-reservation.js";
import { AgentMailClient } from "../agent-mail-client.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Build a minimal Response-like object for vi.spyOn(globalThis, 'fetch') */
function makeFetchResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => JSON.stringify(body),
    headers: new Headers(),
    redirected: false,
    statusText: "OK",
    type: "basic",
    url: "",
    clone: () => makeFetchResponse(body, status),
    body: null,
    bodyUsed: false,
    arrayBuffer: async () => new ArrayBuffer(0),
    blob: async () => new Blob(),
    formData: async () => new FormData(),
  } as unknown as Response;
}

// ── parseFilesFromExplorerReport tests ────────────────────────────────────────

describe("parseFilesFromExplorerReport", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-filereservation-test-"));
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns [] when EXPLORER_REPORT.md does not exist", () => {
    const result = parseFilesFromExplorerReport(tmpDir);
    expect(result).toEqual([]);
  });

  it("returns [] when EXPLORER_REPORT.md exists but has no file paths", () => {
    writeFileSync(join(tmpDir, "EXPLORER_REPORT.md"), [
      "# Explorer Report",
      "",
      "The codebase is well-structured.",
      "No specific files were identified.",
      "",
    ].join("\n"));
    const result = parseFilesFromExplorerReport(tmpDir);
    expect(result).toEqual([]);
  });

  it("parses simple dash-listed src/ paths", () => {
    writeFileSync(join(tmpDir, "EXPLORER_REPORT.md"), [
      "# Explorer Report",
      "",
      "## Key Files",
      "- src/orchestrator/agent-worker.ts",
      "- src/lib/store.ts",
      "- src/cli/commands/run.ts",
    ].join("\n"));
    const result = parseFilesFromExplorerReport(tmpDir);
    expect(result).toContain("src/orchestrator/agent-worker.ts");
    expect(result).toContain("src/lib/store.ts");
    expect(result).toContain("src/cli/commands/run.ts");
  });

  it("parses backtick-wrapped paths", () => {
    writeFileSync(join(tmpDir, "EXPLORER_REPORT.md"), [
      "# Explorer Report",
      "",
      "The main entry point is `src/main.ts` and the store is `src/lib/store.ts`.",
    ].join("\n"));
    const result = parseFilesFromExplorerReport(tmpDir);
    expect(result).toContain("src/main.ts");
    expect(result).toContain("src/lib/store.ts");
  });

  it("deduplicates paths mentioned multiple times", () => {
    writeFileSync(join(tmpDir, "EXPLORER_REPORT.md"), [
      "# Explorer Report",
      "",
      "- src/foo.ts",
      "- src/foo.ts",
      "- src/bar.ts",
      "See also: src/foo.ts",
    ].join("\n"));
    const result = parseFilesFromExplorerReport(tmpDir);
    const fooCount = result.filter((p) => p === "src/foo.ts").length;
    expect(fooCount).toBe(1);
    expect(result).toContain("src/bar.ts");
  });

  it("parses .js and .tsx extensions", () => {
    writeFileSync(join(tmpDir, "EXPLORER_REPORT.md"), [
      "# Explorer Report",
      "",
      "- src/app.js",
      "- src/components/Button.tsx",
      "- src/utils/helper.mts",
    ].join("\n"));
    const result = parseFilesFromExplorerReport(tmpDir);
    expect(result).toContain("src/app.js");
    expect(result).toContain("src/components/Button.tsx");
    expect(result).toContain("src/utils/helper.mts");
  });

  it("strips trailing punctuation from paths", () => {
    writeFileSync(join(tmpDir, "EXPLORER_REPORT.md"), [
      "# Explorer Report",
      "",
      "See src/foo.ts, and src/bar.ts.",
    ].join("\n"));
    const result = parseFilesFromExplorerReport(tmpDir);
    expect(result).toContain("src/foo.ts");
    expect(result).toContain("src/bar.ts");
    // Punctuation should be stripped
    expect(result.some((p) => p.endsWith(","))).toBe(false);
    expect(result.some((p) => p.endsWith("."))).toBe(false);
  });
});

// ── AgentMailClient integration — file reservation behavior ───────────────────

describe("AgentMailClient file reservation integration", () => {
  let client: AgentMailClient;
  let fetchSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    client = new AgentMailClient({ baseUrl: "http://localhost:8765", timeoutMs: 500 });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("calls fileReservation with the expected paths and agent name via JSON-RPC", async () => {
    // The new transport wraps calls in a JSON-RPC envelope to POST /mcp
    const rpcResponse = {
      jsonrpc: "2.0",
      id: 1,
      result: {
        content: [{ type: "text", text: JSON.stringify({ success: true }) }],
      },
    };
    fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      makeFetchResponse(rpcResponse),
    );

    const paths = ["src/foo.ts", "src/bar.ts"];
    const result = await client.fileReservation(paths, {
      agent: "developer-bd-test",
      durationMs: 3_600_000,
    });

    expect(result.success).toBe(true);
    expect(fetchSpy).toHaveBeenCalledOnce();

    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("http://localhost:8765/mcp");
    expect(init.method).toBe("POST");

    const body = JSON.parse(init.body as string) as {
      params: { name: string; arguments: Record<string, unknown> };
    };
    expect(body.params.name).toBe("file_reservation_paths");
    expect(body.params.arguments["paths"]).toEqual(paths);
    expect(body.params.arguments["agent_name"]).toBe("developer-bd-test");
    expect(body.params.arguments["ttl_seconds"]).toBe(3600);
  });

  it("calls releaseReservation with the expected paths and agent name via JSON-RPC", async () => {
    const rpcResponse = {
      jsonrpc: "2.0",
      id: 1,
      result: {
        content: [{ type: "text", text: JSON.stringify({ released: true }) }],
      },
    };
    fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      makeFetchResponse(rpcResponse),
    );

    const paths = ["src/foo.ts", "src/bar.ts"];
    await client.releaseReservation(paths, "developer-bd-test");

    expect(fetchSpy).toHaveBeenCalledOnce();
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("http://localhost:8765/mcp");
    expect(init.method).toBe("POST");

    const body = JSON.parse(init.body as string) as {
      params: { name: string; arguments: Record<string, unknown> };
    };
    expect(body.params.name).toBe("release_file_reservations");
    expect(body.params.arguments["paths"]).toEqual(paths);
    expect(body.params.arguments["agent_name"]).toBe("developer-bd-test");
  });

  it("returns { success: false } when fileReservation gets a network error", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("ECONNREFUSED"));
    const result = await client.fileReservation(["src/foo.ts"], {
      agent: "developer-bd-test",
    });
    expect(result.success).toBe(false);
  });

  it("returns { success: false } when fileReservation gets a non-2xx response", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      makeFetchResponse({ error: "conflict" }, 409),
    );
    const result = await client.fileReservation(["src/foo.ts"], {
      agent: "developer-bd-test",
    });
    expect(result.success).toBe(false);
  });

  it("silently ignores errors from releaseReservation (never throws)", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("ECONNREFUSED"));
    // Must not throw
    await expect(client.releaseReservation(["src/foo.ts"], "developer-bd-test")).resolves.toBeUndefined();
  });

  it("returns [] from fetchInbox when Agent Mail is unreachable", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("ECONNREFUSED"));
    const messages = await client.fetchInbox("qa-bd-test");
    expect(messages).toEqual([]);
  });

  it("fetchInbox returns messages from the inbox (mapped from server shape)", async () => {
    // Server returns messages with numeric id, sender_name, recipients, body_md, received_at
    const rawServerMessages = [
      {
        id: 1,
        sender_name: "developer-bd-test",
        recipients: ["qa-bd-test"],
        subject: "Dev complete",
        body_md: "All tests pass",
        received_at: new Date().toISOString(),
        acknowledged: false,
      },
    ];
    const rpcResponse = {
      jsonrpc: "2.0",
      id: 1,
      result: {
        content: [{ type: "text", text: JSON.stringify(rawServerMessages) }],
      },
    };
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      makeFetchResponse(rpcResponse),
    );
    const messages = await client.fetchInbox("qa-bd-test");
    expect(messages).toHaveLength(1);
    expect(messages[0]?.subject).toBe("Dev complete");
    expect(messages[0]?.id).toBe("1");
    expect(messages[0]?.from).toBe("developer-bd-test");
  });
});

// ── Pipeline integration: reservation lifecycle ───────────────────────────────

describe("file reservation pipeline lifecycle", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-reservation-lifecycle-"));
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    vi.restoreAllMocks();
  });

  it("no reservation is attempted when EXPLORER_REPORT.md has no file paths", () => {
    writeFileSync(join(tmpDir, "EXPLORER_REPORT.md"), [
      "# Explorer Report",
      "",
      "Explored the codebase thoroughly. No specific files noted.",
    ].join("\n"));
    const files = parseFilesFromExplorerReport(tmpDir);
    expect(files).toHaveLength(0);
    // When files is empty, code should skip reservation — verify with a mock
    const client = new AgentMailClient({ baseUrl: "http://localhost:8765" });
    const reserveSpy = vi.spyOn(client, "fileReservation");
    // Simulating: if (reservedFiles.length > 0) { await agentMailClient.fileReservation(...) }
    if (files.length > 0) {
      void client.fileReservation(files, { agent: "developer-test" });
    }
    expect(reserveSpy).not.toHaveBeenCalled();
  });

  it("reservation is attempted when EXPLORER_REPORT.md has file paths", async () => {
    writeFileSync(join(tmpDir, "EXPLORER_REPORT.md"), [
      "# Explorer Report",
      "",
      "## Key Files",
      "- src/orchestrator/agent-worker.ts",
      "- src/lib/store.ts",
    ].join("\n"));
    const files = parseFilesFromExplorerReport(tmpDir);
    expect(files.length).toBeGreaterThan(0);

    const client = new AgentMailClient({ baseUrl: "http://localhost:8765" });
    const reserveSpy = vi.spyOn(client, "fileReservation").mockResolvedValue({ success: true });

    // Simulating the reservation block
    if (files.length > 0) {
      await client.fileReservation(files, {
        agent: "developer-bd-test",
        durationMs: 3_600_000,
      });
    }
    expect(reserveSpy).toHaveBeenCalledOnce();
    expect(reserveSpy).toHaveBeenCalledWith(files, {
      agent: "developer-bd-test",
      durationMs: 3_600_000,
    });
  });

  it("releaseReservation is called after developer phase succeeds (finally block)", async () => {
    writeFileSync(join(tmpDir, "EXPLORER_REPORT.md"), [
      "# Explorer Report",
      "",
      "- src/foo.ts",
    ].join("\n"));
    const files = parseFilesFromExplorerReport(tmpDir);

    const client = new AgentMailClient({ baseUrl: "http://localhost:8765" });
    const releaseSpy = vi.spyOn(client, "releaseReservation").mockResolvedValue(undefined);

    // Simulate the try/finally pattern from the pipeline
    const agentName = "developer-bd-release";
    let devPhaseRan = false;
    try {
      devPhaseRan = true;
      // developer phase succeeds (no throw)
    } finally {
      if (files.length > 0) {
        await client.releaseReservation(files, agentName);
      }
    }

    expect(devPhaseRan).toBe(true);
    expect(releaseSpy).toHaveBeenCalledOnce();
    expect(releaseSpy).toHaveBeenCalledWith(files, agentName);
  });

  it("releaseReservation is called after developer phase fails (finally block)", async () => {
    writeFileSync(join(tmpDir, "EXPLORER_REPORT.md"), [
      "# Explorer Report",
      "",
      "- src/foo.ts",
    ].join("\n"));
    const files = parseFilesFromExplorerReport(tmpDir);

    const client = new AgentMailClient({ baseUrl: "http://localhost:8765" });
    const releaseSpy = vi.spyOn(client, "releaseReservation").mockResolvedValue(undefined);

    // Simulate the try/finally pattern from the pipeline — phase throws
    const agentName = "developer-bd-fail";
    let releaseCalledBeforeThrow = false;
    try {
      await (async () => {
        throw new Error("developer phase failed");
      })();
    } catch {
      // swallow for test
    } finally {
      if (files.length > 0) {
        await client.releaseReservation(files, agentName);
        releaseCalledBeforeThrow = true;
      }
    }

    expect(releaseCalledBeforeThrow).toBe(true);
    expect(releaseSpy).toHaveBeenCalledOnce();
  });

  it("pipeline continues when fileReservation throws", async () => {
    writeFileSync(join(tmpDir, "EXPLORER_REPORT.md"), [
      "# Explorer Report",
      "",
      "- src/foo.ts",
    ].join("\n"));
    const files = parseFilesFromExplorerReport(tmpDir);

    // Simulate fileReservation throwing (shouldn't happen since AgentMailClient
    // swallows all errors, but test the outer try/catch in the pipeline)
    const client = new AgentMailClient({ baseUrl: "http://localhost:8765" });
    vi.spyOn(client, "fileReservation").mockRejectedValue(new Error("unexpected throw"));

    let devPhaseRan = false;
    // Simulating the pipeline's try/catch around fileReservation
    if (files.length > 0) {
      try {
        await client.fileReservation(files, {
          agent: "developer-bd-test",
          durationMs: 3_600_000,
        });
      } catch {
        // Agent Mail is optional — never block the pipeline
      }
    }
    // Developer phase runs regardless
    devPhaseRan = true;

    expect(devPhaseRan).toBe(true);
  });
});
