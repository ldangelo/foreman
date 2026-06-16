/**
 * agent-worker-create-pr-lookup.test.ts
 *
 * Regression test for foreman-63432: Fix create-pr run lookup for registered/native runs.
 *
 * The create-pr built-in phase can fail after finalize with "Run <runId> not found"
 * even though task/run/logs exist. This happens when:
 *
 * 1. registeredProjectId is set but registeredReadStore is undefined
 * 2. runLookup falls back to the dual-write store
 * 3. The dual-write store's getRun reads from local SQLite, not Postgres
 * 4. The run exists in Postgres but not in local SQLite, causing lookup to fail
 *
 * The fix adds fallback logic to create a PostgresStore when registeredReadStore
 * is undefined but registeredProjectId is available, mirroring the existing pattern
 * in onPipelineComplete.
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

describe("agent-worker.ts — create-pr run lookup for registered/native runs (foreman-63432)", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("has fallback logic for registeredReadStore in runCreatePrBuiltinPhase", () => {
    // Verify that runCreatePrBuiltinPhase has the fallback pattern similar to onPipelineComplete
    // This ensures that when registeredReadStore is undefined but registeredProjectId is available,
    // a fallback PostgresStore is created for run lookups.
    expect(source).toContain("fallbackRegisteredProjectId");
    expect(source).toContain("fallbackRegisteredReadStore");
    expect(source).toContain("refineryProjectId");
    expect(source).toContain("refineryRunLookup");
  });

  it("uses fallbackRegisteredProjectId when registeredProjectId is not set", () => {
    // The fallback logic should use config.projectId when registeredProjectId is not set
    const createPrIdx = source.indexOf("async function runCreatePrBuiltinPhase");
    expect(createPrIdx).toBeGreaterThan(-1);

    const block = source.slice(createPrIdx, createPrIdx + 3000);
    // Verify fallback uses config.projectId as the project ID source
    expect(block).toContain("fallbackRegisteredProjectId = !registeredProjectId");
    expect(block).toContain("config.projectId");
  });

  it("creates fallback PostgresStore when registeredReadStore is unavailable", () => {
    // When registeredReadStore is undefined but fallbackRegisteredProjectId is set,
    // a new PostgresStore should be created
    const createPrIdx = source.indexOf("async function runCreatePrBuiltinPhase");
    const block = source.slice(createPrIdx, createPrIdx + 3000);

    // Verify the fallback store creation pattern
    expect(block).toContain("PostgresStore.forProject(fallbackRegisteredProjectId)");
    expect(block).toContain("!registeredReadStore && fallbackRegisteredProjectId");
  });

  it("constructs refineryOptions with proper fallback chain", () => {
    // The refinery should be constructed with the proper options that include
    // the fallback runLookup when registeredReadStore is not available
    const createPrIdx = source.indexOf("async function runCreatePrBuiltinPhase");
    const block = source.slice(createPrIdx, createPrIdx + 3000);

    // Verify the complete fallback chain
    expect(block).toContain("refineryProjectId && refineryRunLookup");
    expect(block).toContain("registeredProjectId ?? fallbackRegisteredProjectId");
    expect(block).toContain("registeredReadStore ?? fallbackRegisteredReadStore");
  });

  it("matches the onPipelineComplete fallback pattern for consistency", () => {
    // The fallback logic in runCreatePrBuiltinPhase should mirror onPipelineComplete
    // to ensure consistent behavior across all pipeline phases

    // Find onPipelineComplete fallback pattern - need larger slice to include the fallback
    // (onPipelineComplete starts at line 1658, fallback is at line 1850)
    const onPipelineCompleteIdx = source.indexOf("async onPipelineComplete");
    const onPipelineBlock = source.slice(onPipelineCompleteIdx, onPipelineCompleteIdx + 15000);
    expect(onPipelineBlock).toContain("fallbackRegisteredProjectId");

    // Find runCreatePrBuiltinPhase fallback pattern
    const createPrIdx = source.indexOf("async function runCreatePrBuiltinPhase");
    const createPrBlock = source.slice(createPrIdx, createPrIdx + 3000);

    // Both should have the same fallback logic
    expect(createPrBlock).toContain("!registeredProjectId && resolveProjectDatabaseUrl");
    expect(createPrBlock).toContain("PostgresStore.forProject");
  });

  it("passes correct refineryOptions to Refinery constructor", () => {
    // The Refinery constructor should receive the properly constructed options
    // that include the fallback runLookup
    const createPrIdx = source.indexOf("async function runCreatePrBuiltinPhase");
    const block = source.slice(createPrIdx, createPrIdx + 3000);

    // Verify refineryOptions is passed to Refinery
    expect(block).toContain("new Refinery(");
    expect(block).toContain("refineryOptions");
  });
});
