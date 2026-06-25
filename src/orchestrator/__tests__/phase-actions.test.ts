import { describe, expect, it } from "vitest";
import { DEFAULT_PHASE_ACTION_CAPABILITIES, getPhaseActionDescriptor, inferPhaseActionType, isBashPhaseAction, isBuiltinPhaseAction, isCommandPhaseAction, isDispatcherPhaseAction, phaseActionCapabilities } from "../phase-actions.js";
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

  it("classifies custom actions as builtin execution path even with config fields", () => {
    expect(getPhaseActionDescriptor({ name: "notify", action: "notify-slack" })).toMatchObject({ kind: "builtin" });
    expect(getPhaseActionDescriptor({ name: "notify", action: "notify-slack", prompt: "notify.md" })).toMatchObject({ kind: "builtin" });
  });

  it("declares default capabilities for privileged builtins", () => {
    expect(DEFAULT_PHASE_ACTION_CAPABILITIES["create-pr"]).toEqual(expect.arrayContaining(["vcs", "mail", "task-store", "network"]));
    expect(DEFAULT_PHASE_ACTION_CAPABILITIES["prepare-worktree"]).toEqual(expect.arrayContaining(["vcs"]));
    expect(DEFAULT_PHASE_ACTION_CAPABILITIES.finalize).toEqual(expect.arrayContaining(["vcs", "exec"]));
  });

  it("merges default capabilities with declared capabilities", () => {
    expect(phaseActionCapabilities("create-pr", ["exec", "vcs"])).toEqual(["vcs", "mail", "task-store", "network", "exec"]);
    expect(phaseActionCapabilities("custom", ["exec"])).toEqual(["exec"]);
  });

  it("classifies execution paths by action kind", () => {
    expect(isCommandPhaseAction({ name: "prd", action: "command-agent", command: "/skill:create-prd" })).toBe(true);
    expect(isBashPhaseAction({ name: "smoke", action: "bash", bash: "npm test" })).toBe(true);
    expect(isBuiltinPhaseAction({ name: "merge", action: "merge", builtin: true })).toBe(true);
    expect(isDispatcherPhaseAction({ name: "prepare-worktree", action: "prepare-worktree" })).toBe(true);
  });
});
