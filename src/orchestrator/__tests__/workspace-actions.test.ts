import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";
import { runWorkspaceAction, type WorkspaceActionContext } from "../workspace-actions.js";

function makeCtx(repoPath: string, worktreePath?: string): WorkspaceActionContext {
  return {
    projectId: "project-1",
    seedId: "task-1",
    repoPath,
    worktreePath,
    attemptNumber: 1,
    seedInfo: {
      id: "task-1",
      title: "Test task",
      description: "Do thing",
      priority: "medium",
      labels: [],
    },
    model: "anthropic/claude-sonnet-4-6",
    log: () => {},
  };
}

describe("workspace actions", () => {
  const dirs: string[] = [];

  afterEach(() => {
    for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  });

  it("runs a custom workspace action module", async () => {
    const repo = mkdtempSync(join(tmpdir(), "foreman-workspace-action-repo-"));
    dirs.push(repo);
    mkdirSync(join(repo, ".foreman", "actions"), { recursive: true });
    writeFileSync(join(repo, ".foreman", "actions", "notify.js"), `
export async function run(ctx) {
  return { ...ctx, branchName: ctx.actionType + "-done" };
}
`);

    const result = await runWorkspaceAction("notify", makeCtx(repo));
    expect(result.branchName).toBe("notify-done");
  });

  it("rejects custom workspace actions that return invalid context", async () => {
    const repo = mkdtempSync(join(tmpdir(), "foreman-workspace-action-repo-"));
    dirs.push(repo);
    mkdirSync(join(repo, ".foreman", "actions"), { recursive: true });
    writeFileSync(join(repo, ".foreman", "actions", "bad-workspace.js"), `
export default async function run() {
  return { success: true };
}
`);

    await expect(runWorkspaceAction("bad-workspace", makeCtx(repo))).rejects.toThrow(/missing projectId/);
  });

  it("lets project workspace action overrides wrap built-in behavior", async () => {
    const repo = mkdtempSync(join(tmpdir(), "foreman-workspace-action-repo-"));
    const worktree = mkdtempSync(join(tmpdir(), "foreman-workspace-action-worktree-"));
    dirs.push(repo, worktree);
    mkdirSync(join(repo, ".foreman", "actions"), { recursive: true });
    writeFileSync(join(repo, ".foreman", "actions", "write-task-context.js"), `
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
export default async function run(ctx) {
  const next = await ctx.internal.runBuiltin();
  await writeFile(join(next.worktreePath, "ACTION_MARKER"), ctx.actionType, "utf8");
  return next;
}
`);

    const result = await runWorkspaceAction("write-task-context", makeCtx(repo, worktree));
    expect(result.worktreePath).toBe(worktree);
    expect(existsSync(join(worktree, "TASK.md"))).toBe(true);
    expect(readFileSync(join(worktree, "ACTION_MARKER"), "utf8")).toBe("write-task-context");
  });
});
