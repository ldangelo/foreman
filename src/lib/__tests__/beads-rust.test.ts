import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Mock setup ──────────────────────────────────────────────────────────────

const { mockExecFile } = vi.hoisted(() => ({
  mockExecFile: vi.fn(),
}));

vi.mock("node:fs/promises", () => ({
  access: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("node:child_process", () => ({
  execFile: mockExecFile,
}));

import { BeadsRustClient, unwrapBrResponse } from "../beads-rust.js";

// ── Helpers ─────────────────────────────────────────────────────────────────

function makeExecFileResponder(overrides: Record<string, object> = {}) {
  return (_cmd: string, args: string[], _opts: unknown, callback: Function) => {
    const subCmd = args[0];

    const defaults: Record<string, object> = {
      create: { id: "beads-mock-1", title: "Mock title", type: "task", priority: "P2", status: "open", assignee: null, parent: null, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z" },
      show: { id: "beads-mock-1", title: "Mock title", type: "task", priority: "P2", status: "open", assignee: null, parent: null, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z", description: null, notes: null, labels: [], estimate_minutes: null, dependencies: [], children: [] },
      list: [],
      ready: [],
      search: [],
      update: {},
      close: {},
      dep: {},
    };

    const payload = overrides[subCmd] ?? defaults[subCmd] ?? {};
    callback(null, { stdout: JSON.stringify(payload), stderr: "" });
  };
}

// ── unwrapBrResponse ────────────────────────────────────────────────────────

describe("unwrapBrResponse", () => {
  it("returns null/undefined as-is", () => {
    expect(unwrapBrResponse(null)).toBeNull();
    expect(unwrapBrResponse(undefined)).toBeUndefined();
  });

  it("returns arrays as-is", () => {
    const arr = [{ id: "1" }, { id: "2" }];
    expect(unwrapBrResponse(arr)).toBe(arr);
  });

  it("throws on error envelope", () => {
    expect(() =>
      unwrapBrResponse({ success: false, error: "something broke" }),
    ).toThrow("something broke");
  });

  it("unwraps issues envelope", () => {
    const issues = [{ id: "1" }];
    expect(unwrapBrResponse({ issues })).toBe(issues);
  });

  it("unwraps issue envelope", () => {
    const issue = { id: "1", title: "test" };
    expect(unwrapBrResponse({ issue })).toBe(issue);
  });

  it("returns plain objects as-is", () => {
    const obj = { id: "beads-abc", title: "hello" };
    expect(unwrapBrResponse(obj)).toBe(obj);
  });
});

// ── BeadsRustClient.create ──────────────────────────────────────────────────

describe("BeadsRustClient.create", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("passes --title flag", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.create("My task");

    const createCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "create",
    );
    expect(createCall).toBeDefined();
    const createArgs = (createCall as unknown[])[1] as string[];
    expect(createArgs).toContain("--title");
    expect(createArgs).toContain("My task");
    expect(createArgs).toContain("--json");
  });

  it("passes --parent flag when parent option is provided", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.create("My task", { parent: "beads-parent-42" });

    const createCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "create",
    );
    const createArgs = (createCall as unknown[])[1] as string[];
    expect(createArgs).toContain("--parent");
    expect(createArgs).toContain("beads-parent-42");
  });

  it("does NOT pass --parent flag when parent option is absent", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.create("My task");

    const createCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "create",
    );
    const createArgs = (createCall as unknown[])[1] as string[];
    expect(createArgs).not.toContain("--parent");
  });

  it("passes --type and --priority flags", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.create("My bug", { type: "bug", priority: "P0" });

    const createCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "create",
    );
    const createArgs = (createCall as unknown[])[1] as string[];
    expect(createArgs).toContain("--type");
    expect(createArgs).toContain("bug");
    expect(createArgs).toContain("--priority");
    expect(createArgs).toContain("P0");
  });

  it("passes --description flag", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.create("Task", { description: "Detailed explanation" });

    const createCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "create",
    );
    const createArgs = (createCall as unknown[])[1] as string[];
    expect(createArgs).toContain("--description");
    expect(createArgs).toContain("Detailed explanation");
  });

  it("passes --labels flag", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.create("Task", { labels: ["frontend", "urgent"] });

    const createCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "create",
    );
    const createArgs = (createCall as unknown[])[1] as string[];
    expect(createArgs).toContain("--labels");
    expect(createArgs).toContain("frontend,urgent");
  });

  it("passes --estimate flag as minutes", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.create("Task", { estimate: 180 });

    const createCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "create",
    );
    const createArgs = (createCall as unknown[])[1] as string[];
    expect(createArgs).toContain("--estimate");
    expect(createArgs).toContain("180");
  });

  it("includes all options together", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.create("Child task", {
      type: "task",
      priority: "P1",
      parent: "beads-epic-7",
      description: "Part of the epic",
      labels: ["kind:task", "trd:SL-T001"],
      estimate: 240,
    });

    const createCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "create",
    );
    const createArgs = (createCall as unknown[])[1] as string[];
    expect(createArgs).toContain("--parent");
    expect(createArgs).toContain("beads-epic-7");
    expect(createArgs).toContain("--type");
    expect(createArgs).toContain("task");
    expect(createArgs).toContain("--priority");
    expect(createArgs).toContain("P1");
    expect(createArgs).toContain("--labels");
    expect(createArgs).toContain("kind:task,trd:SL-T001");
    expect(createArgs).toContain("--estimate");
    expect(createArgs).toContain("240");
  });

  it("fetches full issue when create returns only id", async () => {
    mockExecFile.mockImplementation(
      makeExecFileResponder({
        create: { id: "beads-123" },
      }),
    );
    const client = new BeadsRustClient("/tmp/mock-project");
    const result = await client.create("My task");

    // Should have made both a create and show call
    const showCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "show",
    );
    expect(showCall).toBeDefined();
    expect(result.id).toBe("beads-mock-1");
  });
});

