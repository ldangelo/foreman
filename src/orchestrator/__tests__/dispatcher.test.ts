import { describe, it, expect } from "vitest";
import { Dispatcher } from "../dispatcher.js";
import type { BeadInfo } from "../types.js";

// Minimal mocks — we only need selectRuntime which doesn't touch store/beads
const mockStore = {} as any;
const mockBeads = {} as any;

function makeDispatcher() {
  return new Dispatcher(mockBeads, mockStore, "/tmp");
}

function makeBead(title: string): BeadInfo {
  return { id: "bead-001", title };
}

describe("Dispatcher.selectRuntime", () => {
  const dispatcher = makeDispatcher();

  it("selects pi for 'test' in title", () => {
    expect(dispatcher.selectRuntime(makeBead("Write unit tests"))).toBe("pi");
  });

  it("selects pi for 'doc' in title", () => {
    expect(dispatcher.selectRuntime(makeBead("Update documentation"))).toBe("pi");
  });

  it("selects pi for 'fix' in title", () => {
    expect(dispatcher.selectRuntime(makeBead("Fix login bug"))).toBe("pi");
  });

  it("selects claude-code for 'refactor' in title", () => {
    expect(dispatcher.selectRuntime(makeBead("Refactor auth module"))).toBe("claude-code");
  });

  it("selects claude-code for 'architect' in title", () => {
    expect(dispatcher.selectRuntime(makeBead("Architect the new data layer"))).toBe("claude-code");
  });

  it("defaults to claude-code for unknown keywords", () => {
    expect(dispatcher.selectRuntime(makeBead("Build user profile page"))).toBe("claude-code");
  });

  it("matches keywords case-insensitively", () => {
    expect(dispatcher.selectRuntime(makeBead("TEST the API"))).toBe("pi");
    expect(dispatcher.selectRuntime(makeBead("REFACTOR the codebase"))).toBe("claude-code");
    expect(dispatcher.selectRuntime(makeBead("FIX broken endpoint"))).toBe("pi");
  });
});
