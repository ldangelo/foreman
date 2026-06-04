import { describe, expect, it } from "vitest";
import { inboxCommand } from "../commands/inbox.js";

describe("inbox command", () => {
  it("loads the production command", () => {
    expect(inboxCommand.name()).toBe("inbox");
  });
});
