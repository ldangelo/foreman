import { describe, expect, it } from "vitest";
import { NativeTaskClient } from "../native-task-client.js";

describe("NativeTaskClient", () => {
  it("loads production client", () => {
    expect(NativeTaskClient).toBeDefined();
  });

  it("allows retry-loop transitions from finalize back to remediation phases", () => {
    const client = new NativeTaskClient(process.cwd()) as unknown as {
      validateStatusTransition(id: string, fromStatus: string, toStatus: string): void;
    };

    expect(() => client.validateStatusTransition("task-1", "finalize", "developer")).not.toThrow();
    expect(() => client.validateStatusTransition("task-1", "finalize", "qa")).not.toThrow();
  });

  it("returns complete task metadata from registered Postgres tasks", async () => {
    const client = new NativeTaskClient("/tmp/project", { registeredProjectId: "project-1" }) as unknown as {
      show(id: string): Promise<Record<string, unknown>>;
      postgres: { getTask(projectId: string, id: string): Promise<Record<string, unknown>> };
    };

    client.postgres = {
      async getTask(projectId: string, id: string) {
        expect(projectId).toBe("project-1");
        expect(id).toBe("foreman-74294");
        return {
          id,
          title: "Ready tasks are not automatically dispatched",
          description: "Scheduler should dispatch ready tasks.",
          type: "bug",
          priority: 0,
          status: "ready",
          created_at: new Date("2026-01-01T00:00:00Z"),
          updated_at: new Date("2026-01-01T00:00:00Z"),
          labels: ["scheduler"],
        };
      },
    };

    await expect(client.show("foreman-74294")).resolves.toMatchObject({
      id: "foreman-74294",
      title: "Ready tasks are not automatically dispatched",
      description: "Scheduler should dispatch ready tasks.",
      type: "bug",
      priority: "0",
      status: "ready",
      labels: ["project:/tmp/project", "scheduler"],
    });
  });
});
