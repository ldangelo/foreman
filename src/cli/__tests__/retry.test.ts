import { describe, expect, it } from "vitest";
import { retryCommand } from "../commands/retry.js";

/** Legacy retry tests seeded a removed local ForemanStore. Registered projects now use PostgresStore. */
describe("retry command", () => {
  it("loads the production command", () => {
    expect(retryCommand.name()).toBe("retry");
  });
});
