import { describe, expect, it } from "vitest";
import { formatWorktreeEvent } from "../format-worktree-event.js";

describe("formatWorktreeEvent", () => {
  const ctx = { details: {} };

  describe("WorktreeCreated / worktree-created", () => {
    it("renders branch and path when both present", () => {
      const result = formatWorktreeEvent("WorktreeCreated", {
        target: "task-1",
        details: { branchName: "foreman/feat-x", worktreePath: "/tmp/ft/feat-x" },
      });
      expect(result).toBe("Worktree created for task-1 (foreman/feat-x) at /tmp/ft/feat-x");
    });

    it("renders only target when no branch or path", () => {
      expect(formatWorktreeEvent("worktree-created", { target: "task-2", details: {} })).toBe("Worktree created for task-2");
    });

    it("renders branch and path with snake_case keys", () => {
      const result = formatWorktreeEvent("WorktreeCreated", {
        details: { branch_name: "foreman/fix-y", worktree_path: "/tmp/ft/fix-y" },
      });
      expect(result).toBe("Worktree created (foreman/fix-y) at /tmp/ft/fix-y");
    });

    it("handles missing details", () => {
      expect(formatWorktreeEvent("WorktreeCreated", { details: null })).toBe("WorktreeCreated");
    });
  });

  describe("WorktreeCleaned / worktree-cleaned / worktree-removed", () => {
    it("renders path and reason", () => {
      const result = formatWorktreeEvent("WorktreeCleaned", {
        target: "task-3",
        details: { worktreePath: "/tmp/ft/feat-x", reason: "reset requested from cockpit" },
      });
      expect(result).toBe("Worktree removed for task-3 (/tmp/ft/feat-x) — reset requested from cockpit");
    });

    it("renders path only when reason absent", () => {
      const result = formatWorktreeEvent("worktree-removed", {
        target: "task-4",
        details: { worktreePath: "/tmp/ft/fix-y" },
      });
      expect(result).toBe("Worktree removed for task-4 (/tmp/ft/fix-y)");
    });

    it("renders reason only when path absent", () => {
      const result = formatWorktreeEvent("worktree-cleaned", {
        target: "task-5",
        details: { reason: "abandon" },
      });
      expect(result).toBe("Worktree removed for task-5 — abandon");
    });

    it("renders nothing extra when neither path nor reason", () => {
      expect(formatWorktreeEvent("WorktreeCleaned", { target: "task-6", details: {} })).toBe("Worktree removed for task-6");
    });

    it("handles missing details", () => {
      expect(formatWorktreeEvent("worktree-removed", { details: null })).toBe("worktree-removed");
    });
  });

  describe("unknown event type", () => {
    it("returns the event type as-is", () => {
      expect(formatWorktreeEvent("TaskCreated", { details: {} })).toBe("TaskCreated");
    });

    it("returns the event type when details is null", () => {
      expect(formatWorktreeEvent("TaskCreated", { details: null })).toBe("TaskCreated");
    });
  });
});
