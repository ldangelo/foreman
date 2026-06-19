import { describe, expect, it } from "vitest";
import { taskCommand } from "../task.js";

describe("task command project resolution wiring", () => {
  it("loads task command", () => {
    expect(taskCommand.name()).toBe("task");
  });
});
