/**
 * workflow-config-loader.ts — Load pipeline workflow sequences by seed type.
 *
 * Reads ~/.foreman/workflows.json for user-provided workflow sequences.
 * Falls back to DEFAULT_WORKFLOWS if file is absent or invalid.
 *
 * Each workflow is an ordered array of phase names that must end with "finalize".
 *
 * TRD-2026-003: TRD-013, TRD-014, TRD-015 [satisfies REQ-011, REQ-024, REQ-025]
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { ROLE_CONFIGS } from "../orchestrator/roles.js";

// ── Default workflows ──────────────────────────────────────────────────────────

/** The built-in default workflow sequences for each standard seed type. */
export const DEFAULT_WORKFLOWS: Record<string, string[]> = {
  feature: ["explorer", "developer", "qa", "reviewer", "finalize"],
  bug: ["reproducer", "developer", "qa", "finalize"],
  chore: ["developer", "finalize"],
  docs: ["developer", "finalize"],
};

// ── Validation ─────────────────────────────────────────────────────────────────

/**
 * Validate that a workflow's phases are all known.
 *
 * Checks each phase against:
 *   1. phaseConfigs (user-loaded or ROLE_CONFIGS-derived)
 *   2. ROLE_CONFIGS (built-in fallback)
 *   3. "finalize" is always valid (implemented directly in runPipeline)
 *   4. "reproducer" is recognized as a known built-in phase
 *
 * TRD-014 [satisfies REQ-024]
 *
 * @throws Error with descriptive message if unknown phase found
 */
export function validateWorkflowPhases(
  workflow: string[],
  phaseConfigs: Record<string, unknown>,
  seedType: string,
): void {
  // Built-in phases that are always recognized
  const builtInPhases = new Set<string>([
    ...Object.keys(ROLE_CONFIGS),
    "finalize",
    "reproducer",
  ]);

  for (const phaseName of workflow) {
    // "finalize" is always valid — implemented directly in runPipeline
    if (phaseName === "finalize") continue;

    // Check phaseConfigs (user-provided or ROLE_CONFIGS-derived)
    if (phaseName in phaseConfigs) continue;

    // Check built-in ROLE_CONFIGS phases
    if (builtInPhases.has(phaseName)) continue;

    throw new Error(
      `Workflow '${seedType}' references unknown phase '${phaseName}' which has no config in phases.json or ROLE_CONFIGS`,
    );
  }
}

/**
 * Validate that all workflows in a map end with "finalize".
 *
 * TRD-015 [satisfies REQ-025]
 *
 * @throws Error with descriptive message if finalize is missing or not last
 */
export function validateFinalizeEnforcement(
  workflows: Record<string, string[]>,
): void {
  for (const [seedType, phases] of Object.entries(workflows)) {
    if (phases.length === 0) {
      throw new Error(
        `Workflow '${seedType}' must end with 'finalize' but is empty`,
      );
    }

    const lastPhase = phases[phases.length - 1];
    if (lastPhase !== "finalize") {
      throw new Error(
        `Workflow '${seedType}' must end with 'finalize' but ends with '${lastPhase}'`,
      );
    }

    // Check for finalize appearing earlier (but not last — already handled above)
    const finalizeIdx = phases.indexOf("finalize");
    if (finalizeIdx !== -1 && finalizeIdx !== phases.length - 1) {
      throw new Error(
        `Workflow '${seedType}' has 'finalize' at position ${finalizeIdx} but it must be the last phase`,
      );
    }
  }
}

// ── Loader ─────────────────────────────────────────────────────────────────────

/**
 * Load workflow sequences from ~/.foreman/workflows.json.
 *
 * Resolution order:
 *   1. ~/.foreman/workflows.json (user config)
 *   2. DEFAULT_WORKFLOWS (built-in fallback)
 *
 * Runs validateFinalizeEnforcement on any loaded config.
 * On any error (file not found, invalid JSON, validation failure): warns and returns DEFAULT_WORKFLOWS.
 *
 * @returns Record mapping seed type to ordered phase array
 */
export function loadWorkflows(): Record<string, string[]> {
  const configPath = join(homedir(), ".foreman", "workflows.json");

  if (!existsSync(configPath)) {
    return DEFAULT_WORKFLOWS;
  }

  let raw: string;
  try {
    raw = readFileSync(configPath, "utf-8");
  } catch (err) {
    console.warn(
      `[foreman] workflow-config-loader: could not read ${configPath}: ${String(err)} — using built-in defaults`,
    );
    return DEFAULT_WORKFLOWS;
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    console.warn(
      `[foreman] workflow-config-loader: invalid JSON in ${configPath}: ${String(err)} — using built-in defaults`,
    );
    return DEFAULT_WORKFLOWS;
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    console.warn(
      `[foreman] workflow-config-loader: ${configPath} must be a JSON object — using built-in defaults`,
    );
    return DEFAULT_WORKFLOWS;
  }

  // Validate that all values are string arrays
  const rawMap = parsed as Record<string, unknown>;
  const validated: Record<string, string[]> = {};

  for (const [seedType, phases] of Object.entries(rawMap)) {
    if (!Array.isArray(phases)) {
      console.warn(
        `[foreman] workflow-config-loader: workflow '${seedType}' must be an array — using built-in defaults`,
      );
      return DEFAULT_WORKFLOWS;
    }
    for (const phase of phases as unknown[]) {
      if (typeof phase !== "string") {
        console.warn(
          `[foreman] workflow-config-loader: workflow '${seedType}' contains non-string phase — using built-in defaults`,
        );
        return DEFAULT_WORKFLOWS;
      }
    }
    validated[seedType] = phases as string[];
  }

  // Run finalize enforcement on the loaded workflows
  try {
    validateFinalizeEnforcement(validated);
  } catch (err) {
    console.warn(
      `[foreman] workflow-config-loader: ${String(err)} — using built-in defaults`,
    );
    return DEFAULT_WORKFLOWS;
  }

  return validated;
}

/**
 * Get the workflow phase sequence for a given seed type.
 *
 * Falls back to the "feature" workflow for unknown seed types.
 *
 * @param seedType  Seed type (e.g. "feature", "bug", "chore")
 * @returns         Ordered array of phase names (always ends with "finalize")
 */
export function getWorkflow(seedType: string): string[] {
  const workflows = loadWorkflows();
  return workflows[seedType] ?? workflows["feature"] ?? DEFAULT_WORKFLOWS["feature"];
}
