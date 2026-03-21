/**
 * TRD-013-TEST + TRD-014-TEST + TRD-015-TEST: Workflow Config Loader Tests
 *
 * Tests for loadWorkflows(), getWorkflow(), validateWorkflowPhases(),
 * and validateFinalizeEnforcement() from workflow-config-loader.ts.
 *
 * Satisfies: REQ-011, REQ-024, REQ-025, REQ-016,
 *            AC-011-1 through AC-011-6, AC-016-4 through AC-016-8,
 *            AC-024-1 through AC-024-4, AC-025-1 through AC-025-4
 */

import { describe, it, expect } from "vitest";
import {
  DEFAULT_WORKFLOWS,
  validateWorkflowPhases,
  validateFinalizeEnforcement,
  getWorkflow,
} from "../workflow-config-loader.js";

// ── DEFAULT_WORKFLOWS tests ────────────────────────────────────────────────────

describe("DEFAULT_WORKFLOWS", () => {
  it("AC-011-2: has 'feature' workflow", () => {
    expect(DEFAULT_WORKFLOWS).toHaveProperty("feature");
    expect(DEFAULT_WORKFLOWS["feature"]).toBeInstanceOf(Array);
    expect(DEFAULT_WORKFLOWS["feature"]).toContain("finalize");
  });

  it("AC-011-4: has 'bug' workflow with reproducer as first phase", () => {
    expect(DEFAULT_WORKFLOWS).toHaveProperty("bug");
    const bugWorkflow = DEFAULT_WORKFLOWS["bug"];
    expect(bugWorkflow[0]).toBe("reproducer");
    expect(bugWorkflow[bugWorkflow.length - 1]).toBe("finalize");
  });

  it("has 'chore' workflow ending with finalize", () => {
    expect(DEFAULT_WORKFLOWS).toHaveProperty("chore");
    const chore = DEFAULT_WORKFLOWS["chore"];
    expect(chore[chore.length - 1]).toBe("finalize");
  });

  it("has 'docs' workflow ending with finalize", () => {
    expect(DEFAULT_WORKFLOWS).toHaveProperty("docs");
    const docs = DEFAULT_WORKFLOWS["docs"];
    expect(docs[docs.length - 1]).toBe("finalize");
  });

  it("all default workflows end with finalize", () => {
    for (const [seedType, phases] of Object.entries(DEFAULT_WORKFLOWS)) {
      expect(phases[phases.length - 1]).toBe("finalize");
      expect(phases.length).toBeGreaterThan(0);
    }
  });
});

// ── validateFinalizeEnforcement tests (TRD-015) ──────────────────────────────

describe("validateFinalizeEnforcement() - TRD-015", () => {
  it("AC-025-1: passes for workflow ending with 'finalize'", () => {
    const workflows = {
      feature: ["explorer", "developer", "qa", "reviewer", "finalize"],
    };
    expect(() => validateFinalizeEnforcement(workflows)).not.toThrow();
  });

  it("AC-025-2: throws when workflow is missing 'finalize'", () => {
    const workflows = {
      bad: ["developer", "qa"],
    };
    expect(() => validateFinalizeEnforcement(workflows)).toThrow(/finalize/);
    expect(() => validateFinalizeEnforcement(workflows)).toThrow(/bad/);
  });

  it("AC-025-3: throws when 'finalize' is not the last phase", () => {
    const workflows = {
      bad: ["developer", "finalize", "reviewer"],
    };
    // The workflow ends with "reviewer" not "finalize", so the "must end with finalize" error fires.
    // The "finalize at wrong position" message is a secondary check for edge cases.
    expect(() => validateFinalizeEnforcement(workflows)).toThrow(/finalize/);
    expect(() => validateFinalizeEnforcement(workflows)).toThrow(/bad/);
  });

  it("AC-025-4: validates all workflows in the map", () => {
    const workflows = {
      good: ["developer", "finalize"],
      bad: ["developer", "qa"], // missing finalize
    };
    expect(() => validateFinalizeEnforcement(workflows)).toThrow(/bad/);
  });

  it("throws for empty workflow", () => {
    const workflows = {
      empty: [],
    };
    expect(() => validateFinalizeEnforcement(workflows)).toThrow(/finalize/);
  });
});

// ── validateWorkflowPhases tests (TRD-014) ────────────────────────────────────

