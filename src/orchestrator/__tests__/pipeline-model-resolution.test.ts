/**
 * QA tests for bd-0n5a: Workflow YAML model field is ignored
 *
 * Verifies that the pipeline executor correctly resolves models from:
 *   1. WorkflowPhaseConfig.models map (with priority overrides)
 *   2. Legacy WorkflowPhaseConfig.model field
 *   3. ROLE_CONFIGS fallback
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { resolvePhaseModel } from "../../lib/workflow-loader.js";
import { ROLE_CONFIGS } from "../roles.js";
import type { WorkflowPhaseConfig } from "../../lib/workflow-loader.js";

// ── resolvePhaseModel unit tests ──────────────────────────────────────────────

describe("resolvePhaseModel — model resolution priority", () => {
  it("uses phase.models[P0] when seedPriority is P0", () => {
    const phase: WorkflowPhaseConfig = {
      name: "developer",
      models: { default: "sonnet", P0: "opus" },
    };
    const result = resolvePhaseModel(phase, "P0", "anthropic/claude-haiku-4-5");
    expect(result).toBe("anthropic/claude-opus-4-6");
  });

  it("uses phase.models.default when seedPriority has no override", () => {
    const phase: WorkflowPhaseConfig = {
      name: "developer",
      models: { default: "sonnet", P0: "opus" },
    };
    const result = resolvePhaseModel(phase, "P3", "anthropic/claude-haiku-4-5");
    expect(result).toBe("anthropic/claude-sonnet-4-6");
  });

  it("uses phase.models.default when seedPriority is undefined", () => {
    const phase: WorkflowPhaseConfig = {
      name: "qa",
      models: { default: "haiku" },
    };
    const result = resolvePhaseModel(phase, undefined, "anthropic/claude-opus-4-6");
    expect(result).toBe("anthropic/claude-haiku-4-5");
  });

  it("accepts numeric priority string '0' as P0", () => {
    const phase: WorkflowPhaseConfig = {
      name: "reviewer",
      models: { default: "sonnet", P0: "opus" },
    };
    const result = resolvePhaseModel(phase, "0", "anthropic/claude-haiku-4-5");
    expect(result).toBe("anthropic/claude-opus-4-6");
  });

  it("falls back to legacy model field when models map is absent", () => {
    const phase: WorkflowPhaseConfig = {
      name: "explorer",
      model: "haiku",
    };
    const result = resolvePhaseModel(phase, "P0", "anthropic/claude-sonnet-4-6");
    expect(result).toBe("anthropic/claude-haiku-4-5");
  });

  it("falls back to ROLE_CONFIGS-derived fallback when no YAML model fields", () => {
    const phase: WorkflowPhaseConfig = { name: "developer" };
    const fallback = ROLE_CONFIGS["developer"].model;
    const result = resolvePhaseModel(phase, "P2", fallback);
    expect(result).toBe(fallback);
  });

  it("models map takes precedence over legacy model field", () => {
    const phase: WorkflowPhaseConfig = {
      name: "developer",
      model: "haiku",           // legacy: haiku
      models: { default: "sonnet" }, // new: sonnet
    };
    const result = resolvePhaseModel(phase, "P1", "anthropic/claude-opus-4-6");
    // models map wins → sonnet
    expect(result).toBe("anthropic/claude-sonnet-4-6");
  });
});

// ── ROLE_CONFIGS — verify fallback models are defined ─────────────────────────

describe("ROLE_CONFIGS — all pipeline roles have a model fallback", () => {
  const pipelineRoles = ["explorer", "developer", "qa", "reviewer", "finalize"] as const;

  for (const role of pipelineRoles) {
    it(`ROLE_CONFIGS[${role}].model is a non-empty string`, () => {
      expect(typeof ROLE_CONFIGS[role].model).toBe("string");
      expect(ROLE_CONFIGS[role].model.length).toBeGreaterThan(0);
    });
  }
});

// ── Integration: pipeline-executor uses resolvePhaseModel ────────────────────

describe("pipeline-executor.ts — resolvePhaseModel integration", () => {
  it("pipeline-executor imports resolvePhaseModel (not resolveWorkflowModel)", async () => {
    // Read source to verify the import was changed correctly
    const { readFileSync } = await import("node:fs");
    const { join } = await import("node:path");
    const src = readFileSync(
      join(import.meta.dirname, "..", "pipeline-executor.ts"),
      "utf-8",
    );
    expect(src).toContain('import { resolvePhaseModel }');
    expect(src).not.toContain('import { resolveWorkflowModel }');
  });

  it("pipeline-executor passes config.seedPriority to resolvePhaseModel", async () => {
    const { readFileSync } = await import("node:fs");
    const { join } = await import("node:path");
    const src = readFileSync(
      join(import.meta.dirname, "..", "pipeline-executor.ts"),
      "utf-8",
    );
    expect(src).toContain("config.seedPriority");
    expect(src).toContain("resolvePhaseModel(phase, config.seedPriority");
  });

  it("pipeline-executor passes resolved model to runPhase (not hardcoded)", async () => {
    const { readFileSync } = await import("node:fs");
    const { join } = await import("node:path");
    const src = readFileSync(
      join(import.meta.dirname, "..", "pipeline-executor.ts"),
      "utf-8",
    );
    // phaseModel is set and phaseConfig uses it
    expect(src).toContain("const phaseModel = resolvePhaseModel(");
    expect(src).toContain("const phaseConfig = { ...config, model: phaseModel }");
    expect(src).toContain("ctx.runPhase(\n      phaseName, prompt, phaseConfig,");
  });
});

// ── Integration: agent-worker uses resolved model ─────────────────────────────

describe("agent-worker.ts — uses config.model instead of roleConfig.model", () => {
  it("agent-worker uses resolvedModel from config.model, not roleConfig.model", async () => {
    const { readFileSync } = await import("node:fs");
    const { join } = await import("node:path");
    const src = readFileSync(
      join(import.meta.dirname, "..", "agent-worker.ts"),
      "utf-8",
    );
    // The resolved model should come from config.model
    expect(src).toContain("const resolvedModel: string = config.model || roleConfig.model");
    // Pi SDK call uses resolvedModel
    expect(src).toContain("model: resolvedModel");
    // agentByPhase records the resolved model
    expect(src).toContain("progress.agentByPhase[role] = resolvedModel");
  });
});

// ── Integration: dispatcher no longer has selectModel ─────────────────────────

describe("dispatcher.ts — selectModel removed", () => {
  it("dispatcher.ts does not export or define selectModel", async () => {
    const { readFileSync } = await import("node:fs");
    const { join } = await import("node:path");
    const src = readFileSync(
      join(import.meta.dirname, "..", "dispatcher.ts"),
      "utf-8",
    );
    expect(src).not.toContain("selectModel(task");
    expect(src).not.toContain("this.selectModel(");
  });

  it("dispatcher passes seedPriority to worker config", async () => {
    const { readFileSync } = await import("node:fs");
    const { join } = await import("node:path");
    const src = readFileSync(
      join(import.meta.dirname, "..", "dispatcher.ts"),
      "utf-8",
    );
    expect(src).toContain("seedPriority: seed.priority");
  });
});

// ── Integration: default.yaml and smoke.yaml use models map ──────────────────

describe("workflow YAML files — use models map", () => {
  it("default.yaml uses models map instead of single model field", async () => {
    const { readFileSync } = await import("node:fs");
    const { join } = await import("node:path");
    const yaml = readFileSync(
      join(import.meta.dirname, "..", "..", "..", "src", "defaults", "workflows", "default.yaml"),
      "utf-8",
    );
    // Should have models: blocks
    expect(yaml).toContain("models:");
    expect(yaml).toContain("default: ");
    // Should NOT have bare 'model: opus' or 'model: sonnet' at phase level
    // (only 'models:' blocks)
    const lines = yaml.split("\n");
    const bareModelLines = lines.filter(
      (l) => /^\s+model:\s+\w+/.test(l) && !l.includes("#"),
    );
    expect(bareModelLines).toHaveLength(0);
  });

  it("smoke.yaml uses models map instead of single model field", async () => {
    const { readFileSync } = await import("node:fs");
    const { join } = await import("node:path");
    const yaml = readFileSync(
      join(import.meta.dirname, "..", "..", "..", "src", "defaults", "workflows", "smoke.yaml"),
      "utf-8",
    );
    expect(yaml).toContain("models:");
    const lines = yaml.split("\n");
    const bareModelLines = lines.filter(
      (l) => /^\s+model:\s+\w+/.test(l) && !l.includes("#"),
    );
    expect(bareModelLines).toHaveLength(0);
  });
});
