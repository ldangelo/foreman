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

const planWithTasks: DecompositionPlan = {
  epic: { title: "Auth Epic", description: "Full auth system" },
  tasks: [
    {
      title: "Create DB schema",
      description: "Design tables",
      priority: "high",
      dependencies: [],
      estimatedComplexity: "low",
    },
    {
      title: "Implement API",
      description: "REST endpoints",
      priority: "medium",
      dependencies: ["Create DB schema"],
      estimatedComplexity: "medium",
    },
  ],
};

describe("executePlan", () => {
  it("creates epic bead first with type epic", async () => {
    const { client } = makeMockBeads();
    await executePlan(planWithTasks, client);

    expect(client.create).toHaveBeenCalledTimes(3); // 1 epic + 2 tasks
    const firstCall = (client.create as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(firstCall[0]).toBe("Auth Epic");
    expect(firstCall[1]).toMatchObject({ type: "epic" });
  });

  it("creates child beads with parent reference to epic", async () => {
    const { client } = makeMockBeads();
    await executePlan(planWithTasks, client);

    // Epic gets beads-001, so children should reference it
    const createMock = client.create as ReturnType<typeof vi.fn>;
    const secondCall = createMock.mock.calls[1];
    expect(secondCall[1]).toMatchObject({ parent: "beads-001" });
    const thirdCall = createMock.mock.calls[2];
    expect(thirdCall[1]).toMatchObject({ parent: "beads-001" });
  });

  it("sets up dependencies via addDependency", async () => {
    const { client } = makeMockBeads();
    await executePlan(planWithTasks, client);

    // "Implement API" (beads-003) depends on "Create DB schema" (beads-002)
    expect(client.addDependency).toHaveBeenCalledWith("beads-003", "beads-002");
  });

  it("returns epicBeadId and all taskBeadIds", async () => {
    const { client } = makeMockBeads();
    const result = await executePlan(planWithTasks, client);

    expect(result.epicBeadId).toBe("beads-001");
    expect(result.taskBeadIds).toEqual(["beads-002", "beads-003"]);
  });

  it("handles plan with zero tasks (only epic created)", async () => {
    const { client } = makeMockBeads();
    const emptyPlan: DecompositionPlan = {
      epic: { title: "Empty Epic", description: "No tasks" },
      tasks: [],
    };
    const result = await executePlan(emptyPlan, client);

    expect(client.create).toHaveBeenCalledTimes(1);
    expect(result.epicBeadId).toBe("beads-001");
    expect(result.taskBeadIds).toEqual([]);
    expect(client.addDependency).not.toHaveBeenCalled();
  });
});
