import { describe, expect, it } from "vitest";
import { taskCommand } from "../commands/task.js";

describe("task project resolution command wiring", () => {
  it("loads task command", () => {
    expect(taskCommand.name()).toBe("task");
  });
});
