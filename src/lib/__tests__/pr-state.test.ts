import { afterEach, describe, expect, it, vi } from "vitest";

const execFileMock = vi.hoisted(() => {
  const mock = vi.fn();
  const promisifyCustom = Symbol.for("nodejs.util.promisify.custom");
  Object.assign(mock, {
    [promisifyCustom]: (cmd: string, args: string[], opts: unknown) =>
      new Promise<{ stdout: string; stderr: string }>((resolve, reject) => {
        mock(cmd, args, opts, (err: Error | null, stdout: string, stderr: string) => {
          if (err) reject(err);
          else resolve({ stdout, stderr });
        });
      }),
  });
  return mock;
});

vi.mock("node:child_process", () => ({
  execFile: execFileMock,
}));

const { getPrState, getPrStatesForTasks } = await import("../pr-state.js");

type ExecResult = { stdout?: string; stderr?: string; code?: number };

function queueExecResult(result: ExecResult): void {
  execFileMock.mockImplementationOnce((_cmd, _args, _opts, callback) => {
    if (result.code && result.code !== 0) {
      const error = new Error("command failed") as Error & { code: number; stdout?: string; stderr?: string };
      error.code = result.code;
      error.stdout = result.stdout ?? "";
      error.stderr = result.stderr ?? "";
      callback(error);
      return;
    }
    callback(null, result.stdout ?? "", result.stderr ?? "");
  });
}

function prJson(state: string, headRefOid = "head-1") {
  return JSON.stringify({ state, number: 12, headRefOid, url: "https://github.test/acme/repo/pull/12" });
}

afterEach(() => {
  execFileMock.mockReset();
});

describe("getPrState", () => {
  it("returns an error state when no branch or seed id is provided", async () => {
    await expect(getPrState({ projectPath: "/repo" })).resolves.toMatchObject({
      status: "error",
      error: "Neither branchName nor seedId provided",
      summary: "—",
    });
    expect(execFileMock).not.toHaveBeenCalled();
  });

  it("reports no PR and branch deletion distinctly", async () => {
    queueExecResult({ code: 1, stderr: "unknown revision" });
    queueExecResult({ code: 1, stderr: "no pull request found" });

    await expect(getPrState({ projectPath: "/repo", seedId: "task-1" })).resolves.toMatchObject({
      status: "none",
      currentHeadSha: null,
      summary: "no PR (branch deleted)",
    });
  });

  it("summarizes open, merged, stale merged, closed, and unknown PR states", async () => {
    const cases = [
      { state: "OPEN", current: "head-1", head: "head-1", status: "open", stale: false, summary: "open (#12)" },
      { state: "MERGED", current: "head-1", head: "head-1", status: "merged", stale: false, summary: "merged (#12)" },
      { state: "MERGED", current: "head-2", head: "head-1", status: "merged", stale: true, summary: "merged (#12, stale)" },
      { state: "CLOSED", current: "head-1", head: "head-1", status: "closed", stale: false, summary: "closed (#12)" },
      { state: "DRAFT", current: "head-1", head: "head-1", status: "error", stale: false, summary: "?" },
    ];

    for (const testCase of cases) {
      queueExecResult({ stdout: testCase.current });
      queueExecResult({ stdout: prJson(testCase.state, testCase.head) });

      await expect(getPrState({ projectPath: "/repo", branchName: `foreman/${testCase.state}` })).resolves.toMatchObject({
        status: testCase.status,
        number: 12,
        headSha: testCase.head,
        currentHeadSha: testCase.current,
        isStale: testCase.stale,
        summary: testCase.summary,
      });
    }
  });

  it("surfaces gh command and JSON parsing errors", async () => {
    queueExecResult({ stdout: "head-1" });
    queueExecResult({ code: 2, stderr: "gh auth required" });

    await expect(getPrState({ projectPath: "/repo", branchName: "foreman/auth" })).resolves.toMatchObject({
      status: "error",
      error: "gh auth required",
      summary: "?",
    });

    queueExecResult({ stdout: "head-1" });
    queueExecResult({ stdout: "not-json" });

    await expect(getPrState({ projectPath: "/repo", branchName: "foreman/bad-json" })).resolves.toMatchObject({
      status: "error",
      error: "Failed to parse PR response",
      summary: "?",
    });
  });
});

describe("getPrStatesForTasks", () => {
  it("batches branch lookups and maps each task to its PR summary", async () => {
    queueExecResult({ stdout: "head-a" });
    queueExecResult({ code: 1, stderr: "missing branch" });
    queueExecResult({ stdout: prJson("OPEN", "head-a") });
    queueExecResult({ code: 1, stderr: "could not find pull request" });

    const states = await getPrStatesForTasks(
      [
        { id: "task-a", branch: "custom/task-a" },
        { id: "task-b" },
      ],
      "/repo",
    );

    expect(states.get("task-a")).toMatchObject({ status: "open", summary: "open (#12)", currentHeadSha: "head-a" });
    expect(states.get("task-b")).toMatchObject({ status: "none", summary: "no PR (branch deleted)", currentHeadSha: null });
  });

  it("records per-branch gh errors and stale merged PRs in batch results", async () => {
    queueExecResult({ stdout: "head-x" });
    queueExecResult({ stdout: "head-y" });
    queueExecResult({ code: 2, stderr: "rate limited" });
    queueExecResult({ stdout: prJson("MERGED", "old-head-y") });

    const states = await getPrStatesForTasks(
      [
        { id: "task-x" },
        { id: "task-y" },
      ],
      "/repo",
    );

    expect(states.get("task-x")).toMatchObject({ status: "error", error: "rate limited", summary: "no PR" });
    expect(states.get("task-y")).toMatchObject({ status: "merged", isStale: true, summary: "merged (#12, stale)" });
  });
});
