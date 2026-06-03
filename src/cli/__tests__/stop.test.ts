import { describe, expect, it } from "vitest";
import { stopCommand } from "../commands/stop.js";

describe("stop command", () => {
  it("loads the production command", () => {
    expect(stopCommand.name()).toBe("stop");
  });
});
