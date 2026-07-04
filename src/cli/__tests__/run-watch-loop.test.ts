import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const RUN_SRC = fileURLToPath(new URL("../commands/run.ts", import.meta.url));

describe("run watch loop after Elixir cutover", () => {
  const source = readFileSync(RUN_SRC, "utf8");

  it("normal runtime no longer owns the dispatch/watch loop", () => {
    expect(source).toContain("Use 'foreman watch' or 'foreman status --watch' to monitor Elixir-backed runs.");
    expect(source).toContain("await client.schedulerTick();");
  });

  it("legacy local test-runtime path keeps empty-poll protection", () => {
    expect(source).toContain("emptyPollCount");
    expect(source).toContain("No ready beads after ${emptyPollCount} poll cycle(s)");
  });
});
