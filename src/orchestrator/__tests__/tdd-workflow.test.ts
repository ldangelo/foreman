import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { load as loadYaml } from "js-yaml";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");

type Workflow = { task_type?: string; phases: Array<{ name: string; action?: string; prompt?: string; artifact?: string; verdict?: boolean; retryWith?: string; retryOnFail?: number }> };

function workflow(name: string): Workflow {
  return loadYaml(readFileSync(join(PROJECT_ROOT, "src", "defaults", "workflows", `${name}.yaml`), "utf8")) as Workflow;
}

function phaseNames(name: string): string[] {
  return workflow(name).phases.map((phase) => phase.name);
}

describe("bundled workflow TDD routing", () => {
  for (const name of ["default", "feature"] as const) {
    it(`${name} uses the fast path by default`, () => {
      const names = phaseNames(name);
      expect(names).toContain("explorer");
      expect(names.indexOf("explorer")).toBeLessThan(names.indexOf("developer"));
      expect(names).not.toContain("test-red");
      expect(names).not.toContain("test-review");
    });
  }

  it("bug workflow uses the fast fix path by default", () => {
    const names = phaseNames("bug");
    const workerNames = workflow("bug").phases.filter((phase) => !["prepare-worktree", "setup-workspace", "write-task-context"].includes(phase.action ?? phase.name)).map((phase) => phase.name);
    expect(workerNames[0]).toBe("fix");
    expect(names).not.toContain("test-red");
    expect(names).not.toContain("test-review");
  });

  it("tdd workflow is opt-in and runs red/review before developer", () => {
    const tdd = workflow("tdd");
    const names = tdd.phases.map((phase) => phase.name);
    expect(tdd.task_type).toBe("tdd");
    expect(names.indexOf("explorer")).toBeLessThan(names.indexOf("test-red"));
    expect(names.indexOf("test-red")).toBeLessThan(names.indexOf("test-review"));
    expect(names.indexOf("test-review")).toBeLessThan(names.indexOf("developer"));

    const red = tdd.phases.find((phase) => phase.name === "test-red");
    expect(red?.prompt).toBe("test-red.md");
    expect(red?.artifact).toContain("RED_REPORT.md");
    expect(red?.retryOnFail).toBe(1);

    const review = tdd.phases.find((phase) => phase.name === "test-review");
    expect(review?.verdict).toBe(true);
    expect(review?.retryWith).toBe("test-red");
    expect(review?.retryOnFail).toBe(1);
    expect(review?.artifact).toContain("TEST_REVIEW_REPORT.md");
  });
});
