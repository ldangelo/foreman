import { readFileSync } from "node:fs";
import { join } from "node:path";
import { load as loadYaml } from "js-yaml";
import { describe, expect, it } from "vitest";
import { validateWorkflowConfig } from "../../lib/workflow-loader.js";

const PROJECT_ROOT = join(__dirname, "..", "..", "..");

function loadBundledWorkflow(name: "task" | "bug") {
  const raw = loadYaml(readFileSync(join(PROJECT_ROOT, "src", "defaults", "workflows", `${name}.yaml`), "utf8"));
  return validateWorkflowConfig(raw, name);
}

describe("task and bug workflow remediation routing", () => {
  for (const workflowName of ["task", "bug"] as const) {
    it(`${workflowName} keeps initial fix separate from developer remediation`, () => {
      const workflow = loadBundledWorkflow(workflowName);
      const phaseNames = workflow.phases.map((phase) => phase.name);

      expect(phaseNames).toContain("fix");
      expect(phaseNames).toContain("developer");
      expect(phaseNames.indexOf("developer")).toBeGreaterThan(phaseNames.indexOf("fix"));
    });

    it(`${workflowName} routes findings back to developer, not the initial fix prompt`, () => {
      const workflow = loadBundledWorkflow(workflowName);
      const phasesByName = new Map(workflow.phases.map((phase) => [phase.name, phase]));
      const remediationPhases = ["test", "qa", "reviewer", "cli-review", "finalize", "pr-wait", "pr-review"];

      for (const phaseName of remediationPhases) {
        const phase = phasesByName.get(phaseName);
        if (!phase?.retryWith) continue;

        expect(phase.retryWith).toBe("developer");
        expect(phase.mail?.onFail ?? "developer").toBe("developer");
      }
    });
  }
});
