/**
 * TRD-017-TEST: Bundled Default Files Tests
 *
 * Validates that bundled default files in src/defaults/ are structurally
 * consistent with ROLE_CONFIGS and DEFAULT_WORKFLOWS.
 *
 * Satisfies: REQ-014, AC-014-1 through AC-014-5
 */

import { describe, it, expect } from "vitest";
import * as fs from "node:fs";
import * as path from "node:path";
import { validatePhaseConfigEntry } from "../phase-config-loader.js";
import { validateFinalizeEnforcement, DEFAULT_WORKFLOWS } from "../workflow-config-loader.js";
import { ROLE_CONFIGS } from "../../orchestrator/roles.js";
import { renderTemplate } from "../prompt-loader.js";

// Resolve the defaults directory relative to this test file
const DEFAULTS_DIR = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../../defaults",
);
const PROMPTS_DIR = path.join(DEFAULTS_DIR, "prompts");

describe("src/defaults/phases.json (TRD-017)", () => {
  const phasesJsonPath = path.join(DEFAULTS_DIR, "phases.json");

  it("AC-014-1: phases.json exists in src/defaults/", () => {
    expect(fs.existsSync(phasesJsonPath)).toBe(true);
  });

  it("AC-014-1: phases.json is valid JSON", () => {
    const content = fs.readFileSync(phasesJsonPath, "utf-8");
    expect(() => JSON.parse(content)).not.toThrow();
  });

  it("AC-014-1: phases.json passes schema validation for all phases", () => {
    const content = fs.readFileSync(phasesJsonPath, "utf-8");
    const phases = JSON.parse(content) as Record<string, unknown>;

    for (const [phaseName, entry] of Object.entries(phases)) {
      expect(() => validatePhaseConfigEntry(phaseName, entry)).not.toThrow();
    }
  });

  it("AC-014-1: phases.json contains all ROLE_CONFIGS phases", () => {
    const content = fs.readFileSync(phasesJsonPath, "utf-8");
    const phases = JSON.parse(content) as Record<string, unknown>;
    const roleConfigKeys = Object.keys(ROLE_CONFIGS);

    for (const phaseName of roleConfigKeys) {
      expect(phases).toHaveProperty(phaseName);
    }
  });

  it("AC-014-1: phases.json models match ROLE_CONFIGS defaults", () => {
    const content = fs.readFileSync(phasesJsonPath, "utf-8");
    const phases = JSON.parse(content) as Record<string, { model: string; maxBudgetUsd: number; allowedTools: string[]; reportFile: string; promptFile: string }>;

    // explorer should use haiku, others should use sonnet
    expect(phases["explorer"]?.model).toBe("claude-haiku-4-5-20251001");
    expect(phases["developer"]?.model).toBe("claude-sonnet-4-6");
    expect(phases["qa"]?.model).toBe("claude-sonnet-4-6");
    expect(phases["reviewer"]?.model).toBe("claude-sonnet-4-6");
  });

  it("phases.json includes 'reproducer' phase", () => {
    const content = fs.readFileSync(phasesJsonPath, "utf-8");
    const phases = JSON.parse(content) as Record<string, unknown>;
    expect(phases).toHaveProperty("reproducer");
  });
});

describe("src/defaults/workflows.json (TRD-017)", () => {
  const workflowsJsonPath = path.join(DEFAULTS_DIR, "workflows.json");

  it("AC-014-2: workflows.json exists in src/defaults/", () => {
    expect(fs.existsSync(workflowsJsonPath)).toBe(true);
  });

  it("AC-014-2: workflows.json is valid JSON", () => {
    const content = fs.readFileSync(workflowsJsonPath, "utf-8");
    expect(() => JSON.parse(content)).not.toThrow();
  });

  it("AC-014-2: workflows.json has all four default workflow types", () => {
    const content = fs.readFileSync(workflowsJsonPath, "utf-8");
    const workflows = JSON.parse(content) as Record<string, string[]>;
    expect(workflows).toHaveProperty("feature");
    expect(workflows).toHaveProperty("bug");
    expect(workflows).toHaveProperty("chore");
    expect(workflows).toHaveProperty("docs");
  });

  it("AC-014-2: workflows.json passes finalize enforcement", () => {
    const content = fs.readFileSync(workflowsJsonPath, "utf-8");
    const workflows = JSON.parse(content) as Record<string, string[]>;
    expect(() => validateFinalizeEnforcement(workflows)).not.toThrow();
  });

  it("AC-014-2: workflows.json matches DEFAULT_WORKFLOWS", () => {
    const content = fs.readFileSync(workflowsJsonPath, "utf-8");
    const workflows = JSON.parse(content) as Record<string, string[]>;
    expect(workflows["feature"]).toEqual(DEFAULT_WORKFLOWS["feature"]);
    expect(workflows["bug"]).toEqual(DEFAULT_WORKFLOWS["bug"]);
    expect(workflows["chore"]).toEqual(DEFAULT_WORKFLOWS["chore"]);
    expect(workflows["docs"]).toEqual(DEFAULT_WORKFLOWS["docs"]);
  });
});

describe("src/defaults/prompts/ (TRD-017)", () => {
  const expectedPromptFiles = ["explorer.md", "developer.md", "qa.md", "reviewer.md", "reproducer.md"];

  it("AC-014-3: prompts directory exists", () => {
    expect(fs.existsSync(PROMPTS_DIR)).toBe(true);
  });

  it("AC-014-3: all five prompt files exist", () => {
    for (const filename of expectedPromptFiles) {
      const filePath = path.join(PROMPTS_DIR, filename);
      expect(fs.existsSync(filePath), `${filename} should exist`).toBe(true);
    }
  });

  it("AC-014-4: explorer.md contains {{seedId}} and {{seedTitle}} placeholders", () => {
    const content = fs.readFileSync(path.join(PROMPTS_DIR, "explorer.md"), "utf-8");
    expect(content).toContain("{{seedId}}");
    expect(content).toContain("{{seedTitle}}");
  });

  it("AC-014-4: developer.md contains {{feedbackSection}} or {{#if feedbackContext}} conditional", () => {
    const content = fs.readFileSync(path.join(PROMPTS_DIR, "developer.md"), "utf-8");
    // Developer prompt should have some feedback conditional
    expect(content).toMatch(/\{\{feedbackSection\}\}|\{\{#if feedbackContext\}\}/);
  });

  it("AC-014-5: reproducer.md contains {{seedId}}, {{seedTitle}}, {{seedDescription}}", () => {
    const content = fs.readFileSync(path.join(PROMPTS_DIR, "reproducer.md"), "utf-8");
    expect(content).toContain("{{seedId}}");
    expect(content).toContain("{{seedTitle}}");
    expect(content).toContain("{{seedDescription}}");
  });

  it("AC-014-3: all prompt files are renderable with renderTemplate", () => {
    const testVars = {
      seedId: "bd-test1",
      seedTitle: "Test task",
      seedDescription: "A test description",
      feedbackSection: "",
      feedbackContext: undefined,
      commentsSection: "",
      seedComments: undefined,
      explorerInstruction: "2. Explore the codebase",
    };

    for (const filename of expectedPromptFiles) {
      const filePath = path.join(PROMPTS_DIR, filename);
      const content = fs.readFileSync(filePath, "utf-8");
      expect(() => renderTemplate(content, testVars), `${filename} should render without error`).not.toThrow();
      const rendered = renderTemplate(content, testVars);
      expect(rendered.length).toBeGreaterThan(0);
    }
  });
});
