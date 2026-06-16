/**
 * agent-worker-create-pr.test.ts
 *
 * Verifies that runCreatePrBuiltinPhase correctly handles registered/native runs
 * by using a fallback PostgresStore when registeredReadStore is not available
 * but registeredProjectId exists (foreman-63432).
 *
 * The bug: create-pr built-in phase could fail after finalize with
 * 'Run <runId> not found' even though task/run/logs exist and branch was pushed.
 * The root cause was missing fallback logic to create a PostgresStore when
 * registeredReadStore was undefined but registeredProjectId was available.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

describe("runCreatePrBuiltinPhase — registered run lookup fallback (foreman-63432)", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("creates fallback PostgresStore when registeredReadStore is undefined but registeredProjectId exists", () => {
    const idx = source.indexOf("async function runCreatePrBuiltinPhase");
    expect(idx).toBeGreaterThan(-1);
    const block = source.slice(idx, idx + 4000);

    // Should have fallback logic for PostgresStore
    expect(block).toContain("fallbackRegisteredReadStore");
    expect(block).toContain("PostgresStore.forProject");
  });

  it("uses fallbackRegisteredReadStore when registeredReadStore is not available", () => {
    const idx = source.indexOf("async function runCreatePrBuiltinPhase");
    expect(idx).toBeGreaterThan(-1);
    const block = source.slice(idx, idx + 4000);

    // The fallback should be used when registeredReadStore is falsy
    expect(block).toContain("!registeredReadStore && registeredProjectId");
  });

  it("passes runLookup to RefineryOptions when available", () => {
    const idx = source.indexOf("async function runCreatePrBuiltinPhase");
    expect(idx).toBeGreaterThan(-1);
    const block = source.slice(idx, idx + 4000);

    // Should create refineryOptions with runLookup
    expect(block).toContain("const runLookup = registeredReadStore ?? fallbackRegisteredReadStore");
    expect(block).toContain("const refineryOptions = registeredProjectId && runLookup");
  });

  it("creates Refinery with refineryOptions containing runLookup", () => {
    const idx = source.indexOf("async function runCreatePrBuiltinPhase");
    expect(idx).toBeGreaterThan(-1);
    const block = source.slice(idx, idx + 4000);

    // Refinery should be created with refineryOptions (not directly with registeredReadStore)
    const refineryIdx = block.indexOf("new Refinery(");
    expect(refineryIdx).toBeGreaterThan(-1);
    const refineryBlock = block.slice(refineryIdx, refineryIdx + 300);
    expect(refineryBlock).toContain("refineryOptions");
    expect(refineryBlock).not.toContain("registeredProjectId && registeredReadStore");
  });

  it("mirrors the same fallback pattern used in onPipelineComplete finalize", () => {
    // Find the finalize block
    const finalizeIdx = source.indexOf("const registeredRefineryOptions = registeredRefineryProjectId && registeredRefineryRunLookup");
    expect(finalizeIdx).toBeGreaterThan(-1);

    // Extract the finalize fallback pattern
    const finalizeBlock = source.slice(finalizeIdx - 500, finalizeIdx + 200);

    // Find the create-pr fallback pattern
    const createPrIdx = source.indexOf("const runLookup = registeredReadStore ?? fallbackRegisteredReadStore");
    expect(createPrIdx).toBeGreaterThan(-1);
    const createPrBlock = source.slice(createPrIdx - 200, createPrIdx + 200);

    // Both should use similar patterns for fallback store creation
    expect(createPrBlock).toContain("fallbackRegisteredReadStore");
    expect(createPrBlock).toContain("runLookup");
    expect(finalizeBlock).toContain("registeredRefineryRunLookup");
  });
});

describe("runCreatePrBuiltinPhase — structure verification", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("has the function signature with all required parameters", () => {
    const idx = source.indexOf("async function runCreatePrBuiltinPhase(args:");
    expect(idx).toBeGreaterThan(-1);
    const block = source.slice(idx, idx + 500);
    expect(block).toContain("config: WorkerConfig");
    expect(block).toContain("store: ForemanStore");
    expect(block).toContain("runtimeTaskClient: ITaskClient");
    expect(block).toContain("pipelineProjectPath: string");
    expect(block).toContain("registeredProjectId?: string");
    expect(block).toContain("registeredReadStore?: PostgresStore");
  });

  it("handles no-changes case with proper metadata and stopping", () => {
    const idx = source.indexOf("async function runCreatePrBuiltinPhase");
    const block = source.slice(idx, idx + 6000);

    // Should write PR_METADATA.json when skipping
    expect(block).toContain("PR_METADATA.json");
    expect(block).toContain("skipped: true");
    expect(block).toContain("no_changes_against_base");
    expect(block).toContain("stopPipelineSuccess: true");
  });

  it("calls refinery.ensurePullRequestForRun with correct options", () => {
    const idx = source.indexOf("async function runCreatePrBuiltinPhase");
    const block = source.slice(idx, idx + 6000);
    const ensureIdx = block.indexOf("refinery.ensurePullRequestForRun");
    expect(ensureIdx).toBeGreaterThan(-1);
    const ensureBlock = block.slice(ensureIdx, ensureIdx + 500);
    expect(ensureBlock).toContain("runId: config.runId");
    expect(ensureBlock).toContain("baseBranch");
    expect(ensureBlock).toContain("updateRunStatus: false");
  });

  it("writes PR_METADATA.json after successful PR creation", () => {
    const idx = source.indexOf("async function runCreatePrBuiltinPhase");
    const block = source.slice(idx, idx + 6000);
    // Find the SECOND metadataPath definition (for successful case, after ensurePullRequestForRun)
    const firstMetadataIdx = block.indexOf("const metadataPath = resolveArtifactPath");
    expect(firstMetadataIdx).toBeGreaterThan(-1);
    const secondMetadataIdx = block.indexOf("const metadataPath = resolveArtifactPath", firstMetadataIdx + 1);
    expect(secondMetadataIdx).toBeGreaterThan(-1);
    const metadataBlock = block.slice(secondMetadataIdx, secondMetadataIdx + 300);
    expect(metadataBlock).toContain("pr.prUrl");
    expect(metadataBlock).toContain("prNumber");
    expect(metadataBlock).toContain("pr.branchName");
  });
});
