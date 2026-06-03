import { describe, expect, it } from "vitest";
import { attachCommand } from "../commands/attach.js";

/** Legacy local ForemanStore attach fixtures were removed with sqlite. */
describe("attach command", () => {
  it("loads the production command", () => {
    expect(attachCommand.name()).toBe("attach");
  });
});