// ── BeadsRustClient.list ────────────────────────────────────────────────────

describe("BeadsRustClient.list", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("returns empty array when no issues", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    const result = await client.list();
    expect(result).toEqual([]);
  });

  it("passes --label filter", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.list({ label: "trd:TRD-MERGE-QUEUE" });

    const listCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "list",
    );
    const listArgs = (listCall as unknown[])[1] as string[];
    expect(listArgs).toContain("--label");
    expect(listArgs).toContain("trd:TRD-MERGE-QUEUE");
  });

  it("passes --status and --type filters", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.list({ status: "open", type: "task" });

    const listCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "list",
    );
    const listArgs = (listCall as unknown[])[1] as string[];
    expect(listArgs).toContain("--status");
    expect(listArgs).toContain("open");
    expect(listArgs).toContain("--type");
    expect(listArgs).toContain("task");
  });
});

// ── BeadsRustClient.close ───────────────────────────────────────────────────

describe("BeadsRustClient.close", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("closes an issue by id", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.close("beads-123");

    const closeCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "close",
    );
    const closeArgs = (closeCall as unknown[])[1] as string[];
    expect(closeArgs).toContain("beads-123");
  });

  it("passes --reason flag", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.close("beads-123", "completed");

    const closeCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "close",
    );
    const closeArgs = (closeCall as unknown[])[1] as string[];
    expect(closeArgs).toContain("--reason");
    expect(closeArgs).toContain("completed");
  });
});

// ── BeadsRustClient.addDependency ───────────────────────────────────────────

describe("BeadsRustClient.addDependency", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("wires dependency via dep add", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.addDependency("beads-child", "beads-parent");

    const depCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "dep",
    );
    const depArgs = (depCall as unknown[])[1] as string[];
    expect(depArgs).toEqual(expect.arrayContaining(["dep", "add", "beads-child", "beads-parent"]));
  });
});

// ── BeadsRustClient.update ──────────────────────────────────────────────────

describe("BeadsRustClient.update", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("passes update fields", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.update("beads-123", {
      description: "Updated desc",
      notes: "Some notes",
      acceptance: "AC-1: works",
    });

    const updateCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "update",
    );
    const updateArgs = (updateCall as unknown[])[1] as string[];
    expect(updateArgs).toContain("--description");
    expect(updateArgs).toContain("Updated desc");
    expect(updateArgs).toContain("--notes");
    expect(updateArgs).toContain("Some notes");
    expect(updateArgs).toContain("--acceptance");
    expect(updateArgs).toContain("AC-1: works");
  });

  it("passes --set-labels flag when labels provided in update()", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.update("bd-001", { labels: ["phase:explorer", "phase:developer"] });

    const updateCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "update",
    );
    const updateArgs = (updateCall as unknown[])[1] as string[];
    expect(updateArgs).toContain("--set-labels");
    expect(updateArgs).toContain("phase:explorer,phase:developer");
  });

  it("does not pass --set-labels flag when labels not provided in update()", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.update("bd-001", { status: "in_progress" });

    const updateCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "update",
    );
    const updateArgs = (updateCall as unknown[])[1] as string[];
    expect(updateArgs).not.toContain("--set-labels");
  });
});

