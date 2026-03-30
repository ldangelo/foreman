/**
 * Tests for src/lib/workflow-loader.ts
 */
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import {
  mkdirSync,
  writeFileSync,
  rmSync,
  existsSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  loadWorkflowConfig,
  validateWorkflowConfig,
  installBundledWorkflows,
  findMissingWorkflows,
  resolveWorkflowName,
  resolvePhaseModel,
  WorkflowConfigError,
  BUNDLED_WORKFLOW_NAMES,
  type WorkflowSetupStep,
  type WorkflowPhaseConfig,
} from "../workflow-loader.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

function mkTmpDir(): string {
  const dir = join(tmpdir(), `foreman-wl-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  mkdirSync(dir, { recursive: true });
  return dir;
}

function writeWorkflowFile(projectRoot: string, name: string, content: string): void {
  const dir = join(projectRoot, ".foreman", "workflows");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${name}.yaml`), content, "utf-8");
}

// ── validateWorkflowConfig ────────────────────────────────────────────────────

describe("validateWorkflowConfig", () => {
  it("accepts a valid workflow config", () => {
    const raw = {
      name: "default",
      phases: [
        { name: "explorer", prompt: "explorer.md", model: "haiku", maxTurns: 30, skipIfArtifact: "EXPLORER_REPORT.md" },
        { name: "developer", prompt: "developer.md", model: "sonnet", maxTurns: 80 },
        { name: "qa", prompt: "qa.md", model: "sonnet", maxTurns: 30, retryOnFail: 2 },
        { name: "finalize", builtin: true },
      ],
    };
    const config = validateWorkflowConfig(raw, "default");
    expect(config.name).toBe("default");
    expect(config.phases).toHaveLength(4);
    expect(config.phases[0].name).toBe("explorer");
    expect(config.phases[0].skipIfArtifact).toBe("EXPLORER_REPORT.md");
    expect(config.phases[2].retryOnFail).toBe(2);
    expect(config.phases[3].builtin).toBe(true);
  });

  it("uses workflowName as fallback when name is missing", () => {
    const raw = { phases: [{ name: "finalize", builtin: true }] };
    const config = validateWorkflowConfig(raw, "my-workflow");
    expect(config.name).toBe("my-workflow");
  });

  it("throws on non-object input", () => {
    expect(() => validateWorkflowConfig("string", "w")).toThrow(WorkflowConfigError);
    expect(() => validateWorkflowConfig(null, "w")).toThrow(WorkflowConfigError);
    expect(() => validateWorkflowConfig(42, "w")).toThrow(WorkflowConfigError);
  });

  it("throws when phases is missing", () => {
    expect(() => validateWorkflowConfig({ name: "w" }, "w")).toThrow(WorkflowConfigError);
  });

  it("throws when phases is empty", () => {
    expect(() => validateWorkflowConfig({ phases: [] }, "w")).toThrow(WorkflowConfigError);
  });

  it("throws when a phase has no name", () => {
    const raw = { phases: [{ prompt: "x.md" }] };
    expect(() => validateWorkflowConfig(raw, "w")).toThrow(WorkflowConfigError);
  });

  it("ignores unknown phase fields", () => {
    const raw = { name: "w", phases: [{ name: "explorer", unknown: "field" }] };
    const config = validateWorkflowConfig(raw, "w");
    expect(config.phases[0].name).toBe("explorer");
    // unknown fields are simply not included
    expect((config.phases[0] as unknown as Record<string, unknown>)["unknown"]).toBeUndefined();
  });
});

// ── validateWorkflowConfig — setup block ─────────────────────────────────────

