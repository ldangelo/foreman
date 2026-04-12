import { describe, expect, it } from "vitest";
import { load as yamlLoad } from "js-yaml";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "../../..");
const PACKAGE_JSON_PATH = resolve(ROOT, "package.json");
const CI_WORKFLOW_PATH = resolve(ROOT, ".github/workflows/ci.yml");
const SYSTEM_WORKFLOW_PATH = resolve(ROOT, ".github/workflows/system-tests.yml");

interface PackageJsonShape {
  scripts?: Record<string, string>;
}

interface WorkflowShape {
  on?: Record<string, unknown>;
  jobs?: Record<
    string,
    {
      steps?: Array<{ name?: string; uses?: string; run?: string }>;
      strategy?: { matrix?: Record<string, unknown> };
    }
  >;
}

function loadPackageJson(): PackageJsonShape {
  return JSON.parse(readFileSync(PACKAGE_JSON_PATH, "utf8")) as PackageJsonShape;
}

function loadWorkflow(path: string): WorkflowShape {
  return yamlLoad(readFileSync(path, "utf8")) as WorkflowShape;
}

function getAllSteps(workflowPath: string) {
  const workflow = loadWorkflow(workflowPath);
  return Object.values(workflow.jobs ?? {}).flatMap((job) => job.steps ?? []);
}

describe("testing framework package scripts", () => {
  it("exposes the explicit lane scripts", () => {
    const scripts = loadPackageJson().scripts ?? {};
    expect(scripts["test"]).toBe("npm run test:ci");
    expect(scripts["test:unit"]).toBe("vitest run -c vitest.unit.config.ts");
    expect(scripts["test:integration"]).toBe("vitest run -c vitest.integration.config.ts");
    expect(scripts["test:e2e:smoke"]).toBe("vitest run -c vitest.e2e.smoke.config.ts");
    expect(scripts["test:e2e:full-run"]).toBe("vitest run -c vitest.e2e.full-run.config.ts");
    expect(scripts["test:system"]).toBe("vitest run -c vitest.system.config.ts");
    expect(scripts["test:ci"]).toBe(
      "npm run test:unit && npm run test:integration && npm run test:e2e:smoke",
    );
    expect(scripts["test:all"]).toBe(
      "npm run test:ci && npm run test:e2e:full-run && npm run test:system",
    );
  });

  it("exposes deterministic JSON report commands", () => {
    const scripts = loadPackageJson().scripts ?? {};
    expect(scripts["test:report:unit"]).toContain(".foreman/test-reports/unit.json");
    expect(scripts["test:report:integration"]).toContain(
      ".foreman/test-reports/integration.json",
    );
    expect(scripts["test:report:e2e:smoke"]).toContain(
      ".foreman/test-reports/e2e-smoke.json",
    );
    expect(scripts["test:report:ci"]).toBe(
      "mkdir -p .foreman/test-reports && npm run test:report:unit && npm run test:report:integration && npm run test:report:e2e:smoke",
    );
  });
});

describe("testing framework workflows", () => {
  it("ci workflow uploads deterministic JSON test reports", () => {
    const steps = getAllSteps(CI_WORKFLOW_PATH);
    const reportIdx = steps.findIndex((step) =>
      step.run?.includes("npm run test:report:ci"),
    );
    const uploadIdx = steps.findIndex((step) =>
      step.uses?.startsWith("actions/upload-artifact"),
    );

    expect(reportIdx).toBeGreaterThanOrEqual(0);
    expect(uploadIdx).toBeGreaterThan(reportIdx);
  });

  it("system workflow stays opt-in or scheduled and runs only the system lane", () => {
    const workflow = loadWorkflow(SYSTEM_WORKFLOW_PATH);
    const on = workflow.on ?? {};
    const steps = getAllSteps(SYSTEM_WORKFLOW_PATH);

    expect(on).toHaveProperty("workflow_dispatch");
    expect(on).toHaveProperty("schedule");
    expect(steps.some((step) => step.run?.includes("npm run test:system"))).toBe(true);
    expect(steps.some((step) => step.run?.includes("npm run test:ci"))).toBe(false);
  });

  it("system workflow still typechecks on Node 20 before running system tests", () => {
    const workflow = loadWorkflow(SYSTEM_WORKFLOW_PATH);
    const jobs = Object.values(workflow.jobs ?? {});
    const steps = getAllSteps(SYSTEM_WORKFLOW_PATH);

    expect(
      jobs.some((job) => {
        const versions = job.strategy?.matrix?.["node-version"] as string[] | undefined;
        return versions?.includes("20") || versions?.includes("20.x");
      }) ||
        steps.some((step) => step.uses?.startsWith("actions/setup-node") && step.name?.includes("20")),
    ).toBe(true);

    const typecheckIdx = steps.findIndex(
      (step) => step.run?.includes("tsc") && step.run.includes("--noEmit"),
    );
    const systemIdx = steps.findIndex((step) =>
      step.run?.includes("npm run test:system"),
    );

    expect(typecheckIdx).toBeGreaterThanOrEqual(0);
    expect(systemIdx).toBeGreaterThan(typecheckIdx);
  });
});
