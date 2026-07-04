import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const RESET_SRC = fileURLToPath(new URL("../commands/reset.ts", import.meta.url));

describe("foreman reset after Elixir cutover", () => {
  const source = readFileSync(RESET_SRC, "utf8");

  it("does not use local br/run-store reset paths", () => {
    expect(source).toContain("Elixir");
    expect(source).not.toContain("FOREMAN_BACKEND=node");
    expect(source).not.toContain("enqueueResetTaskToOpen");
  });
});
