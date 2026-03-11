import { describe, it, expect } from "vitest";
import { Dispatcher } from "../dispatcher.js";
import type { BeadInfo } from "../types.js";

// Minimal mocks — we only need selectModel which doesn't touch store/beads
const mockStore = {} as any;
const mockBeads = {} as any;

function makeDispatcher() {
  return new Dispatcher(mockBeads, mockStore, "/tmp");
}

function makeBead(title: string, description?: string): BeadInfo {
  return { id: "bead-001", title, description };
}

describe("Dispatcher.selectModel", () => {
  const dispatcher = makeDispatcher();

  it("selects opus for 'refactor' in title", () => {
    expect(dispatcher.selectModel(makeBead("Refactor auth module"))).toBe("claude-opus-4-6");
  });

  it("selects opus for 'architect' in title", () => {
    expect(dispatcher.selectModel(makeBead("Architect the new data layer"))).toBe("claude-opus-4-6");
  });

  it("selects opus for 'design' in title", () => {
    expect(dispatcher.selectModel(makeBead("Design the API schema"))).toBe("claude-opus-4-6");
  });

  it("selects opus for 'migrate' in title", () => {
    expect(dispatcher.selectModel(makeBead("Migrate database to Postgres"))).toBe("claude-opus-4-6");
  });

  it("selects haiku for 'typo' in title", () => {
    expect(dispatcher.selectModel(makeBead("Fix typo in README"))).toBe("claude-haiku-4-5-20251001");
  });

  it("selects haiku for 'config' in title", () => {
    expect(dispatcher.selectModel(makeBead("Update config for staging"))).toBe("claude-haiku-4-5-20251001");
  });

  it("defaults to sonnet for implementation tasks", () => {
    expect(dispatcher.selectModel(makeBead("Build user profile page"))).toBe("claude-sonnet-4-6");
  });

  it("defaults to sonnet for test tasks", () => {
    expect(dispatcher.selectModel(makeBead("Write unit tests for auth"))).toBe("claude-sonnet-4-6");
  });

  it("defaults to sonnet for fix tasks", () => {
    expect(dispatcher.selectModel(makeBead("Fix login bug"))).toBe("claude-sonnet-4-6");
  });

  it("matches keywords case-insensitively", () => {
    expect(dispatcher.selectModel(makeBead("REFACTOR the codebase"))).toBe("claude-opus-4-6");
    expect(dispatcher.selectModel(makeBead("TYPO in variable name"))).toBe("claude-haiku-4-5-20251001");
  });

  it("checks description for complexity signals", () => {
    expect(dispatcher.selectModel(makeBead("Update module", "This requires a complex overhaul"))).toBe("claude-opus-4-6");
  });
});
