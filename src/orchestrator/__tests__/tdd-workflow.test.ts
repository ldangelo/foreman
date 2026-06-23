import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { load as loadYaml } from "js-yaml";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");

function workflow(name: string): any {
  return loadYaml(readFileSync(join(PROJECT_ROOT, "src", "defaults", "workflows", `${name}.yaml`), "utf8"));
}

describe("bundled workflows use TDD red/review before implementation", () => {
  for (const name of ["default", "feature"] as const) {
    it(`${name} runs test-red and test-review before developer`, () => {
      const phases = workflow(name).phases;
      const names = phases.map((phase: any) => phase.name);
      expect(names.indexOf("explorer")).toBeLessThan(names.indexOf("test-red"));
      expect(names.indexOf("test-red")).toBeLessThan(names.indexOf("test-review"));
      expect(names.indexOf("test-review")).toBeLessThan(names.indexOf("developer"));

      const red = phases.find((phase: any) => phase.name === "test-red");
      expect(red.prompt).toBe("test-red.md");
      expect(red.artifact).toContain("RED_REPORT.md");

      const review = phases.find((phase: any) => phase.name === "test-review");
      expect(review.verdict).toBe(true);
      expect(review.retryWith).toBe("test-red");
      expect(review.artifact).toContain("TEST_REVIEW_REPORT.md");
    });
  }

  it("bug workflow runs test-red and test-review before fix", () => {
    const phases = workflow("bug").phases;
    const names = phases.map((phase: any) => phase.name);
    expect(names.indexOf("test-red")).toBeLessThan(names.indexOf("test-review"));
    expect(names.indexOf("test-review")).toBeLessThan(names.indexOf("fix"));
    expect(phases.find((phase: any) => phase.name === "test-review").retryWith).toBe("test-red");
  });
});
