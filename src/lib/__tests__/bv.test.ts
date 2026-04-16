import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Mock setup ──────────────────────────────────────────────────────────────

const { mockExecFile } = vi.hoisted(() => ({
  mockExecFile: vi.fn(),
}));

vi.mock("node:child_process", () => ({
  execFile: mockExecFile,
}));

import { BvClient } from "../bv.js";
import type { BvTriageResult, BvNextResult } from "../bv.js";

beforeEach(() => {
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

// ── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Returns a callback-style mock for execFile that dispatches by the binary
 * path basename.  br -> brResponse, bv -> bvResponse.
 */
function makeExecFileResponder(opts: {
  brResponse?: { stdout: string; stderr: string } | Error;
  bvResponse?: { stdout: string; stderr: string } | Error;
} = {}) {
  const brOut = opts.brResponse ?? { stdout: "", stderr: "" };
  const bvOut = opts.bvResponse ?? {
    stdout: JSON.stringify({ id: "bd-001", title: "Default task", score: 0.9 }),
    stderr: "",
  };

  return (cmd: string, _args: string[], _opts: unknown, callback: Function) => {
    const isBr = cmd.endsWith("/br") || cmd === "br";
    const response = isBr ? brOut : bvOut;
    if (response instanceof Error) {
      callback(response);
    } else {
      callback(null, response);
    }
  };
}

const MOCK_TRIAGE: BvTriageResult = {
  recommendations: [
    { id: "bd-001", title: "First task", score: 0.95 },
    { id: "bd-002", title: "Second task", score: 0.80 },
  ],
  quick_ref: {
    actionable_count: 2,
    top_picks: [{ id: "bd-001", title: "First task", score: 0.95 }],
  },
};

const MOCK_NEXT: BvNextResult = {
  id: "bd-001",
  title: "First task",
  score: 0.95,
  claim_command: "br update bd-001 --status=in_progress",
};

// ── BvClient.robotTriage ────────────────────────────────────────────────────

describe("BvClient.robotTriage", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("calls br sync --flush-only before bv", async () => {
    const calls: string[][] = [];
    mockExecFile.mockImplementation(
      (cmd: string, args: string[], _opts: unknown, callback: Function) => {
        calls.push([cmd, ...args]);
        if (cmd.endsWith("/br") || cmd === "br") {
          callback(null, { stdout: "", stderr: "" });
        } else {
          callback(null, { stdout: JSON.stringify(MOCK_TRIAGE), stderr: "" });
        }
      },
    );

    const client = new BvClient("/tmp/mock-project");
    await client.robotTriage();

    // br sync must come before bv
    const brIdx = calls.findIndex((c) => c[1] === "sync");
    const bvIdx = calls.findIndex((c) =>
      c[0].endsWith("/bv") || c[0] === "bv",
    );
    expect(brIdx).toBeGreaterThanOrEqual(0);
    expect(bvIdx).toBeGreaterThanOrEqual(0);
    expect(brIdx).toBeLessThan(bvIdx);
  });

  it("passes --flush-only to br sync", async () => {
    const brArgs: string[] = [];
    mockExecFile.mockImplementation(
      (cmd: string, args: string[], _opts: unknown, callback: Function) => {
        if (cmd.endsWith("/br") || cmd === "br") {
          brArgs.push(...args);
          callback(null, { stdout: "", stderr: "" });
        } else {
          callback(null, { stdout: JSON.stringify(MOCK_TRIAGE), stderr: "" });
        }
      },
    );

    const client = new BvClient("/tmp/mock-project");
    await client.robotTriage();

    expect(brArgs).toContain("sync");
    expect(brArgs).toContain("--flush-only");
  });

  it("returns parsed triage result on success", async () => {
    mockExecFile.mockImplementation(
      makeExecFileResponder({
        bvResponse: { stdout: JSON.stringify(MOCK_TRIAGE), stderr: "" },
      }),
    );

    const client = new BvClient("/tmp/mock-project");
    const result = await client.robotTriage();

    expect(result).not.toBeNull();
    expect(result!.recommendations).toHaveLength(2);
    expect(result!.recommendations[0].id).toBe("bd-001");
    expect(result!.quick_ref?.actionable_count).toBe(2);
  });

  it("includes --robot-triage in bv arguments", async () => {
    const bvArgs: string[] = [];
    mockExecFile.mockImplementation(
      (cmd: string, args: string[], _opts: unknown, callback: Function) => {
        if (cmd.endsWith("/bv") || cmd === "bv") {
          bvArgs.push(...args);
          callback(null, { stdout: JSON.stringify(MOCK_TRIAGE), stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const client = new BvClient("/tmp/mock-project");
    await client.robotTriage();

    expect(bvArgs).toContain("--robot-triage");
  });

  it("always appends --format toon", async () => {
    const bvArgs: string[] = [];
    mockExecFile.mockImplementation(
      (cmd: string, args: string[], _opts: unknown, callback: Function) => {
        if (cmd.endsWith("/bv") || cmd === "bv") {
          bvArgs.push(...args);
          callback(null, { stdout: JSON.stringify(MOCK_TRIAGE), stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const client = new BvClient("/tmp/mock-project");
    await client.robotTriage();

    expect(bvArgs).toContain("--format");
    expect(bvArgs).toContain("toon");
  });

  it("returns null when bv binary missing (ENOENT)", async () => {
    mockExecFile.mockImplementation(
      (cmd: string, _args: string[], _opts: unknown, callback: Function) => {
        if (cmd.endsWith("/br") || cmd === "br") {
          callback(null, { stdout: "", stderr: "" });
        } else {
          const err = Object.assign(new Error("spawn ENOENT"), { code: "ENOENT" });
          callback(err);
        }
      },
    );

    const client = new BvClient("/tmp/mock-project");
    const result = await client.robotTriage();
    expect(result).toBeNull();
  });

  it("returns null when bv exits non-zero", async () => {
    mockExecFile.mockImplementation(
      (cmd: string, _args: string[], _opts: unknown, callback: Function) => {
        if (cmd.endsWith("/br") || cmd === "br") {
          callback(null, { stdout: "", stderr: "" });
        } else {
          const err = Object.assign(new Error("exit 1"), {
            code: 1,
            stderr: "error: no beads project found",
            stdout: "",
          });
          callback(err);
        }
      },
    );

    const client = new BvClient("/tmp/mock-project");
    const result = await client.robotTriage();
    expect(result).toBeNull();
  });

  it("returns null when bv output is malformed JSON", async () => {
    mockExecFile.mockImplementation(
      makeExecFileResponder({
        bvResponse: { stdout: "not-json{{{{", stderr: "" },
      }),
    );

    const client = new BvClient("/tmp/mock-project");
    const result = await client.robotTriage();
    expect(result).toBeNull();
  });
});

// ── BvClient.robotNext ──────────────────────────────────────────────────────

describe("BvClient.robotNext", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("returns single task result on success", async () => {
    mockExecFile.mockImplementation(
      makeExecFileResponder({
        bvResponse: { stdout: JSON.stringify(MOCK_NEXT), stderr: "" },
      }),
    );

    const client = new BvClient("/tmp/mock-project");
    const result = await client.robotNext();

    expect(result).not.toBeNull();
    expect(result!.id).toBe("bd-001");
    expect(result!.title).toBe("First task");
    expect(result!.score).toBe(0.95);
    expect(result!.claim_command).toBe("br update bd-001 --status=in_progress");
  });

  it("includes --robot-next in bv arguments", async () => {
    const bvArgs: string[] = [];
    mockExecFile.mockImplementation(
      (cmd: string, args: string[], _opts: unknown, callback: Function) => {
        if (cmd.endsWith("/bv") || cmd === "bv") {
          bvArgs.push(...args);
          callback(null, { stdout: JSON.stringify(MOCK_NEXT), stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const client = new BvClient("/tmp/mock-project");
    await client.robotNext();

    expect(bvArgs).toContain("--robot-next");
  });

  it("returns null when bv binary missing", async () => {
    mockExecFile.mockImplementation(
      (cmd: string, _args: string[], _opts: unknown, callback: Function) => {
        if (cmd.endsWith("/br") || cmd === "br") {
          callback(null, { stdout: "", stderr: "" });
        } else {
          const err = Object.assign(new Error("spawn ENOENT"), { code: "ENOENT" });
          callback(err);
        }
      },
    );

    const client = new BvClient("/tmp/mock-project");
    const result = await client.robotNext();
    expect(result).toBeNull();
  });

  it("returns null when output is malformed", async () => {
    mockExecFile.mockImplementation(
      makeExecFileResponder({
        bvResponse: { stdout: "!!bad json", stderr: "" },
      }),
    );

    const client = new BvClient("/tmp/mock-project");
    const result = await client.robotNext();
    expect(result).toBeNull();
  });
});

// ── BvClient.robotPlan / robotInsights / robotAlerts ────────────────────────

describe("BvClient.robotPlan", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("includes --robot-plan in bv arguments", async () => {
    const bvArgs: string[] = [];
    mockExecFile.mockImplementation(
      (cmd: string, args: string[], _opts: unknown, callback: Function) => {
        if (cmd.endsWith("/bv") || cmd === "bv") {
          bvArgs.push(...args);
          callback(null, { stdout: JSON.stringify({ tracks: [] }), stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const client = new BvClient("/tmp/mock-project");
    await client.robotPlan();

    expect(bvArgs).toContain("--robot-plan");
  });

  it("returns null on failure", async () => {
    mockExecFile.mockImplementation(
      (cmd: string, _args: string[], _opts: unknown, callback: Function) => {
        if (cmd.endsWith("/br") || cmd === "br") {
          callback(null, { stdout: "", stderr: "" });
        } else {
          callback(new Error("spawn ENOENT"));
        }
      },
    );

    const client = new BvClient("/tmp/mock-project");
    const result = await client.robotPlan();
    expect(result).toBeNull();
  });
});

describe("BvClient.robotInsights", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("includes --robot-insights in bv arguments", async () => {
    const bvArgs: string[] = [];
    mockExecFile.mockImplementation(
      (cmd: string, args: string[], _opts: unknown, callback: Function) => {
        if (cmd.endsWith("/bv") || cmd === "bv") {
          bvArgs.push(...args);
          callback(null, { stdout: JSON.stringify({ metrics: {} }), stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const client = new BvClient("/tmp/mock-project");
    await client.robotInsights();

    expect(bvArgs).toContain("--robot-insights");
  });
});

describe("BvClient.robotAlerts", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("includes --robot-alerts in bv arguments", async () => {
    const bvArgs: string[] = [];
    mockExecFile.mockImplementation(
      (cmd: string, args: string[], _opts: unknown, callback: Function) => {
        if (cmd.endsWith("/bv") || cmd === "bv") {
          bvArgs.push(...args);
          callback(null, { stdout: JSON.stringify({ alerts: [] }), stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const client = new BvClient("/tmp/mock-project");
    await client.robotAlerts();

    expect(bvArgs).toContain("--robot-alerts");
  });
});

// ── ADR-002 safety: no public bare-invocation method ────────────────────────

describe("BvClient ADR-002 safety", () => {
  it("does not expose an exec() method on the instance", () => {
    const client = new BvClient("/tmp/mock-project");
    // TypeScript compile-time check is the primary guard; this verifies at runtime too
    const c = client as unknown as Record<string, unknown>;
    expect(c["exec"]).toBeUndefined();
    expect(c["run"]).toBeUndefined();
    expect(c["execBv"]).toBeUndefined();
  });

  it("only exposes the five documented public methods", () => {
    const client = new BvClient("/tmp/mock-project");
    const publicMethods = Object.getOwnPropertyNames(
      Object.getPrototypeOf(client),
    ).filter((m) => m !== "constructor" && !m.startsWith("_"));

    const allowedMethods = new Set([
      "robotNext",
      "robotTriage",
      "robotPlan",
      "robotInsights",
      "robotAlerts",
    ]);

    for (const method of publicMethods) {
      expect(allowedMethods.has(method)).toBe(true);
    }
  });
});

// ── Timeout handling ─────────────────────────────────────────────────────────

describe("BvClient timeout", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("returns null when bv call exceeds timeout", async () => {
    mockExecFile.mockImplementation(
      (cmd: string, _args: string[], _opts: unknown, callback: Function) => {
        if (cmd.endsWith("/br") || cmd === "br") {
          callback(null, { stdout: "", stderr: "" });
          return;
        }
        // Simulate timeout error
        const err = Object.assign(new Error("ETIMEDOUT"), { code: "ETIMEDOUT" });
        callback(err);
      },
    );

    const client = new BvClient("/tmp/mock-project", { timeoutMs: 100 });
    const result = await client.robotTriage();
    expect(result).toBeNull();
  });
});