describe("validateWorkflowConfig — setup block", () => {
  const minimalPhases = [{ name: "finalize", builtin: true }];

  it("parses a setup block with all fields", () => {
    const raw = {
      name: "w",
      setup: [
        { command: "npm install --prefer-offline --no-audit", description: "Install deps", failFatal: true },
        { command: "make build", failFatal: false },
      ],
      phases: minimalPhases,
    };
    const config = validateWorkflowConfig(raw, "w");
    expect(config.setup).toHaveLength(2);
    const [step0, step1] = config.setup as WorkflowSetupStep[];
    expect(step0.command).toBe("npm install --prefer-offline --no-audit");
    expect(step0.description).toBe("Install deps");
    expect(step0.failFatal).toBe(true);
    expect(step1.command).toBe("make build");
    expect(step1.failFatal).toBe(false);
  });

  it("setup is optional — no setup block means config.setup is undefined", () => {
    const raw = { name: "w", phases: minimalPhases };
    const config = validateWorkflowConfig(raw, "w");
    expect(config.setup).toBeUndefined();
  });

  it("failFatal defaults to undefined (caller treats undefined as true)", () => {
    const raw = {
      name: "w",
      setup: [{ command: "npm install" }],
      phases: minimalPhases,
    };
    const config = validateWorkflowConfig(raw, "w");
    expect(config.setup![0].failFatal).toBeUndefined();
  });

  it("throws WorkflowConfigError when setup[i].command is missing", () => {
    const raw = {
      name: "w",
      setup: [{ description: "no command here" }],
      phases: minimalPhases,
    };
    expect(() => validateWorkflowConfig(raw, "w")).toThrow(WorkflowConfigError);
  });

  it("throws WorkflowConfigError when setup[i].command is empty string", () => {
    const raw = {
      name: "w",
      setup: [{ command: "" }],
      phases: minimalPhases,
    };
    expect(() => validateWorkflowConfig(raw, "w")).toThrow(WorkflowConfigError);
  });

  it("throws WorkflowConfigError when setup is not an array", () => {
    const raw = {
      name: "w",
      setup: "npm install",
      phases: minimalPhases,
    };
    expect(() => validateWorkflowConfig(raw, "w")).toThrow(WorkflowConfigError);
  });

  it("throws WorkflowConfigError when a setup entry is not an object", () => {
    const raw = {
      name: "w",
      setup: ["npm install"],
      phases: minimalPhases,
    };
    expect(() => validateWorkflowConfig(raw, "w")).toThrow(WorkflowConfigError);
  });
});

describe("loadWorkflowConfig — setup block integration", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("bundled default workflow has a setup block", () => {
    const config = loadWorkflowConfig("default", tmpDir);
    expect(config.setup).toBeDefined();
    expect(Array.isArray(config.setup)).toBe(true);
    expect(config.setup!.length).toBeGreaterThan(0);
    expect(config.setup![0].command).toBeTruthy();
  });

  it("bundled smoke workflow has a setup block", () => {
    const config = loadWorkflowConfig("smoke", tmpDir);
    expect(config.setup).toBeDefined();
    expect(config.setup![0].command).toBeTruthy();
  });

  it("project-local workflow without setup block has undefined setup", () => {
    writeWorkflowFile(tmpDir, "default", `
name: default
phases:
  - name: finalize
    builtin: true
`);
    const config = loadWorkflowConfig("default", tmpDir);
    expect(config.setup).toBeUndefined();
  });

  it("project-local workflow with setup block parses correctly", () => {
    writeWorkflowFile(tmpDir, "default", `
name: default
setup:
  - command: bundle install
    description: Install Ruby gems
    failFatal: true
phases:
  - name: developer
    prompt: developer.md
  - name: finalize
    builtin: true
`);
    const config = loadWorkflowConfig("default", tmpDir);
    expect(config.setup).toHaveLength(1);
    expect(config.setup![0].command).toBe("bundle install");
    expect(config.setup![0].description).toBe("Install Ruby gems");
    expect(config.setup![0].failFatal).toBe(true);
  });
});

// ── loadWorkflowConfig ────────────────────────────────────────────────────────