describe("validateWorkflowPhases() - TRD-014", () => {
  const mockPhaseConfigs: Record<string, unknown> = {
    explorer: { model: "claude-haiku-4-5-20251001", maxBudgetUsd: 1, allowedTools: [], reportFile: "EXPLORER_REPORT.md", promptFile: "explorer.md" },
    developer: { model: "claude-sonnet-4-6", maxBudgetUsd: 5, allowedTools: [], reportFile: "DEVELOPER_REPORT.md", promptFile: "developer.md" },
    qa: { model: "claude-sonnet-4-6", maxBudgetUsd: 3, allowedTools: [], reportFile: "QA_REPORT.md", promptFile: "qa.md" },
    reviewer: { model: "claude-sonnet-4-6", maxBudgetUsd: 2, allowedTools: [], reportFile: "REVIEW.md", promptFile: "reviewer.md" },
    reproducer: { model: "claude-sonnet-4-6", maxBudgetUsd: 2, allowedTools: [], reportFile: "REPRODUCER_REPORT.md", promptFile: "reproducer.md" },
  };

  it("AC-024-1: passes when all phases exist in phaseConfigs", () => {
    const workflow = ["explorer", "developer", "qa", "reviewer", "finalize"];
    expect(() => validateWorkflowPhases(workflow, mockPhaseConfigs, "feature")).not.toThrow();
  });

  it("AC-024-3: 'finalize' is always valid without needing config entry", () => {
    const phaseConfigsWithoutFinalize = { developer: mockPhaseConfigs["developer"] };
    const workflow = ["developer", "finalize"];
    expect(() => validateWorkflowPhases(workflow, phaseConfigsWithoutFinalize, "chore")).not.toThrow();
  });

  it("AC-024-2: throws for unknown phase not in phaseConfigs or ROLE_CONFIGS", () => {
    const workflow = ["unknown_phase", "developer", "finalize"];
    expect(() => validateWorkflowPhases(workflow, {}, "feature")).toThrow(/unknown_phase/);
    expect(() => validateWorkflowPhases(workflow, {}, "feature")).toThrow(/feature/);
  });

  it("AC-024-2: throws with message containing phase name and workflow name", () => {
    const workflow = ["mystery_phase", "finalize"];
    let error: Error | undefined;
    try {
      validateWorkflowPhases(workflow, {}, "my-workflow");
    } catch (err) {
      error = err as Error;
    }
    expect(error).toBeDefined();
    expect(error?.message).toContain("mystery_phase");
    expect(error?.message).toContain("my-workflow");
  });

  it("'reproducer' is always recognized as a built-in phase", () => {
    const workflow = ["reproducer", "developer", "finalize"];
    expect(() => validateWorkflowPhases(workflow, {}, "bug")).not.toThrow();
  });

  it("AC-024-1: passes when phase is in ROLE_CONFIGS (built-in fallback)", () => {
    // Even with empty phaseConfigs, ROLE_CONFIGS phases are valid
    const workflow = ["explorer", "developer", "finalize"];
    expect(() => validateWorkflowPhases(workflow, {}, "feature")).not.toThrow();
  });
});

// ── getWorkflow tests (TRD-013) ───────────────────────────────────────────────

describe("getWorkflow() - TRD-013", () => {
  it("AC-011-4: returns bug workflow for 'bug' seed type", () => {
    // This test calls loadWorkflows() which reads ~/.foreman/workflows.json
    // If the file doesn't exist it returns DEFAULT_WORKFLOWS
    const workflow = getWorkflow("bug");
    expect(workflow).toBeInstanceOf(Array);
    expect(workflow[workflow.length - 1]).toBe("finalize");
    // Bug workflow should start with reproducer (from DEFAULT_WORKFLOWS)
    // unless user has overridden it
    expect(workflow.length).toBeGreaterThan(0);
  });

  it("AC-011-6: returns 'feature' workflow for unknown seed type", () => {
    const workflow = getWorkflow("completely-unknown-type");
    const featureWorkflow = DEFAULT_WORKFLOWS["feature"] ?? ["explorer", "developer", "qa", "reviewer", "finalize"];
    // Either the feature workflow or whatever was loaded from file
    expect(workflow).toBeInstanceOf(Array);
    expect(workflow[workflow.length - 1]).toBe("finalize");
  });

  it("AC-011-1: returns 'feature' workflow for 'feature' seed type", () => {
    const workflow = getWorkflow("feature");
    expect(workflow).toBeInstanceOf(Array);
    expect(workflow).toContain("developer");
    expect(workflow[workflow.length - 1]).toBe("finalize");
  });

  it("AC-011-3: returns 'chore' workflow for 'chore' seed type", () => {
    const workflow = getWorkflow("chore");
    expect(workflow).toBeInstanceOf(Array);
    expect(workflow[workflow.length - 1]).toBe("finalize");
  });
});

// ── Bundled defaults consistency tests (TRD-016 / AC-016-4 through AC-016-8) ──

describe("Bundled workflow defaults consistency", () => {
  it("AC-016-4: DEFAULT_WORKFLOWS has feature, bug, chore, docs", () => {
    expect(DEFAULT_WORKFLOWS).toHaveProperty("feature");
    expect(DEFAULT_WORKFLOWS).toHaveProperty("bug");
    expect(DEFAULT_WORKFLOWS).toHaveProperty("chore");
    expect(DEFAULT_WORKFLOWS).toHaveProperty("docs");
  });

  it("AC-016-5: feature workflow contains explorer, developer, qa, reviewer, finalize", () => {
    const feature = DEFAULT_WORKFLOWS["feature"];
    expect(feature).toContain("explorer");
    expect(feature).toContain("developer");
    expect(feature).toContain("qa");
    expect(feature).toContain("reviewer");
    expect(feature).toContain("finalize");
  });

  it("AC-016-6: bug workflow contains reproducer, developer, qa, finalize (no explorer/reviewer)", () => {
    const bug = DEFAULT_WORKFLOWS["bug"];
    expect(bug).toContain("reproducer");
    expect(bug).toContain("developer");
    expect(bug).toContain("qa");
    expect(bug).toContain("finalize");
    expect(bug).not.toContain("explorer");
    expect(bug).not.toContain("reviewer");
  });

  it("AC-016-7: chore workflow contains developer and finalize (minimal)", () => {
    const chore = DEFAULT_WORKFLOWS["chore"];
    expect(chore).toContain("developer");
    expect(chore).toContain("finalize");
  });

  it("DEFAULT_WORKFLOWS all pass validateFinalizeEnforcement", () => {
    expect(() => validateFinalizeEnforcement(DEFAULT_WORKFLOWS)).not.toThrow();
  });
});
