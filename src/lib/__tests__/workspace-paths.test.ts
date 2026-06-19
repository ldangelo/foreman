import { describe, expect, it } from "vitest";
import {
  buildTrackedStateRestoreCommand,
  getBeadsIssuesPathForWorkspace,
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

  it("uses local beads state for external workspaces", () => {
    expect(getBeadsIssuesPathForWorkspace("/tmp/.foreman-worktrees/repo/foreman-123", "/tmp/repo")).toBe(".beads/issues.jsonl");
  });

  it("uses main repo beads state for nested legacy workspaces", () => {
    expect(getBeadsIssuesPathForWorkspace("/tmp/repo/.foreman-worktrees/foreman-123", "/tmp/repo")).toBe("../../.beads/issues.jsonl");
  });

  it("unstages node_modules symlinks and runtime artifacts before finalize commits", () => {
    const command = buildTrackedStateRestoreCommand("/tmp/.foreman-worktrees/repo/foreman-123", "/tmp/repo");

    expect(command).toContain(".beads/issues.jsonl");
    expect(command).toContain("node_modules");
    expect(command).toContain("SESSION_LOG.md");
    expect(command).toContain("RUN_LOG.md");
    expect(command).toContain("DOCUMENTATION_REPORT.md");
    expect(command).toContain("FINALIZE_VALIDATION.md");
    expect(command).toContain("docs/reports");
    expect(command).toContain("git rm -r --cached --ignore-unmatch");
  });
});