describe("loadWorkflowConfig", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("loads a valid project-local workflow YAML", () => {
    writeWorkflowFile(tmpDir, "default", `
name: default
phases:
  - name: developer
    prompt: developer.md
  - name: finalize
    builtin: true
`);
    const config = loadWorkflowConfig("default", tmpDir);
    expect(config.name).toBe("default");
    expect(config.phases).toHaveLength(2);
    expect(config.phases[0].name).toBe("developer");
    expect(config.phases[1].builtin).toBe(true);
  });

  it("falls back to bundled defaults when no project-local file exists", () => {
    // tmpDir has no .foreman/workflows/ — should fall through to bundled defaults
    const config = loadWorkflowConfig("default", tmpDir);
    expect(config.name).toBe("default");
    expect(config.phases.length).toBeGreaterThan(0);
    expect(config.phases.some((p) => p.name === "explorer")).toBe(true);
    expect(config.phases.some((p) => p.name === "finalize")).toBe(true);
  });

  it("loads bundled smoke workflow", () => {
    const config = loadWorkflowConfig("smoke", tmpDir);
    expect(config.name).toBe("smoke");
    expect(config.phases.some((p) => p.name === "explorer")).toBe(true);
    expect(config.phases.some((p) => p.name === "developer")).toBe(true);
  });

  it("throws WorkflowConfigError for unknown workflow with no bundled default", () => {
    expect(() => loadWorkflowConfig("nonexistent-workflow", tmpDir)).toThrow(WorkflowConfigError);
  });

  it("project-local file takes precedence over bundled defaults", () => {
    writeWorkflowFile(tmpDir, "default", `
name: custom-default
phases:
  - name: developer
    prompt: developer.md
    model: haiku
  - name: finalize
    builtin: true
`);
    const config = loadWorkflowConfig("default", tmpDir);
    // Name comes from the YAML content
    expect(config.name).toBe("custom-default");
    // Only 2 phases (no explorer, qa, reviewer) - confirming project-local was used
    expect(config.phases).toHaveLength(2);
  });

  it("throws WorkflowConfigError for invalid YAML", () => {
    writeWorkflowFile(tmpDir, "broken", `
name: broken
phases:
  - name:     # missing value — structurally invalid
    builtin: true
`);
    expect(() => loadWorkflowConfig("broken", tmpDir)).toThrow(WorkflowConfigError);
  });

  it("bundled default workflow has qa phase with retryOnFail", () => {
    const config = loadWorkflowConfig("default", tmpDir);
    const qaPhase = config.phases.find((p) => p.name === "qa");
    expect(qaPhase).toBeDefined();
    expect(typeof qaPhase?.retryOnFail).toBe("number");
    expect(qaPhase!.retryOnFail).toBeGreaterThan(0);
  });

  it("bundled default workflow has explorer with skipIfArtifact", () => {
    const config = loadWorkflowConfig("default", tmpDir);
    const explorerPhase = config.phases.find((p) => p.name === "explorer");
    expect(explorerPhase).toBeDefined();
    expect(explorerPhase?.skipIfArtifact).toBe("EXPLORER_REPORT.md");
  });
});

// ── installBundledWorkflows ───────────────────────────────────────────────────

describe("installBundledWorkflows", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("installs all bundled workflow files", () => {
    const { installed, skipped } = installBundledWorkflows(tmpDir);
    expect(installed.length).toBeGreaterThan(0);
    expect(skipped).toHaveLength(0);
    for (const name of BUNDLED_WORKFLOW_NAMES) {
      expect(existsSync(join(tmpDir, ".foreman", "workflows", `${name}.yaml`))).toBe(true);
    }
  });

  it("skips existing files by default", () => {
    installBundledWorkflows(tmpDir); // first install
    const { installed, skipped } = installBundledWorkflows(tmpDir); // second install
    expect(installed).toHaveLength(0);
    expect(skipped.length).toBeGreaterThan(0);
  });

  it("overwrites existing files when force=true", () => {
    installBundledWorkflows(tmpDir); // first install
    const { installed } = installBundledWorkflows(tmpDir, true); // force reinstall
    expect(installed.length).toBeGreaterThan(0);
  });

  it("creates .foreman/workflows/ directory if missing", () => {
    const workflowsDir = join(tmpDir, ".foreman", "workflows");
    expect(existsSync(workflowsDir)).toBe(false);
    installBundledWorkflows(tmpDir);
    expect(existsSync(workflowsDir)).toBe(true);
  });
});

// ── findMissingWorkflows ──────────────────────────────────────────────────────

describe("findMissingWorkflows", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns all bundled workflow names when nothing is installed", () => {
    const missing = findMissingWorkflows(tmpDir);
    expect(missing).toEqual(expect.arrayContaining([...BUNDLED_WORKFLOW_NAMES]));
  });

  it("returns empty array when all workflows are installed", () => {
    installBundledWorkflows(tmpDir);
    const missing = findMissingWorkflows(tmpDir);
    expect(missing).toHaveLength(0);
  });

  it("returns only the missing workflow names", () => {
    // Install only 'default', leaving 'smoke' missing
    const workflowsDir = join(tmpDir, ".foreman", "workflows");
    mkdirSync(workflowsDir, { recursive: true });
    writeFileSync(join(workflowsDir, "default.yaml"), "name: default\nphases:\n  - name: finalize\n    builtin: true\n");

    const missing = findMissingWorkflows(tmpDir);
    expect(missing).toContain("smoke");
    expect(missing).not.toContain("default");
  });
});

