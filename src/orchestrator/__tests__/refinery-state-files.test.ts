import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Module mocks ─────────────────────────────────────────────────────────────

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
}));

// Import mocked modules AFTER vi.mock declarations
import { execFile } from "node:child_process";
import { Refinery } from "../refinery.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeMocks() {
  const store = {
    getRunsByStatus: vi.fn(() => []),
    getRun: vi.fn(() => null),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
  };
  const seeds = {
    getGraph: vi.fn(async () => ({ edges: [] })),
    show: vi.fn(async () => null),
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const refinery = new Refinery(store as any, seeds as any, "/tmp/project");
  return { store, seeds, refinery };
}

/**
 * Set up execFile mock to respond based on git arguments.
 * `statusOutput` is what `git status --porcelain` returns.
 */
function mockGitCommands(statusOutput: string) {
  const calls: Array<{ cmd: string; args: string[] }> = [];

  (execFile as unknown as ReturnType<typeof vi.fn>).mockImplementation(
    (_cmd: string, _args: string[], _opts: unknown, callback: Function) => {
      calls.push({ cmd: _cmd, args: _args });

      if (
        Array.isArray(_args) &&
        _args.includes("status") &&
        _args.includes("--porcelain")
      ) {
        callback(null, { stdout: statusOutput, stderr: "" });
      } else {
        // git add, git commit — succeed
        callback(null, { stdout: "", stderr: "" });
      }
    },
  );

  return calls;
}

// ── autoCommitStateFiles() tests ─────────────────────────────────────────────

describe("Refinery.autoCommitStateFiles()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("no-op when working tree is clean", async () => {
    const { refinery } = makeMocks();
    const calls = mockGitCommands("");

    // Access private method via bracket notation
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (refinery as any).autoCommitStateFiles();

    // Should call git status but NOT git add or git commit
    const gitArgs = calls.map((c) => c.args);
    const statusCall = gitArgs.find(
      (a) => a.includes("status") && a.includes("--porcelain"),
    );
    expect(statusCall).toBeDefined();

    const addCall = gitArgs.find((a) => a[0] === "add");
    expect(addCall).toBeUndefined();

    const commitCall = gitArgs.find((a) => a[0] === "commit");
    expect(commitCall).toBeUndefined();
  });

  it("no-op when dirty files are not in .seeds/ or .foreman/", async () => {
    const { refinery } = makeMocks();
    const calls = mockGitCommands(" M src/index.ts\n?? README.md\n");

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (refinery as any).autoCommitStateFiles();

    const gitArgs = calls.map((c) => c.args);
    const addCall = gitArgs.find((a) => a[0] === "add");
    expect(addCall).toBeUndefined();

    const commitCall = gitArgs.find((a) => a[0] === "commit");
    expect(commitCall).toBeUndefined();
  });

  it("commits when .seeds/ has uncommitted changes", async () => {
    const { refinery } = makeMocks();
    const calls = mockGitCommands(
      " M .seeds/issues.jsonl\n M src/index.ts\n",
    );

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (refinery as any).autoCommitStateFiles();

    const gitArgs = calls.map((c) => c.args);

    // Should git add only the .seeds/ file
    const addCall = gitArgs.find((a) => a[0] === "add");
    expect(addCall).toBeDefined();
    expect(addCall).toContain(".seeds/issues.jsonl");

    // Should git commit
    const commitCall = gitArgs.find((a) => a[0] === "commit");
    expect(commitCall).toBeDefined();
  });

  it("commits when .foreman/ has uncommitted changes", async () => {
    const { refinery } = makeMocks();
    const calls = mockGitCommands(
      " M .foreman/reports/QA-seed-1.md\n",
    );

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (refinery as any).autoCommitStateFiles();

    const gitArgs = calls.map((c) => c.args);

    const addCall = gitArgs.find((a) => a[0] === "add");
    expect(addCall).toBeDefined();
    expect(addCall).toContain(".foreman/reports/QA-seed-1.md");

    const commitCall = gitArgs.find((a) => a[0] === "commit");
    expect(commitCall).toBeDefined();
  });

  it("uses correct commit message format", async () => {
    const { refinery } = makeMocks();
    const calls = mockGitCommands(" M .seeds/issues.jsonl\n");

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (refinery as any).autoCommitStateFiles();

    const gitArgs = calls.map((c) => c.args);
    const commitCall = gitArgs.find((a) => a[0] === "commit");
    expect(commitCall).toBeDefined();
    expect(commitCall).toContain("-m");
    const msgIndex = commitCall!.indexOf("-m") + 1;
    expect(commitCall![msgIndex]).toBe(
      "chore: auto-commit state files before merge",
    );
  });

  it("handles both .seeds/ and .foreman/ together", async () => {
    const { refinery } = makeMocks();
    const calls = mockGitCommands(
      " M .seeds/issues.jsonl\n?? .foreman/state.db\n M src/foo.ts\n",
    );

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (refinery as any).autoCommitStateFiles();

    const gitArgs = calls.map((c) => c.args);

    // Should add both state files but NOT src/foo.ts
    const addCalls = gitArgs.filter((a) => a[0] === "add");
    expect(addCalls.length).toBeGreaterThanOrEqual(1);

    // Collect all files passed to git add
    const addedFiles = addCalls.flatMap((a) => a.slice(1));
    expect(addedFiles).toContain(".seeds/issues.jsonl");
    expect(addedFiles).toContain(".foreman/state.db");
    expect(addedFiles).not.toContain("src/foo.ts");

    // Should commit exactly once
    const commitCalls = gitArgs.filter((a) => a[0] === "commit");
    expect(commitCalls).toHaveLength(1);
  });
});
