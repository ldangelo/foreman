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

});
