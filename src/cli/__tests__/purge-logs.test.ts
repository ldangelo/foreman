import { describe, expect, it } from "vitest";
import { purgeLogsCommand } from "../commands/purge-logs.js";

describe("purge-logs command", () => {
  it("loads the production command", () => {
    expect(purgeLogsCommand.name()).toBe("purge-logs");
  });
});
