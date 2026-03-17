/**
 * LEGACY: Tests for BeadsClient (beads/sd backend).
 *
 * BeadsClient is retained in beads.ts for backward compatibility but is no
 * longer the active task backend. The primary backend is now BeadsRustClient
 * (beads_rust/br). These tests verify the legacy sd CLI integration is intact.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Mock setup ──────────────────────────────────────────────────────────────
//
// We mock node:fs/promises so that ensureSdInstalled() and isInitialized()
// succeed without touching the filesystem.
//
// We mock node:child_process to capture the args that BeadsClient passes to
// `sd` without launching a real process.  vi.hoisted() ensures the mock
// variable is initialised before the module factory runs (vitest hoists
// vi.mock() calls to the top of the file, so plain variable declarations
// would be undefined at that point).

const { mockExecFile } = vi.hoisted(() => ({
  mockExecFile: vi.fn(),
}));

vi.mock("node:fs/promises", () => ({
  access: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("node:child_process", () => ({
  execFile: mockExecFile,
}));

import { BeadsClient } from "../beads.js";

// ── Helpers ─────────────────────────────────────────────────────────────────

/** Build a fake sd response for a given command sub-set.
 *
 * Note: beads.ts uses `promisify(execFile)` and destructures `{ stdout }` from
 * the result. Node's built-in execFile has a `util.promisify.custom` that
 * resolves with `{ stdout, stderr }`, but a plain mock function loses that
 * custom symbol.  We therefore mock `execFile` so that it calls the callback
 * with `{ stdout: <json>, stderr: "" }` as the second (success) argument,
 * which is what promisify will forward to the caller as the resolved value.
 */
function makeExecFileResponder(overrides: Record<string, object> = {}) {
  return (_cmd: string, args: string[], _opts: unknown, callback: Function) => {
    // args includes the sd sub-command plus "--json" appended by execBd
    const subCmd = args[0];

    const defaults: Record<string, object> = {
      create: { success: true, id: "foreman-mock-1" },
      show: {
        success: true,
        issue: {
          id: "foreman-mock-1",
          title: "Mock title",
          type: "task",
          priority: "P2",
          status: "open",
          assignee: null,
          parent: null,
          created_at: "2026-01-01T00:00:00Z",
          updated_at: "2026-01-01T00:00:00Z",
        },
      },
    };

    const payload = overrides[subCmd] ?? defaults[subCmd] ?? { success: true };
    // Pass result as { stdout, stderr } so that promisify resolves with the
    // same shape that the real execFile (via util.promisify.custom) would.
    callback(null, { stdout: JSON.stringify(payload), stderr: "" });
  };
}

// ── Tests ────────────────────────────────────────────────────────────────────

describe("BeadsClient.create", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("passes --parent flag to sd when parent option is provided", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());

    const client = new BeadsClient("/tmp/mock-project");
    await client.create("My task", { parent: "foreman-parent-42" });

    // Find the `create` invocation (first call, before the `show` follow-up)
    const createCall = mockExecFile.mock.calls.find(
      (call: any[]) => call[1]?.[0] === "create",
    );
    expect(createCall).toBeDefined();
    const createArgs: string[] = (createCall as any)[1];
    expect(createArgs).toContain("--parent");
    expect(createArgs).toContain("foreman-parent-42");
  });

  it("does NOT pass --parent flag when parent option is absent", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());

    const client = new BeadsClient("/tmp/mock-project");
    await client.create("My task");

    const createCall = mockExecFile.mock.calls.find(
      (call: any[]) => call[1]?.[0] === "create",
    );
    expect(createCall).toBeDefined();
    const createArgs: string[] = (createCall as any)[1];
    expect(createArgs).not.toContain("--parent");
  });

  it("passes --type and --priority flags", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());

    const client = new BeadsClient("/tmp/mock-project");
    await client.create("My bug", { type: "bug", priority: "P0" });

    const createCall = mockExecFile.mock.calls.find(
      (call: any[]) => call[1]?.[0] === "create",
    );
    const createArgs: string[] = (createCall as any)[1];
    expect(createArgs).toContain("--type");
    expect(createArgs).toContain("bug");
    expect(createArgs).toContain("--priority");
    expect(createArgs).toContain("P0");
  });

  it("passes --description flag when description is provided", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());

    const client = new BeadsClient("/tmp/mock-project");
    await client.create("Task with description", {
      description: "Detailed explanation here",
    });

    const createCall = mockExecFile.mock.calls.find(
      (call: any[]) => call[1]?.[0] === "create",
    );
    const createArgs: string[] = (createCall as any)[1];
    expect(createArgs).toContain("--description");
    expect(createArgs).toContain("Detailed explanation here");
  });

  it("passes --labels flag when labels are provided", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());

    const client = new BeadsClient("/tmp/mock-project");
    await client.create("Task with labels", {
      labels: ["frontend", "urgent"],
    });

    const createCall = mockExecFile.mock.calls.find(
      (call: any[]) => call[1]?.[0] === "create",
    );
    const createArgs: string[] = (createCall as any)[1];
    expect(createArgs).toContain("--labels");
    expect(createArgs).toContain("frontend,urgent");
  });

  it("includes --parent alongside other options", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());

    const client = new BeadsClient("/tmp/mock-project");
    await client.create("Child task", {
      type: "task",
      priority: "P1",
      parent: "foreman-epic-7",
      description: "Part of the epic",
    });

    const createCall = mockExecFile.mock.calls.find(
      (call: any[]) => call[1]?.[0] === "create",
    );
    const createArgs: string[] = (createCall as any)[1];
    expect(createArgs).toContain("--parent");
    expect(createArgs).toContain("foreman-epic-7");
    expect(createArgs).toContain("--type");
    expect(createArgs).toContain("task");
    expect(createArgs).toContain("--priority");
    expect(createArgs).toContain("P1");
  });
});
