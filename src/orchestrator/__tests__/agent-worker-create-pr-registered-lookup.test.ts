import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

describe("agent-worker.ts — create-pr Elixir run lookup", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("defines an Elixir run lookup before create-pr built-in phase", () => {
    const helperIdx = source.indexOf("function createElixirRunLookup(");
    const funcIdx = source.indexOf("async function runCreatePrBuiltinPhase");

    expect(helperIdx).toBeGreaterThan(-1);
    expect(funcIdx).toBeGreaterThan(-1);
    expect(helperIdx).toBeLessThan(funcIdx);
  });

  it("create-pr uses Elixir projection lookup, not Postgres fallback", () => {
    const helperIdx = source.indexOf("function deriveFallbackRefineryOptions(");
    expect(helperIdx).toBeGreaterThan(-1);

    const helperBlock = source.slice(helperIdx, helperIdx + 900);
    expect(helperBlock).toContain("createElixirRunLookup(refineryProjectId)");
    expect(helperBlock).not.toContain("PostgresStore");
    expect(helperBlock).not.toContain("resolveProjectDatabaseUrl");
    expect(helperBlock).not.toContain("DATABASE_URL");
  });

  it("runCreatePrBuiltinPhase passes Elixir refinery options to Refinery", () => {
    const idx = source.indexOf("async function runCreatePrBuiltinPhase");
    expect(idx).toBeGreaterThan(-1);
    const block = source.slice(idx, idx + 3000);

    expect(block).toContain("deriveFallbackRefineryOptions(");
    expect(block).toContain("registeredRefineryOptions,");
    expect(block).not.toContain("registeredProjectId && registeredReadStore ?");
  });

  it("helper is called by the finalize/create-pr refinery setup", () => {
    const callPattern = "deriveFallbackRefineryOptions(";
    let callCount = 0;
    let searchFrom = 0;
    while (true) {
      const callIdx = source.indexOf(callPattern, searchFrom);
      if (callIdx === -1) break;
      const prefix = source.slice(Math.max(0, callIdx - 15), callIdx);
      if (!prefix.includes("function")) callCount++;
      searchFrom = callIdx + 1;
    }
    expect(callCount).toBe(1);
  });
});
