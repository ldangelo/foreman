/**
 * agent-worker-create-pr-registered-lookup.test.ts
 *
 * Regression test for foreman-63432: Fix create-pr run lookup for registered/native runs.
 *
 * The `create-pr` built-in phase can fail after finalize with 'Run <runId> not found'
 * even though task/run/logs exist and branch was pushed. This happens because
 * runCreatePrBuiltinPhase lacked the fallback logic for runLookup that exists in
 * runPipeline's post-finalize PR creation path.
 *
 * The fix extracts the duplicated fallback logic into a shared helper function
 * `deriveFallbackRefineryOptions` that encapsulates the logic for deriving fallback
 * refinery options. This helper is used by both runCreatePrBuiltinPhase and runPipeline
 * to ensure registered/native runs can be found even when registeredProjectId was
 * not propagated through the pipeline context.
 *
 * Error handling: The helper safely handles the case where the connection pool may
 * not be properly initialized by wrapping PostgresStore.forProject in a try-catch.
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

describe("agent-worker.ts — create-pr registered run lookup fix (foreman-63432)", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("deriveFallbackRefineryOptions helper function exists before runCreatePrBuiltinPhase", () => {
    // The helper function should be defined before runCreatePrBuiltinPhase
    const helperIdx = source.indexOf("function deriveFallbackRefineryOptions(");
    expect(helperIdx).toBeGreaterThan(-1);

    const funcIdx = source.indexOf("async function runCreatePrBuiltinPhase");
    expect(funcIdx).toBeGreaterThan(-1);

    // Helper should come before the function that uses it
    expect(helperIdx).toBeLessThan(funcIdx);
  });

  it("deriveFallbackRefineryOptions contains the fallback logic with error handling", () => {
    // Find the helper function
    const helperIdx = source.indexOf("function deriveFallbackRefineryOptions(");
    expect(helperIdx).toBeGreaterThan(-1);

    // Extract the helper function body (next 1500 chars should cover it)
    const helperBlock = source.slice(helperIdx, helperIdx + 1500);

    // The helper should contain the fallback logic
    expect(helperBlock).toContain("fallbackRegisteredProjectId");
    expect(helperBlock).toContain("resolveProjectDatabaseUrl(pipelineProjectPath)");
    expect(helperBlock).toContain("configProjectId");
    expect(helperBlock).toContain("PostgresStore.forProject");
    expect(helperBlock).toContain("fallbackRegisteredProjectId");
    expect(helperBlock).toContain("registeredReadStore ?? fallbackReadStore");
    expect(helperBlock).toContain("registeredProjectId: refineryProjectId");
    expect(helperBlock).toContain("runLookup");
  });

  it("deriveFallbackRefineryOptions includes try-catch error handling for PostgresStore.forProject", () => {
    const helperIdx = source.indexOf("function deriveFallbackRefineryOptions(");
    expect(helperIdx).toBeGreaterThan(-1);

    const helperBlock = source.slice(helperIdx, helperIdx + 1500);

    // Should have try-catch around PostgresStore.forProject
    expect(helperBlock).toContain("try {");
    expect(helperBlock).toContain("PostgresStore.forProject(projectIdForFallback)");
    expect(helperBlock).toContain("catch");
    // Should log the error
    expect(helperBlock).toContain("log?.(");
    expect(helperBlock).toContain("Failed to create PostgresStore for fallback");
  });

  it("runCreatePrBuiltinPhase calls deriveFallbackRefineryOptions for fallback logic", () => {
    const idx = source.indexOf("async function runCreatePrBuiltinPhase");
    expect(idx).toBeGreaterThan(-1);

    // Extract the function body (first 3000 chars should cover the Refinery construction)
    const block = source.slice(idx, idx + 3000);

    // Should call the helper function
    expect(block).toContain("deriveFallbackRefineryOptions(");
    expect(block).toContain("registeredProjectId,");
    expect(block).toContain("registeredReadStore,");
    expect(block).toContain("pipelineProjectPath,");
    expect(block).toContain("config.projectId,");
    expect(block).toContain("log,");
  });

  it("runCreatePrBuiltinPhase passes registeredRefineryOptions to Refinery constructor", () => {
    const idx = source.indexOf("async function runCreatePrBuiltinPhase");
    expect(idx).toBeGreaterThan(-1);
    const block = source.slice(idx, idx + 3000);

    // The fix should use registeredRefineryOptions variable instead of inline conditional
    expect(block).toContain("registeredRefineryOptions,");
    // Should NOT have the old pattern: registeredProjectId && registeredReadStore ?
    expect(block).not.toContain("registeredProjectId && registeredReadStore ?");
  });

  it("runPipeline also calls deriveFallbackRefineryOptions for fallback logic", () => {
    // Find the runPipeline function
    const funcIdx = source.indexOf("async function runPipeline(");
    expect(funcIdx).toBeGreaterThan(-1);

    // Look for where the fallback block should be (after PR review gate logic)
    const fallbackCallIdx = source.indexOf("deriveFallbackRefineryOptions(", funcIdx);
    expect(fallbackCallIdx).toBeGreaterThan(-1);

    // Extract the context around the call
    const contextBlock = source.slice(fallbackCallIdx - 200, fallbackCallIdx + 500);

    // Should pass the same parameters
    expect(contextBlock).toContain("registeredProjectId,");
    expect(contextBlock).toContain("registeredReadStore,");
    expect(contextBlock).toContain("pipelineProjectPath,");
    expect(contextBlock).toContain("config.projectId,");
    expect(contextBlock).toContain("log,");
  });

  it("no duplicate fallback logic blocks remain - only one definition of deriveFallbackRefineryOptions", () => {
    // There should be exactly one definition of deriveFallbackRefineryOptions
    const firstIdx = source.indexOf("function deriveFallbackRefineryOptions(");
    expect(firstIdx).toBeGreaterThan(-1);

    // Search for another occurrence after the first
    const secondIdx = source.indexOf("function deriveFallbackRefineryOptions(", firstIdx + 1);
    expect(secondIdx).toBe(-1); // Should not find another one

    // There should be exactly two calls to deriveFallbackRefineryOptions (runCreatePrBuiltinPhase and runPipeline)
    // Call pattern is "const ... = deriveFallbackRefineryOptions("
    const callPattern = "deriveFallbackRefineryOptions(";
    let callCount = 0;
    let searchFrom = 0;
    while (true) {
      const callIdx = source.indexOf(callPattern, searchFrom);
      if (callIdx === -1) break;
      // Check it's not the definition (which is "function deriveFallbackRefineryOptions(")
      const prev15 = source.slice(Math.max(0, callIdx - 15), callIdx);
      if (!prev15.includes("function")) {
        callCount++;
      }
      searchFrom = callIdx + 1;
    }
    expect(callCount).toBe(2); // One in runCreatePrBuiltinPhase, one in runPipeline
  });
});
