import { describe, it, expect } from "vitest";
import { Dispatcher } from "../dispatcher.js";
import type { SeedInfo } from "../types.js";

// Minimal mocks — we only need selectModel which doesn't touch store/seeds
const mockStore = {} as any;
const mockSeeds = {} as any;

function makeDispatcher() {
  return new Dispatcher(mockSeeds, mockStore, "/tmp");
}

function makeSeed(title: string, description?: string): SeedInfo {
  return { id: "seed-001", title, description };
}

describe("Dispatcher.selectModel", () => {
  const dispatcher = makeDispatcher();

  it("selects opus for 'refactor' in title", () => {
    expect(dispatcher.selectModel(makeSeed("Refactor auth module"))).toBe("claude-opus-4-6");
  });

  it("selects opus for 'architect' in title", () => {
    expect(dispatcher.selectModel(makeSeed("Architect the new data layer"))).toBe("claude-opus-4-6");
  });

  it("selects opus for 'design' in title", () => {
    expect(dispatcher.selectModel(makeSeed("Design the API schema"))).toBe("claude-opus-4-6");
  });

  it("selects opus for 'migrate' in title", () => {
    expect(dispatcher.selectModel(makeSeed("Migrate database to Postgres"))).toBe("claude-opus-4-6");
  });

  it("selects haiku for 'typo' in title", () => {
    expect(dispatcher.selectModel(makeSeed("Fix typo in README"))).toBe("claude-haiku-4-5-20251001");
  });

  it("selects haiku for 'config' in title", () => {
    expect(dispatcher.selectModel(makeSeed("Update config for staging"))).toBe("claude-haiku-4-5-20251001");
  });

  it("defaults to sonnet for implementation tasks", () => {
    expect(dispatcher.selectModel(makeSeed("Build user profile page"))).toBe("claude-sonnet-4-6");
  });

  it("defaults to sonnet for test tasks", () => {
    expect(dispatcher.selectModel(makeSeed("Write unit tests for auth"))).toBe("claude-sonnet-4-6");
  });

  it("defaults to sonnet for fix tasks", () => {
    expect(dispatcher.selectModel(makeSeed("Fix login bug"))).toBe("claude-sonnet-4-6");
  });

  it("matches keywords case-insensitively", () => {
    expect(dispatcher.selectModel(makeSeed("REFACTOR the codebase"))).toBe("claude-opus-4-6");
    expect(dispatcher.selectModel(makeSeed("TYPO in variable name"))).toBe("claude-haiku-4-5-20251001");
  });

  it("checks description for complexity signals", () => {
    expect(dispatcher.selectModel(makeSeed("Update module", "This requires a complex overhaul"))).toBe("claude-opus-4-6");
  });
});
