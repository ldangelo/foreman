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
  it("task keeps initial fix separate from focused repair remediation", () => {
    const workflow = loadBundledWorkflow("task");
    const phaseNames = workflow.phases.map((phase) => phase.name);

    expect(phaseNames).toContain("fix");
    expect(phaseNames).toContain("repair");
    expect(phaseNames.indexOf("repair")).toBeGreaterThan(phaseNames.indexOf("fix"));
  });

  it("task routes generic findings back to repair, not the initial fix prompt", () => {
    const workflow = loadBundledWorkflow("task");
    const phasesByName = new Map(workflow.phases.map((phase) => [phase.name, phase]));
    const remediationPhases = ["test", "qa", "reviewer", "cli-review", "finalize", "pr-wait", "merge"];

    expect(phasesByName.get("repair")?.retryOnly).toBe(true);
    expect(phasesByName.get("repair")?.prompt).toBe("repair.md");
    expect(phasesByName.get("cicd-developer")?.retryOnly).toBe(true);
    expect(phasesByName.get("cr-developer")?.retryOnly).toBe(true);
    expect(phasesByName.get("merge-resolver")?.retryOnly).toBe(true);

    for (const phaseName of remediationPhases) {
      const phase = phasesByName.get(phaseName);
      if (!phase?.retryWith) continue;

      expect(phase.retryWith).toBe("repair");
      expect(phase.mail?.onFail ?? "repair").toBe("repair");
    }

    const prWait = phasesByName.get("pr-wait");
    expect(prWait?.retryWithByReason).toMatchObject({
      "ci_failed:": "cicd-developer",
      "coderabbit_": "cr-developer",
      "merge_conflict:": "merge-resolver",
    });
  });

  it("bug keeps initial fix separate from developer remediation", () => {
    const workflow = loadBundledWorkflow("bug");
    const phaseNames = workflow.phases.map((phase) => phase.name);

    expect(phaseNames).toContain("fix");
    expect(phaseNames).toContain("developer");
    expect(phaseNames.indexOf("developer")).toBeGreaterThan(phaseNames.indexOf("fix"));
  });

  it("bug routes findings back to developer, not the initial fix prompt", () => {
    const workflow = loadBundledWorkflow("bug");
    const phasesByName = new Map(workflow.phases.map((phase) => [phase.name, phase]));
    const remediationPhases = ["test", "qa", "reviewer", "cli-review", "finalize", "pr-wait", "merge"];

    expect(phasesByName.get("cicd-developer")?.retryOnly).toBe(true);
    expect(phasesByName.get("cr-developer")?.retryOnly).toBe(true);
    expect(phasesByName.get("merge-resolver")?.retryOnly).toBe(true);

    for (const phaseName of remediationPhases) {
      const phase = phasesByName.get(phaseName);
      if (!phase?.retryWith) continue;

      expect(phase.retryWith).toBe("developer");
      expect(phase.mail?.onFail ?? "developer").toBe("developer");
    }

    const prWait = phasesByName.get("pr-wait");
    expect(prWait?.retryWithByReason).toMatchObject({
      "ci_failed:": "cicd-developer",
      "coderabbit_": "cr-developer",
      "merge_conflict:": "merge-resolver",
    });
  });
});
