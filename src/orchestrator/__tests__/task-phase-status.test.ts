import { describe, expect, it } from "vitest";
import { nativeTaskStatusForPhase } from "../task-phase-status.js";

describe("nativeTaskStatusForPhase", () => {
  it("keeps native phase statuses unchanged", () => {
    expect(nativeTaskStatusForPhase("developer")).toBe("developer");
    expect(nativeTaskStatusForPhase("qa")).toBe("qa");
    expect(nativeTaskStatusForPhase("reviewer")).toBe("reviewer");
    expect(nativeTaskStatusForPhase("finalize")).toBe("finalize");
  });

  it("maps implementation helper phases to in-progress", () => {
    expect(nativeTaskStatusForPhase("fix")).toBe("in-progress");
    expect(nativeTaskStatusForPhase("implement")).toBe("in-progress");
    expect(nativeTaskStatusForPhase("test")).toBe("in-progress");
  });

  it("skips builtin PR and review helper phases that are not native task statuses", () => {
    expect(nativeTaskStatusForPhase("cli-review")).toBeNull();
    expect(nativeTaskStatusForPhase("create-pr")).toBeNull();
    expect(nativeTaskStatusForPhase("pr-wait")).toBeNull();
    expect(nativeTaskStatusForPhase("prepare-pr-review")).toBeNull();
    expect(nativeTaskStatusForPhase("pr-review")).toBeNull();
    expect(nativeTaskStatusForPhase("merge")).toBeNull();
  });
});
