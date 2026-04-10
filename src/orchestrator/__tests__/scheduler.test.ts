import { describe, it, expect } from "vitest";
import { planProjectDispatches, type ProjectSchedulingCandidate } from "../scheduler.js";

function makeCandidate(overrides: Partial<ProjectSchedulingCandidate> & { path: string; name?: string }): ProjectSchedulingCandidate {
  const path = overrides.path;
  const name = overrides.name ?? path.split("/").at(-1) ?? "project";
  return {
    project: {
      name,
      path,
      addedAt: "2026-04-08T00:00:00.000Z",
    },
    readyCount: 1,
    bestPriority: 2,
    oldestReadyAt: "2026-04-08T00:00:00.000Z",
    activeAgents: 0,
    maxNewSlots: 1,
    source: "beads",
    ...overrides,
  };
}

describe("planProjectDispatches", () => {
  it("allocates fleet capacity to the higher-priority project first", () => {
    const decisions = planProjectDispatches([
      makeCandidate({ path: "/tmp/project-a", bestPriority: 2 }),
      makeCandidate({ path: "/tmp/project-b", bestPriority: 0 }),
    ], 1);

    const selected = decisions.find((decision) => decision.grantedSlots === 1);
    expect(selected?.project.path).toBe("/tmp/project-b");
    expect(selected?.reason).toContain("priority P0");
  });

  it("uses active-agent count as a fairness tiebreaker", () => {
    const decisions = planProjectDispatches([
      makeCandidate({ path: "/tmp/project-a", activeAgents: 2 }),
      makeCandidate({ path: "/tmp/project-b", activeAgents: 0 }),
    ], 3);

    const projectB = decisions.find((decision) => decision.project.path === "/tmp/project-b");
    expect(projectB?.grantedSlots).toBe(1);
    expect(projectB?.reason).toContain("no active agents");
  });

  it("spreads slots across projects before giving one project extra capacity", () => {
    const decisions = planProjectDispatches([
      makeCandidate({ path: "/tmp/project-a", readyCount: 3, maxNewSlots: 3 }),
      makeCandidate({ path: "/tmp/project-b", readyCount: 2, maxNewSlots: 2, oldestReadyAt: "2026-04-07T00:00:00.000Z" }),
    ], 2);

    expect(decisions.find((decision) => decision.project.path === "/tmp/project-a")?.grantedSlots).toBe(1);
    expect(decisions.find((decision) => decision.project.path === "/tmp/project-b")?.grantedSlots).toBe(1);
  });

  it("reports why a project was deferred when capacity is exhausted", () => {
    const decisions = planProjectDispatches([
      makeCandidate({ path: "/tmp/project-a", bestPriority: 0 }),
      makeCandidate({ path: "/tmp/project-b", bestPriority: 3 }),
    ], 1);

    const deferred = decisions.find((decision) => decision.project.path === "/tmp/project-b");
    expect(deferred?.grantedSlots).toBe(0);
    expect(deferred?.reason).toContain("deferred");
  });
});
