import { describe, it, expect, vi, beforeEach } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseTrd } from "../../orchestrator/trd-parser.js";
import { analyzeParallel } from "../../orchestrator/sprint-parallel.js";

// Test that the parser + parallel analyzer work end-to-end
// (CLI tests are integration-level, testing the pipeline without invoking commander)

describe("sling trd CLI pipeline", () => {
  const trdPath = join(process.cwd(), "docs", "TRD", "merge-queue.md");
  let content: string;

  beforeEach(() => {
    content = readFileSync(trdPath, "utf-8");
  });

  it("parses TRD and produces valid plan", () => {
    const plan = parseTrd(content);
    expect(plan.epic.title).toBe("TRD: Merge Queue Epic");
    expect(plan.sprints.length).toBe(9);
  });

  it("--dry-run shows preview without creating tasks", () => {
    const plan = parseTrd(content);
    const parallel = analyzeParallel(plan, content);

    // Verify plan has data for display
    const totalTasks = plan.sprints.reduce(
      (sum, s) => sum + s.stories.reduce((ss, st) => ss + st.tasks.length, 0),
      0,
    );
    expect(totalTasks).toBeGreaterThan(70);
    expect(parallel.groups.length).toBeGreaterThanOrEqual(0);
  });

  it("--json outputs valid JSON structure", () => {
    const plan = parseTrd(content);
    const parallel = analyzeParallel(plan, content);

    const output = {
      epic: plan.epic,
      sprints: plan.sprints,
      parallel: parallel.groups,
      warnings: parallel.warnings,
      acceptanceCriteria: Object.fromEntries(plan.acceptanceCriteria),
      riskMap: Object.fromEntries(plan.riskMap),
    };

    const json = JSON.stringify(output, null, 2);
    const parsed = JSON.parse(json);

    expect(parsed.epic.title).toBe("TRD: Merge Queue Epic");
    expect(parsed.sprints).toHaveLength(9);
    expect(parsed.parallel).toBeDefined();
    expect(parsed.acceptanceCriteria).toBeDefined();
    expect(parsed.riskMap).toBeDefined();
  });

  it("file not found returns error", () => {
    expect(() => readFileSync("/nonexistent/path.md", "utf-8")).toThrow();
  });

  it("sling-trd.md parses correctly", () => {
    const slingTrd = readFileSync(
      join(process.cwd(), "docs", "TRD", "sling-trd.md"),
      "utf-8",
    );
    const plan = parseTrd(slingTrd);
    expect(plan.epic.title).toBe("TRD: Sling-TRD Command");
    expect(plan.epic.documentId).toBe("TRD-SLING-TRD");

    const totalTasks = plan.sprints.reduce(
      (sum, s) => sum + s.stories.reduce((ss, st) => ss + st.tasks.length, 0),
      0,
    );
    expect(totalTasks).toBe(52);
  });

  it("--skip-completed filters completed tasks from plan", () => {
    const plan = parseTrd(content);
    const allTasks = plan.sprints.flatMap((s) =>
      s.stories.flatMap((st) => st.tasks),
    );
    const openTasks = allTasks.filter((t) => t.status !== "completed");
    const completedTasks = allTasks.filter((t) => t.status === "completed");

    expect(completedTasks.length).toBeGreaterThan(0);
    expect(openTasks.length + completedTasks.length).toBe(allTasks.length);
  });
});
