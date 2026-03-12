import { describe, it, expect } from "vitest";
import { unwrapSdResponse } from "../seeds.js";

describe("unwrapSdResponse", () => {
  it("unwraps list response to issues array", () => {
    const raw = {
      success: true,
      command: "list",
      issues: [
        { id: "foreman-abc", title: "Task 1", status: "open" },
        { id: "foreman-def", title: "Task 2", status: "closed" },
      ],
    };
    const result = unwrapSdResponse(raw);
    expect(result).toEqual(raw.issues);
    expect(Array.isArray(result)).toBe(true);
    expect(result).toHaveLength(2);
  });

  it("unwraps ready response to issues array", () => {
    const raw = {
      success: true,
      command: "ready",
      issues: [{ id: "foreman-abc", title: "Task 1", status: "open" }],
    };
    const result = unwrapSdResponse(raw);
    expect(result).toEqual(raw.issues);
  });

  it("unwraps blocked response to issues array", () => {
    const raw = {
      success: true,
      command: "blocked",
      issues: [],
      count: 0,
    };
    const result = unwrapSdResponse(raw);
    expect(result).toEqual([]);
  });

  it("unwraps show response to single issue", () => {
    const raw = {
      success: true,
      command: "show",
      issue: {
        id: "foreman-abc",
        title: "Task 1",
        status: "open",
        description: "Details",
      },
    };
    const result = unwrapSdResponse(raw);
    expect(result).toEqual(raw.issue);
    expect(result.id).toBe("foreman-abc");
  });

  it("unwraps create response (returns full envelope since no nested data)", () => {
    const raw = {
      success: true,
      command: "create",
      id: "foreman-xyz",
    };
    const result = unwrapSdResponse(raw);
    // create returns { success, command, id } — no issues/issue key
    // so we return the envelope itself
    expect(result).toEqual(raw);
  });

  it("returns undefined as-is", () => {
    expect(unwrapSdResponse(undefined)).toBeUndefined();
  });

  it("returns non-object values as-is", () => {
    expect(unwrapSdResponse("hello")).toBe("hello");
    expect(unwrapSdResponse(42)).toBe(42);
  });

  it("returns bare arrays as-is (backward compat)", () => {
    const arr = [{ id: "1" }, { id: "2" }];
    expect(unwrapSdResponse(arr)).toEqual(arr);
  });

  it("throws on failed sd response", () => {
    const raw = {
      success: false,
      command: "show",
      error: "Issue not found: bad-id",
    };
    expect(() => unwrapSdResponse(raw)).toThrow("Issue not found: bad-id");
  });
});
