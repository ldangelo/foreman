import { describe, expect, it } from "vitest";
import { purgeZombieRunsCommand } from "../commands/purge-zombie-runs.js";

describe("purge-zombie-runs command", () => {
  it("loads the production command", () => {
    expect(purgeZombieRunsCommand.name()).toBe("purge-zombie-runs");
  });
});
