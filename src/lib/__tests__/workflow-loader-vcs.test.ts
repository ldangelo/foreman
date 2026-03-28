/**
 * Tests for the VCS key in workflow YAML (TRD-024-TEST).
 *
 * Acceptance criteria:
 *   AC-T-024-1: Given YAML with vcs.backend = 'git', config.vcs.backend === 'git'.
 *   AC-T-024-2: Given YAML without vcs key, config.vcs is undefined.
 *   AC-T-024-3: Given YAML with vcs.backend = 'bad', WorkflowConfigError is thrown.
 */

import { describe, it, expect } from "vitest";
import {
  validateWorkflowConfig,
  WorkflowConfigError,
} from "../workflow-loader.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Minimal valid raw workflow config (no vcs key). */
function minimalRaw(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    name: "test",
    phases: [{ name: "developer", prompt: "developer.md" }],
    ...overrides,
  };
}

// ── AC-T-024-1: Valid VCS backends ────────────────────────────────────────────

describe("validateWorkflowConfig — vcs: valid backends (AC-T-024-1)", () => {
  it("parses vcs.backend='git'", () => {
    const config = validateWorkflowConfig(
      minimalRaw({ vcs: { backend: "git" } }),
      "test",
    );
    expect(config.vcs?.backend).toBe("git");
  });

  it("parses vcs.backend='jujutsu'", () => {
    const config = validateWorkflowConfig(
      minimalRaw({ vcs: { backend: "jujutsu" } }),
      "test",
    );
    expect(config.vcs?.backend).toBe("jujutsu");
  });

  it("parses vcs.backend='auto'", () => {
    const config = validateWorkflowConfig(
      minimalRaw({ vcs: { backend: "auto" } }),
      "test",
    );
    expect(config.vcs?.backend).toBe("auto");
  });
});

// ── AC-T-024-2: Missing VCS key ───────────────────────────────────────────────

describe("validateWorkflowConfig — vcs absent (AC-T-024-2)", () => {
  it("leaves config.vcs undefined when vcs key is not present", () => {
    const config = validateWorkflowConfig(minimalRaw(), "test");
    expect(config.vcs).toBeUndefined();
  });
});

// ── AC-T-024-3: Invalid VCS backend values ────────────────────────────────────

describe("validateWorkflowConfig — vcs: invalid backend (AC-T-024-3)", () => {
  it("throws WorkflowConfigError for vcs.backend='svn'", () => {
    expect(() =>
      validateWorkflowConfig(minimalRaw({ vcs: { backend: "svn" } }), "test"),
    ).toThrow(WorkflowConfigError);
  });

  it("throws WorkflowConfigError for vcs.backend='mercurial'", () => {
    expect(() =>
      validateWorkflowConfig(
        minimalRaw({ vcs: { backend: "mercurial" } }),
        "test",
      ),
    ).toThrow(WorkflowConfigError);
  });

  it("throws WorkflowConfigError for vcs.backend='' (empty string)", () => {
    expect(() =>
      validateWorkflowConfig(minimalRaw({ vcs: { backend: "" } }), "test"),
    ).toThrow(WorkflowConfigError);
  });

  it("error message mentions valid values", () => {
    expect(() =>
      validateWorkflowConfig(minimalRaw({ vcs: { backend: "bad" } }), "test"),
    ).toThrow(/vcs\.backend must be/);
  });

  it("error message includes the invalid value", () => {
    expect(() =>
      validateWorkflowConfig(
        minimalRaw({ vcs: { backend: "unknown-vcs" } }),
        "test",
      ),
    ).toThrow(/unknown-vcs/);
  });
});

// ── Edge cases ────────────────────────────────────────────────────────────────

describe("validateWorkflowConfig — vcs: edge cases", () => {
  it("ignores vcs block when it is not an object (string)", () => {
    // A non-record vcs value is silently ignored by isRecord() guard
    const config = validateWorkflowConfig(
      minimalRaw({ vcs: "git" }),
      "test",
    );
    expect(config.vcs).toBeUndefined();
  });

  it("ignores vcs block when it is not an object (array)", () => {
    const config = validateWorkflowConfig(
      minimalRaw({ vcs: ["git"] }),
      "test",
    );
    expect(config.vcs).toBeUndefined();
  });

  it("ignores vcs block when it is null", () => {
    const config = validateWorkflowConfig(minimalRaw({ vcs: null }), "test");
    expect(config.vcs).toBeUndefined();
  });

  it("throws WorkflowConfigError when vcs.backend is a number", () => {
    expect(() =>
      validateWorkflowConfig(minimalRaw({ vcs: { backend: 42 } }), "test"),
    ).toThrow(WorkflowConfigError);
  });

  it("throws WorkflowConfigError when vcs.backend is a boolean", () => {
    expect(() =>
      validateWorkflowConfig(minimalRaw({ vcs: { backend: true } }), "test"),
    ).toThrow(WorkflowConfigError);
  });

  it("uses workflow name in error message", () => {
    expect(() =>
      validateWorkflowConfig(
        minimalRaw({ vcs: { backend: "bad" } }),
        "my-workflow",
      ),
    ).toThrow(/my-workflow/);
  });
});
