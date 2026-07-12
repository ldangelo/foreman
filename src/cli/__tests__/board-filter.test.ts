import { describe, expect, it } from "vitest";
import { resolveFilterToBoardStatus } from "../commands/board.js";

describe("board status filters", () => {
  it.each([
    ["completed", "closed"],
    ["closed", "closed"],
    ["merged", "closed"],
    ["in-progress", "in_progress"],
    ["in_progress", "in_progress"],
    ["needs-attention", "needs_attention"],
    ["blocked", "needs_attention"],
    ["todo", "backlog"],
    ["ready", "ready"],
  ] as const)("resolves %s to %s", (filter, expected) => {
    expect(resolveFilterToBoardStatus(filter)).toBe(expected);
  });

  it("returns null when no status filter is provided", () => {
    expect(resolveFilterToBoardStatus(undefined)).toBeNull();
  });
});
