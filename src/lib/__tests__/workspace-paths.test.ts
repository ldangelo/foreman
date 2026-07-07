import { describe, expect, it } from "vitest";
import {
  buildTrackedStateRestoreCommand,
  getTasksIssuesPathForWorkspace,
  getWorkspacePath,
  getWorkspaceRoot,
  inferProjectPathFromWorkspacePath,
} from "../workspace-paths.js";

describe("workspace path helpers", () => {
  it("builds external workspace paths", () => {
    expect(getWorkspaceRoot("/tmp/repo")).toBe("/tmp/.foreman-worktrees/repo");
    expect(getWorkspacePath("/tmp/repo", "foreman-123")).toBe("/tmp/.foreman-worktrees/repo/foreman-123");
    expect(inferProjectPathFromWorkspacePath("/tmp/.foreman-worktrees/repo/foreman-123")).toBe("/tmp/repo");
  });

  it("uses local tasks state for external workspaces", () => {
    expect(getTasksIssuesPathForWorkspace("/tmp/.foreman-worktrees/repo/foreman-123", "/tmp/repo")).toBe(".tasks/issues.jsonl");
  });

  it("uses main repo tasks state for nested legacy workspaces", () => {
    expect(getTasksIssuesPathForWorkspace("/tmp/repo/.foreman-worktrees/foreman-123", "/tmp/repo")).toBe("../../.tasks/issues.jsonl");
  });

  it("unstages node_modules symlinks and runtime artifacts before finalize commits", () => {
    const command = buildTrackedStateRestoreCommand("/tmp/.foreman-worktrees/repo/foreman-123", "/tmp/repo");

    expect(command).toContain(".tasks/issues.jsonl");
    expect(command).toContain("node_modules");
    expect(command).toContain("SESSION_LOG.md");
    expect(command).toContain("RUN_LOG.md");
    expect(command).toContain("DOCUMENTATION_REPORT.md");
    expect(command).toContain("FINALIZE_VALIDATION.md");
    expect(command).toContain("docs/reports");
    expect(command).toContain("git rm -r --cached --ignore-unmatch");
  });
});
