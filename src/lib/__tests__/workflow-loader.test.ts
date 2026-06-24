/**
 * Tests for src/lib/workflow-loader.ts
 */
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import {
  mkdirSync,
  writeFileSync,
  readFileSync,
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
  hasWorkflowConfig,
  listAvailableWorkflows,
  ensureBundledWorkflowsInstalled,
  WorkflowConfigError,
  BUNDLED_WORKFLOW_NAMES,
  getBundledWorkflowPath,
  buildTaskTypeWorkflowMap,
  validateTaskTypeUniqueness,
  type WorkflowSetupStep,
  type WorkflowPhaseConfig,
} from "../workflow-loader.js";
import { inferPhaseActionType } from "../../orchestrator/phase-actions.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

function mkTmpDir(): string {
  const dir = join(tmpdir(), `foreman-wl-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  mkdirSync(dir, { recursive: true });
  return dir;
}

function writeWorkflowFile(foremanHome: string, name: string, content: string): void {
  const dir = join(foremanHome, "workflows");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${name}.yaml`), content, "utf-8");
}

// ── validateWorkflowConfig ────────────────────────────────────────────────────

describe("validateWorkflowConfig", () => {
  it("rejects unsafe workflow config names", () => {
    expect(() => validateWorkflowConfig({ name: "../escape", phases: [{ name: "developer", prompt: "developer.md" }] }, "custom")).toThrow(/safe workflow name/);
  });

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

  it("rejects unsafe phase action declarations", () => {
    expect(() => validateWorkflowConfig({
      name: "custom",
      phases: [{ name: "notify", action: "../notify" }],
    }, "custom")).toThrow(WorkflowConfigError);
  });

  it("parses explicit phase action declarations", () => {
    const raw = {
      name: "default",
      phases: [
        { name: "reviewer", action: "prompt-agent", prompt: "reviewer.md" },
        { name: "auto-smoke", action: "bash", bash: "npm test" },
      ],
    };
    const config = validateWorkflowConfig(raw, "default");
    expect(config.phases[0].action).toBe("prompt-agent");
    expect(config.phases[1].action).toBe("bash");
  });

  it("allows custom project actions without prompt/bash/command", () => {
    const config = validateWorkflowConfig({
      name: "custom",
      phases: [{ name: "notify", action: "notify-slack" }],
    }, "custom");
    expect(config.phases[0].action).toBe("notify-slack");
  });

  it("rejects unsafe phase names", () => {
    expect(() => validateWorkflowConfig({
      name: "default",
      phases: [{ name: "bad phase", prompt: "developer.md" }],
    }, "default")).toThrow(/safe phase name/);
  });

  it("rejects duplicate phase names", () => {
    expect(() => validateWorkflowConfig({
      name: "default",
      phases: [
        { name: "developer", prompt: "developer.md" },
        { name: "developer", prompt: "developer.md" },
      ],
    }, "default")).toThrow(/duplicate phase name/);
  });

  it("rejects retryWith references to unknown phases", () => {
    expect(() => validateWorkflowConfig({
      name: "default",
      phases: [
        { name: "qa", prompt: "qa.md", retryWith: "developer" },
      ],
    }, "default")).toThrow(/retryWith references unknown phase/);
  });

  it("rejects mail.onFail references to unknown phases", () => {
    expect(() => validateWorkflowConfig({
      name: "default",
      phases: [
        { name: "qa", prompt: "qa.md", mail: { onFail: "developer" } },
      ],
    }, "default")).toThrow(/mail\.onFail references unknown phase/);
  });

  it("rejects mail.forwardArtifactTo references to unknown phases except foreman", () => {
    expect(() => validateWorkflowConfig({
      name: "default",
      phases: [
        { name: "explorer", prompt: "explorer.md", mail: { forwardArtifactTo: "developer" } },
      ],
    }, "default")).toThrow(/mail\.forwardArtifactTo references unknown phase/);

    const config = validateWorkflowConfig({
      name: "default",
      phases: [
        { name: "explorer", prompt: "explorer.md", mail: { forwardArtifactTo: "foreman" } },
      ],
    }, "default");
    expect(config.phases[0].mail?.forwardArtifactTo).toBe("foreman");
  });

  it("rejects invalid contract and overwatch controls", () => {
    for (const phase of [
      { name: "developer", prompt: "developer.md", contract: { requiredSections: [""] } },
      { name: "developer", prompt: "developer.md", contract: { completion: { minEditTargets: 2, maxEditTargets: 1 } } },
      { name: "developer", prompt: "developer.md", contract: { allowedScope: { canWriteOnly: [""] } } },
      { name: "developer", prompt: "developer.md", overwatch: { checkEveryTurns: 0 } },
      { name: "developer", prompt: "developer.md", overwatch: { maxToolCalls: -1 } },
      { name: "developer", prompt: "developer.md", overwatch: { blockedCommands: [""] } },
    ]) {
      expect(() => validateWorkflowConfig({ name: "default", phases: [phase] }, "default")).toThrow(WorkflowConfigError);
    }
  });

  it("rejects invalid numeric phase controls", () => {
    for (const phase of [
      { name: "developer", prompt: "developer.md", maxTurns: 0 },
      { name: "developer", prompt: "developer.md", timeoutSecs: -1 },
      { name: "developer", prompt: "developer.md", retryOnFail: 1.5 },
      { name: "developer", prompt: "developer.md", cooldownSeconds: 0 },
      { name: "developer", prompt: "developer.md", files: { leaseSecs: 0 } },
    ]) {
      expect(() => validateWorkflowConfig({ name: "default", phases: [phase] }, "default")).toThrow(WorkflowConfigError);
    }
  });

  it("rejects invalid action capabilities", () => {
    expect(() => validateWorkflowConfig({
      name: "default",
      phases: [{ name: "notify", action: "notify", capabilities: ["mail", ""] }],
    }, "default")).toThrow(WorkflowConfigError);
    expect(() => validateWorkflowConfig({
      name: "default",
      phases: [{ name: "notify", action: "notify", capabilities: "mail" }],
    }, "default")).toThrow(WorkflowConfigError);
  });

  it("parses action capabilities", () => {
    const raw = {
      name: "default",
      phases: [
        { name: "create-pr", action: "create-pr", builtin: true, capabilities: ["vcs", "mail", "network"] },
      ],
    };
    const config = validateWorkflowConfig(raw, "default");
    expect(config.phases[0].capabilities).toEqual(["vcs", "mail", "network"]);
  });

  it("parses declarative contract policies", () => {
    const raw = {
      name: "default",
      phases: [
        {
          name: "qa",
          action: "prompt-agent",
          prompt: "qa.md",
          contract: {
            policy: {
              acceptanceCoverage: true,
              testEvidence: true,
              captureQaTarget: true,
              terminalOnFailExhausted: true,
            },
          },
        },
      ],
    };
    const config = validateWorkflowConfig(raw, "default");
    expect(config.phases[0].contract?.policy).toMatchObject({
      acceptanceCoverage: true,
      testEvidence: true,
      captureQaTarget: true,
      terminalOnFailExhausted: true,
    });
  });

  it("parses retryAfterCooldown and cooldownSeconds from phase config", () => {
    const raw = {
      name: "default",
      phases: [
        { name: "cli-review", builtin: true, retryAfterCooldown: true, cooldownSeconds: 600 },
        { name: "developer", prompt: "developer.md" },
      ],
    };
    const config = validateWorkflowConfig(raw, "default");
    expect(config.phases[0].retryAfterCooldown).toBe(true);
    expect(config.phases[0].cooldownSeconds).toBe(600);
    expect(config.phases[1].retryAfterCooldown).toBeUndefined();
    expect(config.phases[1].cooldownSeconds).toBeUndefined();
  });

  it("treats retryAfterCooldown as optional (defaults to undefined when not set)", () => {
    const raw = {
      name: "default",
      phases: [
        { name: "cli-review", builtin: true },
      ],
    };
    const config = validateWorkflowConfig(raw, "default");
    expect(config.phases[0].retryAfterCooldown).toBeUndefined();
    expect(config.phases[0].cooldownSeconds).toBeUndefined();
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
    const raw = { name: "w", phases: [{ name: "explorer", prompt: "explorer.md", unknown: "field" }] };
    const config = validateWorkflowConfig(raw, "w");
    expect(config.phases[0].name).toBe("explorer");
    // unknown fields are simply not included
    expect((config.phases[0] as unknown as Record<string, unknown>)["unknown"]).toBeUndefined();
  });

  it("parses per-phase tool allowlists", () => {
    const raw = {
      name: "w",
      phases: [{
        name: "pr-review",
        prompt: "pr-review.md",
        tools: { allowed: ["Bash", "Edit", "Read", "Write"] },
      }],
    };
    const config = validateWorkflowConfig(raw, "w");
    expect(config.phases[0].tools?.allowed).toEqual(["Bash", "Edit", "Read", "Write"]);
  });

  it("throws when tools.allowed is not a string array", () => {
    expect(() => validateWorkflowConfig({
      name: "w",
      phases: [{ name: "developer", prompt: "developer.md", tools: { allowed: ["Read", ""] } }],
    }, "w")).toThrow(WorkflowConfigError);
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
    process.env["FOREMAN_HOME"] = tmpDir;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
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

  it("global workflow without setup block has undefined setup", () => {
    writeWorkflowFile(tmpDir, "default", `
name: default
phases:
  - name: finalize
    builtin: true
`);
    const config = loadWorkflowConfig("default", tmpDir);
    expect(config.setup).toBeUndefined();
  });

  it("global workflow with setup block parses correctly", () => {
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
    process.env["FOREMAN_HOME"] = tmpDir;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("loads a valid global workflow YAML", () => {
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

  it("does not resolve unsafe names through bundled workflow paths", () => {
    expect(getBundledWorkflowPath("../escape")).toBeNull();
    expect(hasWorkflowConfig("../escape", tmpDir)).toBe(false);
  });

  it("rejects unsafe workflow lookup names", () => {
    mkdirSync(join(tmpDir, ".foreman"), { recursive: true });
    writeFileSync(join(tmpDir, ".foreman", "escape.yaml"), "name: escape\nphases:\n  - name: finalize\n    builtin: true\n");

    expect(() => loadWorkflowConfig("../escape", tmpDir)).toThrow(WorkflowConfigError);
  });

  it("rejects explicit project-relative workflow paths outside the project", () => {
    expect(() => loadWorkflowConfig("../escape.yaml", tmpDir)).toThrow(WorkflowConfigError);
  });

  it("loads an explicit project-relative workflow YAML path", () => {
    mkdirSync(join(tmpDir, "custom"), { recursive: true });
    writeFileSync(join(tmpDir, "custom", "manual.yaml"), `
name: manual
phases:
  - name: qa
    prompt: qa.md
`);

    const config = loadWorkflowConfig("custom/manual.yaml", tmpDir);
    expect(config.name).toBe("manual");
    expect(config.sourcePath).toBe(join(tmpDir, "custom", "manual.yaml"));
    expect(config.phases.map((p) => p.name)).toEqual(["qa"]);
  });

  it("falls back to bundled defaults when no global workflow file exists", () => {
    // tmpDir has no workflows/ — should fall through to bundled defaults
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

  it("loads bundled task workflow with retry targets that reference existing phases", () => {
    const config = loadWorkflowConfig("task", tmpDir);
    const phaseNames = new Set(config.phases.map((p) => p.name));
    const fixPhase = config.phases.find((p) => p.name === "fix");
    const developerPhase = config.phases.find((p) => p.name === "developer");
    const qaPhase = config.phases.find((p) => p.name === "qa");

    expect(fixPhase?.prompt).toBe("fix-issue.md");
    expect(fixPhase?.command).toBeUndefined();
    expect(developerPhase?.prompt).toBe("developer.md");
    expect(qaPhase?.prompt).toBe("qa.md");
    expect(qaPhase?.retryWith).toBe("developer");
    expect(qaPhase?.retryOnFail).toBe(3);

    for (const phase of config.phases) {
      if (phase.retryWith) {
        expect(phaseNames.has(phase.retryWith), `${phase.name}.retryWith`).toBe(true);
      }
      if (phase.mail?.onFail) {
        expect(phaseNames.has(phase.mail.onFail), `${phase.name}.mail.onFail`).toBe(true);
      }
    }
  });

  it("loads bundled bug and chore workflows with scoped fix prompts", () => {
    for (const workflow of ["bug", "chore"] as const) {
      const config = loadWorkflowConfig(workflow, tmpDir);
      const fixPhase = config.phases.find((p) => p.name === "fix");
      const validationPhase = config.phases.find((p) => p.name === (workflow === "bug" ? "qa" : "test"));
      expect(fixPhase?.prompt).toBe("fix-issue.md");
      expect(fixPhase?.command).toBeUndefined();
      if (workflow === "bug") {
        expect(validationPhase?.prompt).toBe("qa.md");
        expect(config.phases.find((p) => p.name === "developer")?.retryOnly).toBe(true);
      } else {
        expect(validationPhase?.bash).toBe("npm run test:unit");
      }
    }
  });

  it("feature workflow inserts cli-review, PR review, and merge phases after reviewer", () => {
    const config = loadWorkflowConfig("feature", tmpDir);
    const phaseNames = config.phases.map((phase) => phase.name);
    expect(phaseNames.slice(phaseNames.indexOf("reviewer"))).toEqual([
      "reviewer",
      "cli-review",
      "finalize",
      "documentation",
      "create-pr",
      "pr-wait",
      "prepare-pr-review",
      "pr-review",
      "merge",
    ]);
    const cliReviewPhase = config.phases.find((phase) => phase.name === "cli-review");
    expect(cliReviewPhase?.builtin).toBe(true);
    expect(cliReviewPhase?.artifact).toBe("{task.projectReportsDir}/CR_CLI_REPORT.md");
    expect(cliReviewPhase?.retryWith).toBe("developer");
    expect(cliReviewPhase?.retryOnFail).toBe(2);
    expect(cliReviewPhase?.timeoutSecs).toBe(600);
    expect(config.phases.find((phase) => phase.name === "create-pr")?.builtin).toBe(true);
    const prWaitPhase = config.phases.find((phase) => phase.name === "pr-wait");
    expect(prWaitPhase?.artifact).toBe("{task.projectReportsDir}/PR_WAIT_REPORT.md");
    expect(prWaitPhase?.retryWith).toBe("developer");
    expect(prWaitPhase?.retryOnFail).toBe(2);
    const prReviewPhase = config.phases.find((phase) => phase.name === "pr-review");
    expect(prReviewPhase?.artifact).toBe("{task.projectReportsDir}/PR_REVIEW_REPORT.md");
    expect(prReviewPhase?.retryOnFail).toBe(3);
    expect(prReviewPhase?.tools?.allowed).not.toContain("Edit");
    const mergePhase = config.phases.find((phase) => phase.name === "merge");
    expect(mergePhase?.builtin).toBe(true);
    expect(mergePhase?.artifact).toBe("{task.projectReportsDir}/MERGE_REPORT.md");
  });

  it("bundled workflows declare reusable action types for every phase", () => {
    for (const workflowName of BUNDLED_WORKFLOW_NAMES) {
      const config = loadWorkflowConfig(workflowName, tmpDir);
      for (const phase of config.phases) {
        expect(phase.action, `${workflowName}.${phase.name}`).toBeTruthy();
        expect(inferPhaseActionType(phase), `${workflowName}.${phase.name}`).toBe(phase.action);
      }
    }
  });

  it("bundled default workflow declares phase validation policies", () => {
    const config = loadWorkflowConfig("default", tmpDir);
    expect(config.phases.find((phase) => phase.name === "developer")?.contract?.policy).toMatchObject({ developerCompletion: true });
    expect(config.phases.find((phase) => phase.name === "qa")?.contract?.policy).toMatchObject({ testEvidence: true, captureQaTarget: true });
    expect(config.phases.find((phase) => phase.name === "finalize")?.contract?.policy).toMatchObject({ finalizeValidation: true });
  });

  it("bundled auto-merge workflows expose cli-review, PR review, and merge phases", () => {
    const workflows = ["default", "feature", "bug", "chore", "docs", "task", "quick"];
    for (const workflowName of workflows) {
      const config = loadWorkflowConfig(workflowName, tmpDir);
      const phaseNames = config.phases.map((phase) => phase.name);
      expect(phaseNames, workflowName).toContain("cli-review");
      expect(phaseNames, workflowName).toContain("create-pr");
      expect(phaseNames, workflowName).toContain("pr-wait");
      expect(phaseNames, workflowName).toContain("prepare-pr-review");
      expect(phaseNames, workflowName).toContain("pr-review");
      expect(phaseNames, workflowName).toContain("merge");
      expect(config.phases.find((phase) => phase.name === "cli-review")?.builtin, workflowName).toBe(true);
      expect(config.phases.find((phase) => phase.name === "merge")?.builtin, workflowName).toBe(true);
    }
  });

  it("bundled workflows run documentation after finalization and before PR creation", () => {
    for (const workflowName of BUNDLED_WORKFLOW_NAMES) {
      const config = loadWorkflowConfig(workflowName, tmpDir);
      const phaseNames = config.phases.map((phase) => phase.name);
      const documentationIdx = phaseNames.indexOf("documentation");
      const finalizeIdx = phaseNames.indexOf("finalize");
      expect(documentationIdx, workflowName).toBeGreaterThanOrEqual(0);
      expect(finalizeIdx, workflowName).toBeGreaterThanOrEqual(0);
      const createPrIdx = phaseNames.indexOf("create-pr");
      if (["default", "feature", "bug", "tdd"].includes(workflowName)) {
        expect(documentationIdx, workflowName).toBeGreaterThan(finalizeIdx);
        if (createPrIdx >= 0) {
          expect(documentationIdx, workflowName).toBeLessThan(createPrIdx);
        }
      } else {
        expect(documentationIdx, workflowName).toBeLessThan(finalizeIdx);
      }
      const documentationPhase = config.phases[documentationIdx];
      expect(documentationPhase?.prompt, workflowName).toBe("documentation.md");
      expect(documentationPhase?.artifact, workflowName).toBe("{task.projectReportsDir}/DOCUMENTATION_REPORT.md");
      expect(documentationPhase?.tools?.allowed, workflowName).toContain("Edit");
    }
  });

  it("does not use Anthropic Haiku for bundled finalize phases", () => {
    for (const workflowName of BUNDLED_WORKFLOW_NAMES) {
      const config = loadWorkflowConfig(workflowName, tmpDir);
      const finalizePhase = config.phases.find((p) => p.name === "finalize");
      if (!finalizePhase) continue;

      const model = resolvePhaseModel(finalizePhase, undefined, "minimax/MiniMax-M2.7");
      expect(model, `${workflowName} finalize model`).not.toBe("anthropic/claude-haiku-4-5");
    }
  });

  it("throws WorkflowConfigError for unknown workflow with no bundled default", () => {
    expect(() => loadWorkflowConfig("nonexistent-workflow", tmpDir)).toThrow(WorkflowConfigError);
  });

  it("loads project .yml workflow overrides", () => {
    mkdirSync(join(tmpDir, ".foreman", "workflows"), { recursive: true });
    writeFileSync(join(tmpDir, ".foreman", "workflows", "short.yml"), `
name: short
phases:
  - name: finalize
    builtin: true
`);

    const config = loadWorkflowConfig("short", tmpDir);
    expect(config.name).toBe("short");
    expect(config.sourcePath).toBe(join(tmpDir, ".foreman", "workflows", "short.yml"));
  });

  it("project workflow takes precedence over global and bundled defaults", () => {
    writeWorkflowFile(tmpDir, "default", `
name: global-default
phases:
  - name: global-phase
    prompt: developer.md
`);
    mkdirSync(join(tmpDir, ".foreman", "workflows"), { recursive: true });
    writeFileSync(join(tmpDir, ".foreman", "workflows", "default.yaml"), `
name: project-default
phases:
  - name: project-phase
    prompt: developer.md
`);

    const config = loadWorkflowConfig("default", tmpDir);
    expect(config.name).toBe("project-default");
    expect(config.sourcePath).toBe(join(tmpDir, ".foreman", "workflows", "default.yaml"));
    expect(config.phases.map((phase) => phase.name)).toEqual(["project-phase"]);
  });

  it("global file takes precedence over bundled defaults", () => {
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
    // Only 2 phases (no explorer, qa, reviewer) - confirming global override was used
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

  it("bundled default workflow has explorer with skipIfArtifact and overwatch", () => {
    const config = loadWorkflowConfig("default", tmpDir);
    const explorerPhase = config.phases.find((p) => p.name === "explorer");
    expect(explorerPhase).toBeDefined();
    expect(explorerPhase?.skipIfArtifact).toBe("EXPLORER_REPORT.md");
    expect(explorerPhase?.overwatch?.enabled).toBe(true);
    expect(explorerPhase?.contract?.completion?.maxEditTargets).toBe(3);
  });
});

// ── installBundledWorkflows ───────────────────────────────────────────────────

describe("installBundledWorkflows", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
    process.env["FOREMAN_HOME"] = tmpDir;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("installs all bundled workflow files", () => {
    const { installed, skipped } = installBundledWorkflows(tmpDir);
    expect(installed.length).toBeGreaterThan(0);
    expect(skipped).toHaveLength(0);
    for (const name of BUNDLED_WORKFLOW_NAMES) {
      expect(existsSync(join(tmpDir, "workflows", `${name}.yaml`))).toBe(true);
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

  it("creates ~/.foreman/workflows/ directory if missing", () => {
    const workflowsDir = join(tmpDir, "workflows");
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
    process.env["FOREMAN_HOME"] = tmpDir;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
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
    const workflowsDir = join(tmpDir, "workflows");
    mkdirSync(workflowsDir, { recursive: true });
    writeFileSync(join(workflowsDir, "default.yaml"), "name: default\nphases:\n  - name: finalize\n    builtin: true\n");

    const missing = findMissingWorkflows(tmpDir);
    expect(missing).toContain("smoke");
    expect(missing).not.toContain("default");
  });
});

// ── resolveWorkflowName ───────────────────────────────────────────────────────

describe("resolveWorkflowName", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
    process.env["FOREMAN_HOME"] = tmpDir;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("returns 'smoke' for smoke bead type", () => {
    expect(resolveWorkflowName("smoke")).toBe("smoke");
  });

  it("returns 'epic' for epic bead type", () => {
    expect(resolveWorkflowName("epic")).toBe("epic");
  });

  it("returns 'feature' for feature bead type (feature.yaml exists)", () => {
    expect(resolveWorkflowName("feature")).toBe("feature");
  });

  it("returns 'bug' for bug bead type (bug.yaml exists — TRD-008)", () => {
    expect(resolveWorkflowName("bug")).toBe("bug");
  });

  it("returns 'task' for task bead type (task.yaml exists)", () => {
    expect(resolveWorkflowName("task")).toBe("task");
  });

  it("returns workflow label override when present", () => {
    expect(resolveWorkflowName("feature", ["workflow:smoke"])).toBe("smoke");
    expect(resolveWorkflowName("feature", ["phase:explorer", "workflow:custom"])).toBe("custom");
  });

  it("label override takes precedence over bead type", () => {
    expect(resolveWorkflowName("smoke", ["workflow:default"])).toBe("default");
  });

  it("ignores non-workflow labels", () => {
    expect(resolveWorkflowName("feature", ["phase:explorer", "priority:high"])).toBe("feature");
  });

  it("returns workflow when labels array is empty", () => {
    expect(resolveWorkflowName("feature", [])).toBe("feature");
  });

  it("returns workflow when labels is undefined", () => {
    expect(resolveWorkflowName("feature", undefined)).toBe("feature");
  });

  it("uses a workflow file installed in project .foreman/workflows when projectRoot is provided", () => {
    mkdirSync(join(tmpDir, ".foreman", "workflows"), { recursive: true });
    writeFileSync(join(tmpDir, ".foreman", "workflows", "project-seed.yaml"), `
name: project-seed
phases:
  - name: finalize
    builtin: true
`);

    expect(resolveWorkflowName("project-seed", undefined, undefined, undefined, undefined, tmpDir)).toBe("project-seed");
    expect(hasWorkflowConfig("project-seed", tmpDir)).toBe(true);
  });

  it("uses a workflow file installed in the global foreman home", () => {
    writeWorkflowFile(tmpDir, "custom-seed", `
name: custom-seed
phases:
  - name: finalize
    builtin: true
`);

    expect(resolveWorkflowName("custom-seed")).toBe("custom-seed");
  });

  it("ignores optional routing hints — uses type-based workflow when no workflow label", () => {
    // bug.yaml exists → bug workflow
    expect(resolveWorkflowName("bug", ["priority:high"])).toBe("bug");
    // feature.yaml exists → feature workflow
    expect(resolveWorkflowName("feature", ["priority:high"])).toBe("feature");
    // no workflow label, no matching file → default
    expect(resolveWorkflowName("unknown", ["priority:high"])).toBe("default");
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
          prompt: "developer.md",
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
      phases: [{ name: "explorer", prompt: "explorer.md", models: { default: "haiku" } }],
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
      phases: [{ name: "developer", prompt: "developer.md", model: "haiku", models: { default: "sonnet" } }],
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
      if (phase.prompt) {
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

describe("validateWorkflowConfig — sandbox block", () => {
  const bashConfig = {
    name: "sandboxed",
    phases: [{ name: "test", bash: "npm test" }],
  };

  it("parses sandbox for bash-only workflows", () => {
    const config = validateWorkflowConfig(
      { ...bashConfig, sandbox: { backend: "docker", image: "ubuntu:22.04", network: false } },
      "sandboxed",
    );

    expect(config.sandbox).toEqual({
      backend: "docker",
      image: "ubuntu:22.04",
      network: false,
    });
  });

  it("throws when sandbox is not an object", () => {
    expect(() => validateWorkflowConfig({ ...bashConfig, sandbox: "docker" }, "sandboxed")).toThrow(
      /'sandbox' must be an object/,
    );
  });

  it("throws when sandbox.limits is not an object", () => {
    expect(() => validateWorkflowConfig({ ...bashConfig, sandbox: { limits: "2g" } }, "sandboxed")).toThrow(
      /'sandbox.limits' must be an object/,
    );
  });

  it("throws when sandbox.image is empty", () => {
    expect(() => validateWorkflowConfig({ ...bashConfig, sandbox: { image: "" } }, "sandboxed")).toThrow(
      /'sandbox.image' must be a non-empty string/,
    );
  });

  it("throws when sandbox.limits.memory is empty", () => {
    expect(() => validateWorkflowConfig({ ...bashConfig, sandbox: { limits: { memory: "" } } }, "sandboxed")).toThrow(
      /'sandbox.limits.memory' must be a non-empty string/,
    );
  });

  it("rejects sandboxed workflows with host-executed prompt phases", () => {
    expect(() => validateWorkflowConfig(
      { name: "sandboxed", phases: [{ name: "developer", prompt: "developer.md" }], sandbox: { backend: "docker" } },
      "sandboxed",
    )).toThrow(/sandbox is only supported for bash phases/);
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

  it("includes the bundled default/smoke/epic workflows", () => {
    expect(BUNDLED_WORKFLOW_NAMES).toContain("default");
    expect(BUNDLED_WORKFLOW_NAMES).toContain("smoke");
    expect(BUNDLED_WORKFLOW_NAMES).toContain("epic");
  });
});

// ── quick workflow (YAML-first replacement for --skip-explore/--skip-review) ──

describe("quick bundled workflow", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
    process.env["FOREMAN_HOME"] = tmpDir;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("is registered as a bundled workflow", () => {
    expect(BUNDLED_WORKFLOW_NAMES).toContain("quick");
  });

  it("loads from bundled defaults and omits explorer and reviewer phases", () => {
    const config = loadWorkflowConfig("quick", tmpDir);
    expect(config.name).toBe("quick");
    const phaseNames = config.phases.map((p) => p.name);
    expect(phaseNames).not.toContain("explorer");
    expect(phaseNames).not.toContain("reviewer");
    expect(phaseNames).toContain("developer");
    expect(phaseNames).toContain("qa");
    expect(phaseNames).toContain("documentation");
    expect(phaseNames).toContain("finalize");
  });

  it("keeps QA verdict/retry wiring like the default workflow", () => {
    const config = loadWorkflowConfig("quick", tmpDir);
    const qaPhase = config.phases.find((p) => p.name === "qa");
    expect(qaPhase?.verdict).toBe(true);
    expect(qaPhase?.retryWith).toBe("developer");
    expect(typeof qaPhase?.retryOnFail).toBe("number");
  });
});

// ── resolveWorkflowName explicit override ────────────────────────────────────

describe("resolveWorkflowName explicit override", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
    process.env["FOREMAN_HOME"] = tmpDir;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("explicit override takes priority over workflow:<name> labels", () => {
    expect(resolveWorkflowName("feature", ["workflow:smoke"], undefined, "quick")).toBe("quick");
  });

  it("explicit override takes priority over taskTypeWorkflowMap", () => {
    expect(
      resolveWorkflowName("bug", undefined, { bug: "bug", default: "default" }, "quick"),
    ).toBe("quick");
  });

  it("falls back to label resolution when override is undefined", () => {
    expect(resolveWorkflowName("feature", ["workflow:smoke"], undefined, undefined)).toBe("smoke");
  });

  it("ignores empty/whitespace overrides", () => {
    expect(resolveWorkflowName("feature", ["workflow:smoke"], undefined, "  ")).toBe("smoke");
  });
});

// ── listAvailableWorkflows ───────────────────────────────────────────────────

describe("listAvailableWorkflows", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
    process.env["FOREMAN_HOME"] = tmpDir;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("includes all bundled workflow names", () => {
    const available = listAvailableWorkflows();
    for (const name of BUNDLED_WORKFLOW_NAMES) {
      expect(available).toContain(name);
    }
  });

  it("includes custom workflows installed in ~/.foreman/workflows/", () => {
    writeWorkflowFile(tmpDir, "my-custom", "name: my-custom\nphases:\n  - name: finalize\n    builtin: true\n");
    const available = listAvailableWorkflows();
    expect(available).toContain("my-custom");
  });

  it("includes custom workflows installed in project .foreman/workflows/", () => {
    mkdirSync(join(tmpDir, ".foreman", "workflows"), { recursive: true });
    writeFileSync(join(tmpDir, ".foreman", "workflows", "project-custom.yaml"), "name: project-custom\nphases:\n  - name: finalize\n    builtin: true\n");
    const available = listAvailableWorkflows(tmpDir);
    expect(available).toContain("project-custom");
  });

  it("deduplicates names present in both global and bundled locations", () => {
    writeWorkflowFile(tmpDir, "default", "name: default\nphases:\n  - name: finalize\n    builtin: true\n");
    const available = listAvailableWorkflows();
    expect(available.filter((n) => n === "default")).toHaveLength(1);
  });
});

// ── ensureBundledWorkflowsInstalled ──────────────────────────────────────────

describe("ensureBundledWorkflowsInstalled", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
    process.env["FOREMAN_HOME"] = tmpDir;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("auto-installs missing bundled workflows and returns an empty missing list", () => {
    const stillMissing = ensureBundledWorkflowsInstalled(tmpDir);
    expect(stillMissing).toHaveLength(0);
    for (const name of BUNDLED_WORKFLOW_NAMES) {
      expect(existsSync(join(tmpDir, "workflows", `${name}.yaml`))).toBe(true);
    }
  });

  it("does not overwrite existing installed workflows", () => {
    const customContent = "name: default\nphases:\n  - name: finalize\n    builtin: true\n";
    writeWorkflowFile(tmpDir, "default", customContent);
    ensureBundledWorkflowsInstalled(tmpDir);
    const after = readFileSync(join(tmpDir, "workflows", "default.yaml"), "utf-8");
    expect(after).toBe(customContent);
  });

  it("installs newly added bundled workflows (e.g. quick) into existing installs", () => {
    // Simulate an existing install that predates quick.yaml: install everything,
    // then delete quick.yaml.
    installBundledWorkflows(tmpDir);
    rmSync(join(tmpDir, "workflows", "quick.yaml"), { force: true });
    const stillMissing = ensureBundledWorkflowsInstalled(tmpDir);
    expect(stillMissing).toHaveLength(0);
    expect(existsSync(join(tmpDir, "workflows", "quick.yaml"))).toBe(true);
  });
});

describe("workflow task_type routing", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
    process.env["FOREMAN_HOME"] = tmpDir;
    installBundledWorkflows(tmpDir);
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("loads task_type declarations into the workflow map", () => {
    const map = buildTaskTypeWorkflowMap();
    expect(map.get("bug")).toBe("bug");
    expect(map.get("feature")).toBe("feature");
    expect(map.get("task")).toBe("task");
  });

  it("routes task type through workflow task_type before config fallback", () => {
    expect(resolveWorkflowName("bug", [], { bug: "quick" })).toBe("bug");
  });

  it("loads project workflow task_type declarations when projectRoot is provided", () => {
    mkdirSync(join(tmpDir, ".foreman", "workflows"), { recursive: true });
    writeFileSync(join(tmpDir, ".foreman", "workflows", "support.yaml"), `
name: support
kind: task
version: 1
task_type: support
phases:
  - name: finalize
    builtin: true
`);

    expect(buildTaskTypeWorkflowMap(tmpDir).get("support")).toBe("support");
    expect(resolveWorkflowName("support", [], undefined, undefined, undefined, tmpDir)).toBe("support");
  });

  it("detects duplicate task_type declarations", () => {
    const quickPath = join(tmpDir, "workflows", "quick.yaml");
    const quick = readFileSync(quickPath, "utf-8").replace("task_type: quick", "task_type: bug");
    writeFileSync(quickPath, quick);

    const result = validateTaskTypeUniqueness();
    expect(result.valid).toBe(false);
    expect(result.duplicates).toContainEqual({ taskType: "bug", workflows: ["bug", "quick"] });
  });
});