// ── resolveWorkflowName ───────────────────────────────────────────────────────

describe("resolveWorkflowName", () => {
  it("returns 'smoke' for smoke bead type", () => {
    expect(resolveWorkflowName("smoke")).toBe("smoke");
  });

  it("returns 'epic' for epic bead type", () => {
    expect(resolveWorkflowName("epic")).toBe("epic");
  });

  it("returns 'default' for feature bead type", () => {
    expect(resolveWorkflowName("feature")).toBe("default");
  });

  it("returns 'default' for bug bead type", () => {
    expect(resolveWorkflowName("bug")).toBe("default");
  });

  it("returns 'default' for task bead type", () => {
    expect(resolveWorkflowName("task")).toBe("default");
  });

  it("returns workflow label override when present", () => {
    expect(resolveWorkflowName("feature", ["workflow:smoke"])).toBe("smoke");
    expect(resolveWorkflowName("feature", ["phase:explorer", "workflow:custom"])).toBe("custom");
  });

  it("label override takes precedence over bead type", () => {
    expect(resolveWorkflowName("smoke", ["workflow:default"])).toBe("default");
  });

  it("ignores non-workflow labels", () => {
    expect(resolveWorkflowName("feature", ["phase:explorer", "priority:high"])).toBe("default");
  });

  it("returns 'default' when labels array is empty", () => {
    expect(resolveWorkflowName("feature", [])).toBe("default");
  });

  it("returns 'default' when labels is undefined", () => {
    expect(resolveWorkflowName("feature", undefined)).toBe("default");
  });
});

// ── validateWorkflowConfig — models map ──────────────────────────────────────

describe("validateWorkflowConfig — models map", () => {
  const minimalPhases = [{ name: "finalize", builtin: true }];

  it("parses a models map with default and priority overrides", () => {
    const raw = {
      name: "w",
      phases: [
        {
          name: "developer",
          models: { default: "sonnet", P0: "opus", P1: "sonnet" },
        },
        ...minimalPhases,
      ],
    };
    const config = validateWorkflowConfig(raw, "w");
    const devPhase = config.phases[0];
    expect(devPhase.models).toBeDefined();
    expect(devPhase.models!["default"]).toBe("sonnet");
    expect(devPhase.models!["P0"]).toBe("opus");
    expect(devPhase.models!["P1"]).toBe("sonnet");
  });

  it("accepts models map with only 'default' key", () => {
    const raw = {
      name: "w",
      phases: [{ name: "explorer", models: { default: "haiku" } }],
    };
    const config = validateWorkflowConfig(raw, "w");
    expect(config.phases[0].models).toEqual({ default: "haiku" });
  });

  it("throws on invalid models map key", () => {
    const raw = {
      name: "w",
      phases: [{ name: "explorer", models: { default: "haiku", P5: "opus" } }],
    };
    expect(() => validateWorkflowConfig(raw, "w")).toThrow(WorkflowConfigError);
  });

  it("throws on non-string models map value", () => {
    const raw = {
      name: "w",
      phases: [{ name: "explorer", models: { default: 42 } }],
    };
    expect(() => validateWorkflowConfig(raw, "w")).toThrow(WorkflowConfigError);
  });

  it("throws on empty string models map value", () => {
    const raw = {
      name: "w",
      phases: [{ name: "explorer", models: { default: "" } }],
    };
    expect(() => validateWorkflowConfig(raw, "w")).toThrow(WorkflowConfigError);
  });

  it("coexists with legacy 'model' field (models takes precedence)", () => {
    const raw = {
      name: "w",
      phases: [{ name: "developer", model: "haiku", models: { default: "sonnet" } }],
    };
    const config = validateWorkflowConfig(raw, "w");
    // Both fields are preserved; resolvePhaseModel() determines precedence
    expect(config.phases[0].model).toBe("haiku");
    expect(config.phases[0].models).toEqual({ default: "sonnet" });
  });

  it("bundled default workflow phases have models map", () => {
    // Bundled YAMLs have been updated to models map
    const tmpDir2 = tmpdir() + `/wl-test-${Date.now()}`;
    mkdirSync(tmpDir2, { recursive: true });
    const config = loadWorkflowConfig("default", tmpDir2);
    rmSync(tmpDir2, { recursive: true, force: true });
    for (const phase of config.phases) {
      if (!phase.builtin) {
        expect(phase.models).toBeDefined();
        expect(phase.models!["default"]).toBeTruthy();
      }
    }
  });
});