// ── BeadsRustClient.search ──────────────────────────────────────────────────

describe("BeadsRustClient.search", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("passes search query", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.search("parser");

    const searchCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "search",
    );
    const searchArgs = (searchCall as unknown[])[1] as string[];
    expect(searchArgs).toContain("parser");
  });

  it("passes --label filter on search", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder());
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.search("epic", { label: "trd:TRD-SLING" });

    const searchCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "search",
    );
    const searchArgs = (searchCall as unknown[])[1] as string[];
    expect(searchArgs).toContain("--label");
    expect(searchArgs).toContain("trd:TRD-SLING");
  });
});

// ── BeadsRustClient.ready ───────────────────────────────────────────────────

describe("BeadsRustClient.ready", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("returns parsed BrIssue array of open unblocked issues", async () => {
    const issues = [
      { id: "beads-1", title: "First task", type: "task", priority: "P1", status: "open", assignee: null, parent: null, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z" },
      { id: "beads-2", title: "Second task", type: "bug", priority: "P0", status: "open", assignee: null, parent: null, created_at: "2026-01-02T00:00:00Z", updated_at: "2026-01-02T00:00:00Z" },
    ];
    mockExecFile.mockImplementation(
      makeExecFileResponder({ ready: issues }),
    );
    const client = new BeadsRustClient("/tmp/mock-project");
    const result = await client.ready();

    expect(result).toEqual(issues);
  });

  it("invokes br ready --json", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder({ ready: [] }));
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.ready();

    const readyCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "ready",
    );
    expect(readyCall).toBeDefined();
    const readyArgs = (readyCall as unknown[])[1] as string[];
    expect(readyArgs).toContain("--json");
  });

  it("returns empty array when output is empty", async () => {
    mockExecFile.mockImplementation(
      (_cmd: string, _args: string[], _opts: unknown, callback: Function) => {
        callback(null, { stdout: "", stderr: "" });
      },
    );
    const client = new BeadsRustClient("/tmp/mock-project");
    const result = await client.ready();
    expect(result).toEqual([]);
  });

  it("returns empty array when br returns empty array", async () => {
    mockExecFile.mockImplementation(makeExecFileResponder({ ready: [] }));
    const client = new BeadsRustClient("/tmp/mock-project");
    const result = await client.ready();
    expect(result).toEqual([]);
  });

  it("throws when br binary is not found", async () => {
    const { access: mockAccess } = await import("node:fs/promises");
    (mockAccess as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error("ENOENT"));

    const client = new BeadsRustClient("/tmp/mock-project");
    await expect(client.ready()).rejects.toThrow("br (beads_rust) CLI not found");
  });

  it("throws on malformed JSON output", async () => {
    mockExecFile.mockImplementation(
      (_cmd: string, _args: string[], _opts: unknown, callback: Function) => {
        callback(null, { stdout: "not valid json {{{{", stderr: "" });
      },
    );
    const client = new BeadsRustClient("/tmp/mock-project");
    await expect(client.ready()).rejects.toThrow();
  });
});

// ── BeadsRustClient.comments ────────────────────────────────────────────────

