import { describe, it, expect } from "vitest";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import {
  buildSprintDepGraph,
  computeParallelGroups,
  parseTrdParallelNotes,
  validate,
  analyzeParallel,
} from "../sprint-parallel.js";
import { parseTrd } from "../trd-parser.js";
import type { TrdSprint, SlingPlan, Priority } from "../types.js";

// ── Test helpers ─────────────────────────────────────────────────────────

function makeSprint(
  number: number,
  tasks: { trdId: string; deps: string[] }[],
): TrdSprint {
  return {
    number,
    title: `Sprint ${number}`,
    goal: `Goal ${number}`,
    priority: "high" as Priority,
    stories: [
      {
        title: `Story ${number}.1`,
        tasks: tasks.map((t) => ({
          trdId: t.trdId,
          title: `Task ${t.trdId}`,
          estimateHours: 1,
          dependencies: t.deps,
          files: [],
          status: "open" as const,
        })),
      },
    ],
  };
}

// ── buildSprintDepGraph ──────────────────────────────────────────────────

describe("buildSprintDepGraph", () => {
  it("detects cross-sprint dependencies", () => {
    const sprints = [
      makeSprint(1, [{ trdId: "T001", deps: [] }]),
      makeSprint(2, [{ trdId: "T002", deps: ["T001"] }]),
    ];
    const graph = buildSprintDepGraph(sprints);
    expect(graph.get(1)!.has(0)).toBe(true); // Sprint 2 depends on Sprint 1
    expect(graph.get(0)!.size).toBe(0); // Sprint 1 has no deps
  });

  it("handles independent sprints", () => {
    const sprints = [
      makeSprint(1, [{ trdId: "T001", deps: [] }]),
      makeSprint(2, [{ trdId: "T002", deps: [] }]),
    ];
    const graph = buildSprintDepGraph(sprints);
    expect(graph.get(0)!.size).toBe(0);
    expect(graph.get(1)!.size).toBe(0);
  });

  it("ignores intra-sprint dependencies", () => {
    const sprints = [
      makeSprint(1, [
        { trdId: "T001", deps: [] },
        { trdId: "T002", deps: ["T001"] },
      ]),
    ];
    const graph = buildSprintDepGraph(sprints);
    expect(graph.get(0)!.size).toBe(0);
  });

  it("handles multiple cross-sprint deps", () => {
    const sprints = [
      makeSprint(1, [{ trdId: "T001", deps: [] }]),
      makeSprint(2, [{ trdId: "T002", deps: [] }]),
      makeSprint(3, [{ trdId: "T003", deps: ["T001", "T002"] }]),
    ];
    const graph = buildSprintDepGraph(sprints);
    expect(graph.get(2)!.has(0)).toBe(true);
    expect(graph.get(2)!.has(1)).toBe(true);
  });
});

// ── computeParallelGroups ────────────────────────────────────────────────

describe("computeParallelGroups", () => {
  it("identifies independent sprints as parallel", () => {
    const sprints = [
      makeSprint(1, [{ trdId: "T001", deps: [] }]),
      makeSprint(2, [{ trdId: "T002", deps: [] }]),
    ];
    const graph = buildSprintDepGraph(sprints);
    const groups = computeParallelGroups(graph, 2);
    expect(groups).toHaveLength(1);
    expect(groups[0].sprintIndices).toEqual([0, 1]);
    expect(groups[0].label).toBe("A");
  });

  it("does not group dependent sprints", () => {
    const sprints = [
      makeSprint(1, [{ trdId: "T001", deps: [] }]),
      makeSprint(2, [{ trdId: "T002", deps: ["T001"] }]),
    ];
    const graph = buildSprintDepGraph(sprints);
    const groups = computeParallelGroups(graph, 2);
    expect(groups).toHaveLength(0); // No parallel groups
  });

  it("handles diamond dependency", () => {
    // Sprint 1 → Sprint 2 and Sprint 3 → Sprint 4
    // Sprint 2 and 3 can be parallel
    const sprints = [
      makeSprint(1, [{ trdId: "T001", deps: [] }]),
      makeSprint(2, [{ trdId: "T002", deps: ["T001"] }]),
      makeSprint(3, [{ trdId: "T003", deps: ["T001"] }]),
      makeSprint(4, [{ trdId: "T004", deps: ["T002", "T003"] }]),
    ];
    const graph = buildSprintDepGraph(sprints);
    const groups = computeParallelGroups(graph, 4);
    expect(groups).toHaveLength(1);
    expect(groups[0].sprintIndices).toEqual([1, 2]);
  });

  it("returns empty for single sprint", () => {
    const sprints = [makeSprint(1, [{ trdId: "T001", deps: [] }])];
    const graph = buildSprintDepGraph(sprints);
    const groups = computeParallelGroups(graph, 1);
    expect(groups).toHaveLength(0);
  });

  it("returns empty for empty graph", () => {
    const groups = computeParallelGroups(new Map(), 0);
    expect(groups).toHaveLength(0);
  });
});