// ── resolvePhaseModel ─────────────────────────────────────────────────────────

describe("resolvePhaseModel", () => {
  const fallback = "anthropic/claude-haiku-4-5";

  it("uses priority override when priority matches", () => {
    const phase: WorkflowPhaseConfig = {
      name: "developer",
      models: { default: "sonnet", P0: "opus" },
    };
    expect(resolvePhaseModel(phase, "P0", fallback)).toBe("anthropic/claude-opus-4-6");
  });

  it("falls back to models.default when priority has no override", () => {
    const phase: WorkflowPhaseConfig = {
      name: "developer",
      models: { default: "sonnet", P0: "opus" },
    };
    expect(resolvePhaseModel(phase, "P2", fallback)).toBe("anthropic/claude-sonnet-4-6");
  });

  it("falls back to models.default when priority is undefined", () => {
    const phase: WorkflowPhaseConfig = {
      name: "developer",
      models: { default: "haiku" },
    };
    expect(resolvePhaseModel(phase, undefined, fallback)).toBe("anthropic/claude-haiku-4-5");
  });

  it("accepts numeric string priority '0' as P0", () => {
    const phase: WorkflowPhaseConfig = {
      name: "developer",
      models: { default: "sonnet", P0: "opus" },
    };
    expect(resolvePhaseModel(phase, "0", fallback)).toBe("anthropic/claude-opus-4-6");
  });

  it("falls back to legacy model field when no models map", () => {
    const phase: WorkflowPhaseConfig = { name: "developer", model: "haiku" };
    expect(resolvePhaseModel(phase, "P0", fallback)).toBe("anthropic/claude-haiku-4-5");
  });

  it("falls back to fallbackModel when no models map or model field", () => {
    const phase: WorkflowPhaseConfig = { name: "developer" };
    expect(resolvePhaseModel(phase, "P0", fallback)).toBe(fallback);
  });

  it("returns fallback when fallbackModel is the only option", () => {
    const phase: WorkflowPhaseConfig = { name: "finalize", builtin: true };
    expect(resolvePhaseModel(phase, undefined, fallback)).toBe(fallback);
  });

  it("expands shorthands in models map (haiku → full ID)", () => {
    const phase: WorkflowPhaseConfig = {
      name: "explorer",
      models: { default: "haiku" },
    };
    expect(resolvePhaseModel(phase, undefined, fallback)).toBe("anthropic/claude-haiku-4-5");
  });

  it("expands shorthands in legacy model field", () => {
    const phase: WorkflowPhaseConfig = { name: "explorer", model: "sonnet" };
    expect(resolvePhaseModel(phase, undefined, fallback)).toBe("anthropic/claude-sonnet-4-6");
  });

  it("passes through full model IDs unchanged (custom provider)", () => {
    const phase: WorkflowPhaseConfig = {
      name: "developer",
      models: { default: "openai/gpt-4o", P0: "google/gemini-2.0-pro" },
    };
    expect(resolvePhaseModel(phase, "P1", fallback)).toBe("openai/gpt-4o");
    expect(resolvePhaseModel(phase, "P0", fallback)).toBe("google/gemini-2.0-pro");
  });

  it("treats unrecognised priority string as missing (falls back to default)", () => {
    const phase: WorkflowPhaseConfig = {
      name: "developer",
      models: { default: "sonnet", P0: "opus" },
    };
    // "high" is not a valid priority key → use default
    expect(resolvePhaseModel(phase, "high", fallback)).toBe("anthropic/claude-sonnet-4-6");
  });
});

// ── validateWorkflowConfig — vcs block ────────────────────────────────────────

