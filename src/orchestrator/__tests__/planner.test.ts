import { describe, it, expect, vi } from "vitest";
import { executePlan } from "../planner.js";
import type { DecompositionPlan } from "../types.js";
import type { Bead, BeadsClient } from "../../lib/beads.js";

function makeMockBeads() {
  let counter = 0;
  const createCalls: Array<{ title: string; opts: any }> = [];
  const depCalls: Array<{ childId: string; parentId: string }> = [];

  const client = {
    create: vi.fn(async (title: string, opts?: any): Promise<Bead> => {
      counter++;
      createCalls.push({ title, opts });
      return {
        id: `beads-${String(counter).padStart(3, "0")}`,
        title,
        type: opts?.type ?? "task",
        priority: opts?.priority ?? "medium",
        status: "open",
        assignee: null,
        parent: opts?.parent ?? null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };
    }),
    addDependency: vi.fn(async (childId: string, parentId: string) => {
      depCalls.push({ childId, parentId });
    }),
  };

  return { client: client as unknown as BeadsClient, createCalls, depCalls };
}

const hierarchicalPlan: DecompositionPlan = {
  epic: { title: "Auth Epic", description: "Full auth system" },
  sprints: [
    {
      title: "Sprint 1: Foundation",
      goal: "Database and core auth",
      stories: [
        {
          title: "As a developer, I can persist user data",
          description: "Database foundation",
          priority: "critical",
          tasks: [
            {
              title: "Create DB schema",
              description: "Design tables",
              type: "task",
              priority: "high",
              dependencies: [],
              estimatedComplexity: "low",
            },
          ],
        },
        {
          title: "As a user, I can register",
          description: "Registration flow",
          priority: "high",
          tasks: [
            {
              title: "Implement API",
              description: "REST endpoints",
              type: "task",
              priority: "medium",
              dependencies: ["Create DB schema"],
              estimatedComplexity: "medium",
            },
            {
              title: "Spike on OAuth providers",
              description: "Research OAuth options",
              type: "spike",
              priority: "medium",
              dependencies: [],
              estimatedComplexity: "low",
            },
          ],
        },
      ],
    },
  ],
};

