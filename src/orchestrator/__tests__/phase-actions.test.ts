import { describe, expect, it } from "vitest";
import { getPhaseActionDescriptor, inferPhaseActionType, isBashPhaseAction, isBuiltinPhaseAction, isCommandPhaseAction, isDispatcherPhaseAction } from "../phase-actions.js";
import type { WorkflowPhaseConfig } from "../../lib/workflow-loader.js";

describe("phase actions", () => {
  it("infers reusable action types for legacy phase shapes", () => {
    expect(inferPhaseActionType({ name: "developer", prompt: "developer.md" })).toBe("prompt-agent");
    expect(inferPhaseActionType({ name: "implement", command: "/skill:implement" })).toBe("command-agent");
    expect(inferPhaseActionType({ name: "auto-smoke", bash: "npm test" })).toBe("bash");
    expect(inferPhaseActionType({ name: "finalize", builtin: true })).toBe("finalize");
    expect(inferPhaseActionType({ name: "create-pr", builtin: true })).toBe("create-pr");
  });

  it("honors explicit action declarations", () => {
    const phase: WorkflowPhaseConfig = { name: "review", action: "prompt-agent", prompt: "reviewer.md" };
    expect(inferPhaseActionType(phase)).toBe("prompt-agent");
    expect(getPhaseActionDescriptor(phase)).toMatchObject({ kind: "prompt" });
  });

  it("classifies custom actions without prompt/bash/command as builtin execution path", () => {
    expect(getPhaseActionDescriptor({ name: "notify", action: "notify-slack" })).toMatchObject({ kind: "builtin" });
  });

  it("classifies execution paths by action kind", () => {
    expect(isCommandPhaseAction({ name: "prd", action: "command-agent", command: "/skill:create-prd" })).toBe(true);
    expect(isBashPhaseAction({ name: "smoke", action: "bash", bash: "npm test" })).toBe(true);
    expect(isBuiltinPhaseAction({ name: "merge", action: "merge", builtin: true })).toBe(true);
    expect(isDispatcherPhaseAction({ name: "prepare-worktree", action: "prepare-worktree" })).toBe(true);
  });
});
