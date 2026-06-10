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
});
