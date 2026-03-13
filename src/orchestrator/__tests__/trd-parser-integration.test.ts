import { describe, it, expect } from "vitest";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { parseTrd } from "../trd-parser.js";

describe("TRD Parser integration with merge-queue.md", () => {
  let plan: ReturnType<typeof parseTrd>;

  // Read the real TRD file once
  it("parses merge-queue.md without errors", async () => {
    const trdPath = join(process.cwd(), "docs", "TRD", "merge-queue.md");
    const content = await readFile(trdPath, "utf-8");
    plan = parseTrd(content);
    expect(plan).toBeDefined();
  });

  it("extracts the correct epic metadata", () => {
    expect(plan.epic.title).toBe("TRD: Merge Queue Epic");
    expect(plan.epic.documentId).toBe("TRD-MERGE-QUEUE");
  });

  it("extracts 9 sprints (3a and 3b counted separately)", () => {
    // Sprints: 1, 2, 3a, 3b, 4, 5, 6, 7, 8
    // 3a and 3b both have number=3 but are separate sprint objects
    expect(plan.sprints).toHaveLength(9);
    // Both sub-sprints for sprint 3
    const sprint3s = plan.sprints.filter((s) => s.number === 3);
    expect(sprint3s).toHaveLength(2);
  });

  it("extracts tasks with valid IDs matching MQ-T### pattern", () => {
    const allTasks = plan.sprints.flatMap((s) =>
      s.stories.flatMap((st) => st.tasks),
    );
    expect(allTasks.length).toBeGreaterThan(70);

    for (const task of allTasks) {
      expect(task.trdId).toMatch(/^MQ-T\d+/);
    }
  });

  it("preserves dependency references", () => {
    const allTasks = plan.sprints.flatMap((s) =>
      s.stories.flatMap((st) => st.tasks),
    );

    // MQ-T002 depends on MQ-T001
    const t002 = allTasks.find((t) => t.trdId === "MQ-T002");
    expect(t002).toBeDefined();
    expect(t002!.dependencies).toContain("MQ-T001");

    // MQ-T018 depends on MQ-T008 and MQ-T009
    const t018 = allTasks.find((t) => t.trdId === "MQ-T018");
    expect(t018).toBeDefined();
    expect(t018!.dependencies).toContain("MQ-T008");
    expect(t018!.dependencies).toContain("MQ-T009");
  });

  it("extracts hour estimates", () => {
    const allTasks = plan.sprints.flatMap((s) =>
      s.stories.flatMap((st) => st.tasks),
    );

    const t001 = allTasks.find((t) => t.trdId === "MQ-T001");
    expect(t001!.estimateHours).toBe(3);

    const t008 = allTasks.find((t) => t.trdId === "MQ-T008");
    expect(t008!.estimateHours).toBe(4);
  });

  it("extracts file paths", () => {
    const allTasks = plan.sprints.flatMap((s) =>
      s.stories.flatMap((st) => st.tasks),
    );

    const t001 = allTasks.find((t) => t.trdId === "MQ-T001");
    expect(t001!.files).toContain("src/orchestrator/refinery.ts");
  });

  it("detects completed tasks", () => {
    const allTasks = plan.sprints.flatMap((s) =>
      s.stories.flatMap((st) => st.tasks),
    );

    // Most merge-queue tasks should be completed
    const completed = allTasks.filter((t) => t.status === "completed");
    expect(completed.length).toBeGreaterThan(50);
  });

  it("extracts acceptance criteria", () => {
    expect(plan.acceptanceCriteria.size).toBeGreaterThan(0);
    expect(plan.acceptanceCriteria.has("FR-1")).toBe(true);
    expect(plan.acceptanceCriteria.has("FR-2")).toBe(true);
  });

  it("extracts risk register", () => {
    expect(plan.riskMap.size).toBeGreaterThan(0);
    // MQ-T030 should have high risk (AI produces invalid code: Medium likelihood, High impact)
    expect(plan.riskMap.get("MQ-T030")).toBe("high");
  });

  it("extracts quality requirements", () => {
    expect(plan.epic.qualityNotes).toBeDefined();
    expect(plan.epic.qualityNotes).toContain("80%");
  });

  it("extracts sprint summaries", () => {
    // Sprint 1 should have summary
    const s1 = plan.sprints.find((s) => s.number === 1);
    expect(s1?.summary).toBeDefined();
    expect(s1!.summary!.focus).toBe("Foundation");
  });

  it("extracts stories with titles", () => {
    const s1 = plan.sprints.find((s) => s.number === 1);
    expect(s1!.stories.length).toBeGreaterThanOrEqual(2);
    expect(s1!.stories[0].title).toContain("Auto-Commit");
  });
});
