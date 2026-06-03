import { describe, expect, it } from "vitest";
import { attachCommand } from "../commands/attach.js";

describe("attach --follow command wiring", () => {
  it("keeps follow-capable attach command registered", () => {
    expect(attachCommand.name()).toBe("attach");
    expect(attachCommand.options.some((opt) => opt.long === "--follow")).toBe(true);
  });
});