describe("BeadsRustClient.comments", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("returns null when there are no comments", async () => {
    mockExecFile.mockImplementation(
      (_cmd: string, _args: string[], _opts: unknown, callback: Function) => {
        callback(null, { stdout: JSON.stringify([]), stderr: "" });
      },
    );
    const client = new BeadsRustClient("/tmp/mock-project");
    const result = await client.comments("bd-001");
    expect(result).toBeNull();
  });

  it("formats a single comment as markdown", async () => {
    const comments = [
      {
        id: 1,
        issue_id: "bd-001",
        author: "alice",
        text: "Please add rate limiting",
        created_at: "2026-03-20T14:30:00Z",
      },
    ];
    mockExecFile.mockImplementation(
      (_cmd: string, _args: string[], _opts: unknown, callback: Function) => {
        callback(null, { stdout: JSON.stringify(comments), stderr: "" });
      },
    );
    const client = new BeadsRustClient("/tmp/mock-project");
    const result = await client.comments("bd-001");
    expect(result).toContain("**alice**");
    expect(result).toContain("2026-03-20T14:30:00Z");
    expect(result).toContain("Please add rate limiting");
  });

  it("formats multiple comments separated by blank lines", async () => {
    const comments = [
      {
        id: 1,
        issue_id: "bd-001",
        author: "alice",
        text: "First comment",
        created_at: "2026-03-20T14:30:00Z",
      },
      {
        id: 2,
        issue_id: "bd-001",
        author: "bob",
        text: "Second comment",
        created_at: "2026-03-20T15:45:00Z",
      },
    ];
    mockExecFile.mockImplementation(
      (_cmd: string, _args: string[], _opts: unknown, callback: Function) => {
        callback(null, { stdout: JSON.stringify(comments), stderr: "" });
      },
    );
    const client = new BeadsRustClient("/tmp/mock-project");
    const result = await client.comments("bd-001");
    expect(result).toContain("**alice**");
    expect(result).toContain("**bob**");
    expect(result).toContain("First comment");
    expect(result).toContain("Second comment");
    // Should be separated by double newline
    expect(result).toMatch(/First comment\n\nSecond comment|\n\n/);
  });

  it("invokes br comments <id> --json", async () => {
    mockExecFile.mockImplementation(
      (_cmd: string, _args: string[], _opts: unknown, callback: Function) => {
        callback(null, { stdout: JSON.stringify([]), stderr: "" });
      },
    );
    const client = new BeadsRustClient("/tmp/mock-project");
    await client.comments("bd-abc");

    const commentsCall = mockExecFile.mock.calls.find(
      (call: unknown[]) => (call[1] as string[])?.[0] === "comments",
    );
    expect(commentsCall).toBeDefined();
    const commentsArgs = (commentsCall as unknown[])[1] as string[];
    expect(commentsArgs).toContain("bd-abc");
    expect(commentsArgs).toContain("--json");
  });

  it("throws when br command fails", async () => {
    mockExecFile.mockImplementation(
      (_cmd: string, _args: string[], _opts: unknown, callback: Function) => {
        const err = new Error("exit 1") as Error & { stderr: string; stdout: string };
        err.stderr = "error: issue not found";
        err.stdout = "";
        callback(err);
      },
    );
    const client = new BeadsRustClient("/tmp/mock-project");
    await expect(client.comments("bd-bad")).rejects.toThrow("br comments");
  });
});

// ── BeadsRustClient error handling ──────────────────────────────────────────

describe("BeadsRustClient error handling", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("throws when br binary is not found", async () => {
    const { access: mockAccess } = await import("node:fs/promises");
    (mockAccess as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error("ENOENT"));

    const client = new BeadsRustClient("/tmp/mock-project");
    await expect(client.ensureBrInstalled()).rejects.toThrow("br (beads_rust) CLI not found");
  });

  it("throws when .beads/ not initialized", async () => {
    const { access: mockAccess } = await import("node:fs/promises");
    // First call (ensureBrInstalled) succeeds, second call (isInitialized) fails
    (mockAccess as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(undefined)  // br binary exists
      .mockRejectedValueOnce(new Error("ENOENT"));  // .beads/ missing

    const client = new BeadsRustClient("/tmp/mock-project");
    await expect(client.list()).rejects.toThrow("Beads not initialised");
  });

  it("throws on non-zero exit from br CLI", async () => {
    mockExecFile.mockImplementation(
      (_cmd: string, _args: string[], _opts: unknown, callback: Function) => {
        const err = new Error("exit 1") as Error & { stderr: string; stdout: string };
        err.stderr = "error: issue not found";
        err.stdout = "";
        callback(err);
      },
    );

    const client = new BeadsRustClient("/tmp/mock-project");
    await expect(client.show("nonexistent")).rejects.toThrow("br show nonexistent --json --lock-timeout 10000 failed");
  });
});
