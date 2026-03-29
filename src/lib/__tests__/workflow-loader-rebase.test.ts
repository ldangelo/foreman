/**
 * Tests for rebaseAfterPhase / rebaseTarget workflow-loader.ts changes (TRD-003-TEST).
 *
 * Verifies:
 * - AC-T-003-1: Valid rebaseAfterPhase is accepted and stored
 * - AC-T-003-2: Absent rebaseAfterPhase -> config.rebaseAfterPhase is undefined
 * - AC-T-003-3: rebaseAfterPhase referencing unknown phase throws WorkflowConfigError
 * - AC-T-003-4: rebaseTarget is parsed as-is
 * - AC-T-003-5: Absent rebaseTarget -> config.rebaseTarget is undefined
 */

import { describe, it, expect } from "vitest";
import { validateWorkflowConfig, WorkflowConfigError } from "../workflow-loader.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

function baseWorkflow(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    name: "test",
    phases: [
      { name: "explorer", prompt: "explorer.md" },
      { name: "developer", prompt: "developer.md" },
      { name: "qa", prompt: "qa.md" },
    ],
    ...overrides,
  };
}

// ── Tests ────────────────────────────────────────────────────────────────────

describe("validateWorkflowConfig — rebaseAfterPhase", () => {
  it("AC-T-003-1: valid rebaseAfterPhase is accepted", () => {
    const config = validateWorkflowConfig(
      baseWorkflow({ rebaseAfterPhase: "developer" }),
      "test",
    );
    expect(config.rebaseAfterPhase).toBe("developer");
  });

  it("AC-T-003-2: absent rebaseAfterPhase -> undefined", () => {
    const config = validateWorkflowConfig(baseWorkflow(), "test");
    expect(config.rebaseAfterPhase).toBeUndefined();
  });

  it("AC-T-003-3: rebaseAfterPhase referencing unknown phase throws with descriptive error", () => {
    expect(() =>
      validateWorkflowConfig(baseWorkflow({ rebaseAfterPhase: "bogus" }), "test"),
    ).toThrow(WorkflowConfigError);

    try {
      validateWorkflowConfig(baseWorkflow({ rebaseAfterPhase: "nonexistent-phase" }), "test");
      expect.fail("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(WorkflowConfigError);
      expect((err as WorkflowConfigError).message).toMatch(/rebaseAfterPhase names unknown phase/);
      expect((err as WorkflowConfigError).message).toContain("nonexistent-phase");
      // Error message should list the valid phase names
      expect((err as WorkflowConfigError).message).toMatch(/explorer|developer|qa/);
    }
  });

  it("rebaseAfterPhase can reference the first phase", () => {
    const config = validateWorkflowConfig(
      baseWorkflow({ rebaseAfterPhase: "explorer" }),
      "test",
    );
    expect(config.rebaseAfterPhase).toBe("explorer");
  });

  it("rebaseAfterPhase non-string throws WorkflowConfigError", () => {
    expect(() =>
      validateWorkflowConfig(baseWorkflow({ rebaseAfterPhase: 42 }), "test"),
    ).toThrow(WorkflowConfigError);
  });
});

describe("validateWorkflowConfig — rebaseTarget", () => {
  it("AC-T-003-4: rebaseTarget is parsed as-is", () => {
    const config = validateWorkflowConfig(
      baseWorkflow({ rebaseAfterPhase: "developer", rebaseTarget: "origin/feature-branch" }),
      "test",
    );
    expect(config.rebaseTarget).toBe("origin/feature-branch");
  });

  it("AC-T-003-5: absent rebaseTarget -> undefined", () => {
    const config = validateWorkflowConfig(baseWorkflow(), "test");
    expect(config.rebaseTarget).toBeUndefined();
  });

  it("rebaseTarget can be set without rebaseAfterPhase (independent fields)", () => {
    const config = validateWorkflowConfig(
      baseWorkflow({ rebaseTarget: "origin/main" }),
      "test",
    );
    expect(config.rebaseTarget).toBe("origin/main");
    expect(config.rebaseAfterPhase).toBeUndefined();
  });

  it("rebaseTarget with non-string throws WorkflowConfigError", () => {
    expect(() =>
      validateWorkflowConfig(baseWorkflow({ rebaseTarget: 123 }), "test"),
    ).toThrow(WorkflowConfigError);
  });
});
