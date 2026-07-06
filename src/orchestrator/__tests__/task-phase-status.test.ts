import { describe, expect, it } from "vitest";
import { nativeTaskStatusForPhase } from "../task-phase-status.js";

describe("nativeTaskStatusForPhase", () => {
  it("keeps task status separate from workflow phase names", () => {
    expect(nativeTaskStatusForPhase("developer")).toBe("in-progress");
    expect(nativeTaskStatusForPhase("qa")).toBe("in-progress");
    expect(nativeTaskStatusForPhase("documentation")).toBe("in-progress");
    expect(nativeTaskStatusForPhase("any-future-phase")).toBe("in-progress");
  });
});
