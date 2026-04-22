import { afterEach, describe, expect, it, vi } from "vitest";
import { join } from "node:path";
import { WorktreeManager } from "../worktree-manager.js";

describe("WorktreeManager", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("derives the default root from HOME at construction time", () => {
    vi.stubEnv("HOME", "/tmp/foreman-home-test");

    const manager = new WorktreeManager();

    expect(manager.root).toBe(join("/tmp/foreman-home-test", ".foreman", "worktrees"));
  });
});