describe("validateWorkflowConfig — vcs block", () => {
  const minimalConfig = {
    name: "test",
    phases: [{ name: "developer", prompt: "developer.md" }],
  };

  it("parses vcs.backend='git'", () => {
    const config = validateWorkflowConfig(
      { ...minimalConfig, vcs: { backend: "git" } },
      "test",
    );
    expect(config.vcs?.backend).toBe("git");
  });

  it("parses vcs.backend='jujutsu'", () => {
    const config = validateWorkflowConfig(
      { ...minimalConfig, vcs: { backend: "jujutsu" } },
      "test",
    );
    expect(config.vcs?.backend).toBe("jujutsu");
  });

  it("parses vcs.backend='auto'", () => {
    const config = validateWorkflowConfig(
      { ...minimalConfig, vcs: { backend: "auto" } },
      "test",
    );
    expect(config.vcs?.backend).toBe("auto");
  });

  it("leaves vcs undefined when not present", () => {
    const config = validateWorkflowConfig(minimalConfig, "test");
    expect(config.vcs).toBeUndefined();
  });

  it("throws WorkflowConfigError for invalid vcs.backend value", () => {
    expect(() =>
      validateWorkflowConfig(
        { ...minimalConfig, vcs: { backend: "svn" } },
        "test",
      ),
    ).toThrow(/vcs.backend must be/);
  });
});

// ── validateWorkflowConfig — epic mode (taskPhases, finalPhases) ────────────

describe("validateWorkflowConfig — epic mode", () => {
  const epicConfig = {
    name: "epic",
    phases: [
      { name: "developer", prompt: "developer.md" },
      { name: "qa", prompt: "qa.md", verdict: true, retryWith: "developer", retryOnFail: 2 },
      { name: "finalize", prompt: "finalize.md" },
    ],
  };

  it("parses taskPhases and finalPhases from YAML", () => {
    const raw = {
      ...epicConfig,
      taskPhases: ["developer", "qa"],
      finalPhases: ["finalize"],
    };
    const config = validateWorkflowConfig(raw, "epic");
    expect(config.taskPhases).toEqual(["developer", "qa"]);
    expect(config.finalPhases).toEqual(["finalize"]);
  });

  it("leaves taskPhases and finalPhases undefined when absent (single-task mode)", () => {
    const config = validateWorkflowConfig(epicConfig, "default");
    expect(config.taskPhases).toBeUndefined();
    expect(config.finalPhases).toBeUndefined();
  });

  it("throws on non-array taskPhases", () => {
    const raw = { ...epicConfig, taskPhases: "developer" };
    expect(() => validateWorkflowConfig(raw, "epic")).toThrow(
      /taskPhases.*must be an array/,
    );
  });

  it("throws on non-array finalPhases", () => {
    const raw = { ...epicConfig, finalPhases: "finalize" };
    expect(() => validateWorkflowConfig(raw, "epic")).toThrow(
      /finalPhases.*must be an array/,
    );
  });

  it("throws when taskPhases references a phase not in phases array", () => {
    const raw = { ...epicConfig, taskPhases: ["developer", "explorer"] };
    expect(() => validateWorkflowConfig(raw, "epic")).toThrow(
      /references phase 'explorer' which is not defined/,
    );
  });

  it("throws when finalPhases references a phase not in phases array", () => {
    const raw = { ...epicConfig, finalPhases: ["nonexistent"] };
    expect(() => validateWorkflowConfig(raw, "epic")).toThrow(
      /references phase 'nonexistent' which is not defined/,
    );
  });

  it("throws on non-string entry in taskPhases", () => {
    const raw = { ...epicConfig, taskPhases: ["developer", 42] };
    expect(() => validateWorkflowConfig(raw, "epic")).toThrow(
      /taskPhases\[1\] must be a non-empty string/,
    );
  });

  it("throws on empty string entry in taskPhases", () => {
    const raw = { ...epicConfig, taskPhases: ["developer", ""] };
    expect(() => validateWorkflowConfig(raw, "epic")).toThrow(
      /taskPhases\[1\] must be a non-empty string/,
    );
  });

  it("bundled epic.yaml loads with taskPhases and finalPhases", () => {
    const tmpDir2 = tmpdir() + `/wl-epic-test-${Date.now()}`;
    mkdirSync(tmpDir2, { recursive: true });
    const config = loadWorkflowConfig("epic", tmpDir2);
    rmSync(tmpDir2, { recursive: true, force: true });
    expect(config.name).toBe("epic");
    expect(config.taskPhases).toEqual(["developer", "qa"]);
    expect(config.finalPhases).toEqual(["finalize"]);
    expect(config.phases.length).toBeGreaterThanOrEqual(3);
  });

  it("includes 'epic' in BUNDLED_WORKFLOW_NAMES", () => {
    expect(BUNDLED_WORKFLOW_NAMES).toContain("epic");
  });
});