describe("executePlan", () => {
  it("creates full hierarchy: epic → sprint → story → task", async () => {
    const { client } = makeMockBeads();
    await executePlan(hierarchicalPlan, client);

    // 1 epic + 1 sprint + 2 stories + 3 tasks = 7 creates
    expect(client.create).toHaveBeenCalledTimes(7);

    const calls = (client.create as ReturnType<typeof vi.fn>).mock.calls;

    // Epic (beads-001)
    expect(calls[0][0]).toBe("Auth Epic");
    expect(calls[0][1]).toMatchObject({ type: "epic" });

    // Sprint (beads-002) → mapped to bd type "feature" with label "kind:sprint"
    expect(calls[1][0]).toBe("Sprint 1: Foundation");
    expect(calls[1][1]).toMatchObject({ type: "feature", parent: "beads-001" });
    expect(calls[1][1].labels).toContain("kind:sprint");

    // Story 1 (beads-003) → mapped to bd type "feature" with label "kind:story"
    expect(calls[2][0]).toBe("As a developer, I can persist user data");
    expect(calls[2][1]).toMatchObject({ type: "feature", parent: "beads-002" });
    expect(calls[2][1].labels).toContain("kind:story");

    // Task 1 (beads-004), parent = story 1
    expect(calls[3][0]).toBe("Create DB schema");
    expect(calls[3][1]).toMatchObject({ type: "task", parent: "beads-003" });

    // Story 2 (beads-005), parent = sprint
    expect(calls[4][0]).toBe("As a user, I can register");
    expect(calls[4][1]).toMatchObject({ type: "feature", parent: "beads-002" });

    // Task 2 (beads-006), parent = story 2
    expect(calls[5][0]).toBe("Implement API");
    expect(calls[5][1]).toMatchObject({ type: "task", parent: "beads-005" });

    // Spike (beads-007) → mapped to bd type "chore" with label "kind:spike"
    expect(calls[6][0]).toBe("Spike on OAuth providers");
    expect(calls[6][1]).toMatchObject({ type: "chore", parent: "beads-005" });
    expect(calls[6][1].labels).toContain("kind:spike");
  });

  it("sets up cross-story dependencies via addDependency", async () => {
    const { client } = makeMockBeads();
    await executePlan(hierarchicalPlan, client);

    // "Implement API" (beads-006) depends on "Create DB schema" (beads-004)
    expect(client.addDependency).toHaveBeenCalledWith("beads-006", "beads-004");
  });

  it("does not add container dependencies (bd parent-child handles it)", async () => {
    const { client, depCalls } = makeMockBeads();
    await executePlan(hierarchicalPlan, client);

    // Only cross-task deps should exist, no container deps.
    // "Implement API" (beads-006) depends on "Create DB schema" (beads-004)
    expect(depCalls).toContainEqual({ childId: "beads-006", parentId: "beads-004" });

    // No container should appear as childId (containers = epic, sprint, stories)
    const containerIds = ["beads-001", "beads-002", "beads-003", "beads-005"];
    for (const id of containerIds) {
      expect(depCalls).not.toContainEqual(
        expect.objectContaining({ childId: id }),
      );
    }
  });

  it("returns all bead IDs organized by level", async () => {
    const { client } = makeMockBeads();
    const result = await executePlan(hierarchicalPlan, client);

    expect(result.epicBeadId).toBe("beads-001");
    expect(result.sprintBeadIds).toEqual(["beads-002"]);
    expect(result.storyBeadIds).toEqual(["beads-003", "beads-005"]);
    expect(result.taskBeadIds).toEqual(["beads-004", "beads-006", "beads-007"]);
  });

  it("handles plan with empty sprints (only epic created)", async () => {
    const { client } = makeMockBeads();
    const emptyPlan: DecompositionPlan = {
      epic: { title: "Empty Epic", description: "No work" },
      sprints: [],
    };
    const result = await executePlan(emptyPlan, client);

    expect(client.create).toHaveBeenCalledTimes(1);
    expect(result.epicBeadId).toBe("beads-001");
    expect(result.sprintBeadIds).toEqual([]);
    expect(result.storyBeadIds).toEqual([]);
    expect(result.taskBeadIds).toEqual([]);
    expect(client.addDependency).not.toHaveBeenCalled();
  });

  it("maps spike type to chore with kind:spike label", async () => {
    const { client, createCalls } = makeMockBeads();
    await executePlan(hierarchicalPlan, client);

    const spikeBead = createCalls.find((c) => c.title === "Spike on OAuth providers");
    expect(spikeBead?.opts.type).toBe("chore");
    expect(spikeBead?.opts.labels).toContain("kind:spike");
  });

  it("maps priorities correctly to P0-P3", async () => {
    const plan: DecompositionPlan = {
      epic: { title: "Priority Test", description: "Test priority mapping" },
      sprints: [{
        title: "Sprint 1",
        goal: "Test",
        stories: [{
          title: "Story",
          description: "Story desc",
          priority: "critical",
          tasks: [
            { title: "Critical task", description: "d", type: "task", priority: "critical", dependencies: [], estimatedComplexity: "low" },
            { title: "High task", description: "d", type: "task", priority: "high", dependencies: [], estimatedComplexity: "low" },
            { title: "Medium task", description: "d", type: "task", priority: "medium", dependencies: [], estimatedComplexity: "low" },
            { title: "Low task", description: "d", type: "task", priority: "low", dependencies: [], estimatedComplexity: "low" },
          ],
        }],
      }],
    };

    const { createCalls, client } = makeMockBeads();
    await executePlan(plan, client);

    const taskCalls = createCalls.filter((c) => c.opts.type === "task");
    expect(taskCalls[0].opts.priority).toBe("P0");
    expect(taskCalls[1].opts.priority).toBe("P1");
    expect(taskCalls[2].opts.priority).toBe("P2");
    expect(taskCalls[3].opts.priority).toBe("P3");
  });

  it("does not add kind label for regular tasks", async () => {
    const { client, createCalls } = makeMockBeads();
    await executePlan(hierarchicalPlan, client);

    const taskBead = createCalls.find((c) => c.title === "Create DB schema");
    expect(taskBead?.opts.labels).not.toContain("kind:task");
    expect(taskBead?.opts.labels).toContain("complexity:low");
  });
});
