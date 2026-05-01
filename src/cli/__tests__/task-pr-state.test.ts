import { describe, expect, it } from "vitest";
import { resolveTaskPrDisplayState } from "../commands/task.js";

describe("resolveTaskPrDisplayState", () => {
  it("returns none when no PR metadata exists", () => {
    expect(resolveTaskPrDisplayState(null)).toBe("none");
  });

  it("returns the stored PR state when head still matches", () => {
    expect(resolveTaskPrDisplayState({ pr_state: "draft", pr_head_sha: "abc123" }, "abc123")).toBe("draft");
    expect(resolveTaskPrDisplayState({ pr_state: "open", pr_head_sha: "abc123" }, "abc123")).toBe("open");
    expect(resolveTaskPrDisplayState({ pr_state: "merged", pr_head_sha: "abc123" }, "abc123")).toBe("merged");
  });

  it("returns head-mismatch when branch head has moved since PR publication", () => {
    expect(resolveTaskPrDisplayState({ pr_state: "open", pr_head_sha: "oldhead" }, "newhead")).toBe("head-mismatch");
  });
});