// ── parseTrdParallelNotes ────────────────────────────────────────────────

describe("parseTrdParallelNotes", () => {
  it("extracts parallel sprint pairs from Section 4", () => {
    const content = `## 4. Dependency Graph

\`\`\`
Sprint 1 -> Sprint 2
\`\`\`

### Parallelization Opportunities

- Sprint 5 and Sprint 6 can run in parallel (independent feature sets)
- Sprint 7 and Sprint 8 can run in parallel after Sprint 4 is complete

## 5. Acceptance Criteria`;

    const pairs = parseTrdParallelNotes(content);
    expect(pairs).toHaveLength(2);
    expect(pairs[0]).toEqual({ sprintA: 5, sprintB: 6 });
    expect(pairs[1]).toEqual({ sprintA: 7, sprintB: 8 });
  });

  it("returns empty when no Section 4", () => {
    const pairs = parseTrdParallelNotes("# TRD\n## 1. Foo");
    expect(pairs).toHaveLength(0);
  });
});

// ── validate ─────────────────────────────────────────────────────────────

describe("validate", () => {
  it("warns when TRD states parallel but deps disagree", () => {
    const sprints = [
      makeSprint(1, [{ trdId: "T001", deps: [] }]),
      makeSprint(2, [{ trdId: "T002", deps: ["T001"] }]),
    ];
    const groups = computeParallelGroups(
      buildSprintDepGraph(sprints),
      2,
    );
    const warnings = validate(
      groups,
      [{ sprintA: 1, sprintB: 2 }],
      sprints,
    );
    expect(warnings.length).toBeGreaterThan(0);
    expect(warnings[0]).toContain("TRD states Sprint 1 and Sprint 2 are parallel");
  });

  it("warns when auto-computed parallel not in TRD", () => {
    const sprints = [
      makeSprint(1, [{ trdId: "T001", deps: [] }]),
      makeSprint(2, [{ trdId: "T002", deps: [] }]),
    ];
    const groups = computeParallelGroups(
      buildSprintDepGraph(sprints),
      2,
    );
    const warnings = validate(groups, [], sprints);
    expect(warnings.length).toBeGreaterThan(0);
    expect(warnings[0]).toContain("Auto-computed");
  });

  it("no warnings when TRD and auto-computed agree", () => {
    const sprints = [
      makeSprint(1, [{ trdId: "T001", deps: [] }]),
      makeSprint(2, [{ trdId: "T002", deps: [] }]),
    ];
    const groups = computeParallelGroups(
      buildSprintDepGraph(sprints),
      2,
    );
    const warnings = validate(
      groups,
      [{ sprintA: 1, sprintB: 2 }],
      sprints,
    );
    expect(warnings).toHaveLength(0);
  });
});

// ── analyzeParallel ──────────────────────────────────────────────────────

describe("analyzeParallel", () => {
  it("returns groups and warnings for a plan", () => {
    const plan: SlingPlan = {
      epic: { title: "Test", description: "", documentId: "TRD-TEST" },
      sprints: [
        makeSprint(1, [{ trdId: "T001", deps: [] }]),
        makeSprint(2, [{ trdId: "T002", deps: [] }]),
        makeSprint(3, [{ trdId: "T003", deps: ["T001", "T002"] }]),
      ],
      acceptanceCriteria: new Map(),
      riskMap: new Map(),
    };
    const result = analyzeParallel(plan);
    expect(result.groups).toHaveLength(1);
    expect(result.groups[0].sprintIndices).toEqual([0, 1]);
  });
});

// ── Integration with merge-queue.md ──────────────────────────────────────

describe("analyzeParallel with merge-queue.md", () => {
  it("identifies parallel sprints in merge-queue TRD", async () => {
    const trdPath = join(process.cwd(), "docs", "TRD", "merge-queue.md");
    const content = await readFile(trdPath, "utf-8");
    const plan = parseTrd(content);
    const result = analyzeParallel(plan, content);

    // Should find at least one parallel group
    expect(result.groups.length).toBeGreaterThanOrEqual(1);

    // All sprint indices should be valid
    for (const group of result.groups) {
      for (const idx of group.sprintIndices) {
        expect(idx).toBeGreaterThanOrEqual(0);
        expect(idx).toBeLessThan(plan.sprints.length);
      }
    }
  });
});
