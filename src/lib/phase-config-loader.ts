/**
 * phase-config-loader.ts — Load per-phase mechanical configuration.
 *
 * Reads ~/.foreman/phases.json for user-provided phase config (model, budget, tools).
 * Falls back to ROLE_CONFIGS from roles.ts if file is absent, invalid JSON, or
 * fails schema validation.
 *
 * TRD-2026-003: TRD-011, TRD-012 [satisfies REQ-009, REQ-010]
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { ROLE_CONFIGS } from "../orchestrator/roles.js";

// ── Public types ───────────────────────────────────────────────────────────────

/**
 * Shape of a single phase entry in ~/.foreman/phases.json.
 * Extra fields are silently ignored.
 */
export interface PhaseConfigEntry {
  model: string;
  maxBudgetUsd: number;
  allowedTools: string[];
  reportFile: string;
  promptFile: string;
}

/** The full phases.json schema: a map of phase name to PhaseConfigEntry. */
export type PhaseConfigFile = Record<string, PhaseConfigEntry>;

// ── Validation ─────────────────────────────────────────────────────────────────

/**
 * Validate a single phase config entry.
 * Throws with a descriptive message if any required field is missing or wrong type.
 * Extra fields are silently ignored.
 *
 * TRD-012 [satisfies REQ-010]
 *
 * @throws Error with message "Phase '{phaseName}': field '{fieldName}' must be {type}, got {actual}"
 */
export function validatePhaseConfigEntry(phaseName: string, raw: unknown): void {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new Error(
      `Phase '${phaseName}': must be an object, got ${Array.isArray(raw) ? "array" : typeof raw}`,
    );
  }

  const entry = raw as Record<string, unknown>;

  // model: required string
  if (typeof entry["model"] !== "string") {
    throw new Error(
      `Phase '${phaseName}': field 'model' must be string, got ${typeof entry["model"]}`,
    );
  }

  // maxBudgetUsd: required number
  if (typeof entry["maxBudgetUsd"] !== "number") {
    throw new Error(
      `Phase '${phaseName}': field 'maxBudgetUsd' must be number, got ${typeof entry["maxBudgetUsd"]}`,
    );
  }

  // allowedTools: required string[]
  if (!Array.isArray(entry["allowedTools"])) {
    throw new Error(
      `Phase '${phaseName}': field 'allowedTools' must be string[], got ${typeof entry["allowedTools"]}`,
    );
  }
  for (const tool of entry["allowedTools"] as unknown[]) {
    if (typeof tool !== "string") {
      throw new Error(
        `Phase '${phaseName}': field 'allowedTools' must be string[], found non-string element: ${typeof tool}`,
      );
    }
  }

  // reportFile: required string
  if (typeof entry["reportFile"] !== "string") {
    throw new Error(
      `Phase '${phaseName}': field 'reportFile' must be string, got ${typeof entry["reportFile"]}`,
    );
  }

  // promptFile: required string
  if (typeof entry["promptFile"] !== "string") {
    throw new Error(
      `Phase '${phaseName}': field 'promptFile' must be string, got ${typeof entry["promptFile"]}`,
    );
  }
}

// ── Loader ─────────────────────────────────────────────────────────────────────

/**
 * Load per-phase configuration from ~/.foreman/phases.json.
 *
 * Resolution order:
 *   1. ~/.foreman/phases.json (user config)
 *   2. ROLE_CONFIGS from roles.ts (built-in fallback)
 *
 * After loading, env var overrides (FOREMAN_EXPLORER_MODEL, etc.) take precedence.
 * These are already applied in ROLE_CONFIGS at import time via resolveModel().
 *
 * @returns PhaseConfigFile if custom config loaded; ROLE_CONFIGS cast-compatible record otherwise
 */
export function loadPhaseConfigs(): PhaseConfigFile {
  const configPath = join(homedir(), ".foreman", "phases.json");

  if (!existsSync(configPath)) {
    // No custom config — return ROLE_CONFIGS as PhaseConfigFile
    return roleConfigsAsPhaseConfigFile();
  }

  let raw: string;
  try {
    raw = readFileSync(configPath, "utf-8");
  } catch (err) {
    console.warn(
      `[foreman] phase-config-loader: could not read ${configPath}: ${String(err)} — using built-in defaults`,
    );
    return roleConfigsAsPhaseConfigFile();
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    console.warn(
      `[foreman] phase-config-loader: invalid JSON in ${configPath}: ${String(err)} — using built-in defaults`,
    );
    return roleConfigsAsPhaseConfigFile();
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    console.warn(
      `[foreman] phase-config-loader: ${configPath} must be a JSON object — using built-in defaults`,
    );
    return roleConfigsAsPhaseConfigFile();
  }

  // Validate each phase entry
  const rawMap = parsed as Record<string, unknown>;
  for (const [phaseName, entry] of Object.entries(rawMap)) {
    try {
      validatePhaseConfigEntry(phaseName, entry);
    } catch (err) {
      console.warn(
        `[foreman] phase-config-loader: validation error in ${configPath}: ${String(err)} — using built-in defaults`,
      );
      return roleConfigsAsPhaseConfigFile();
    }
  }

  return rawMap as PhaseConfigFile;
}

// ── Helpers ────────────────────────────────────────────────────────────────────

/**
 * Convert ROLE_CONFIGS into a PhaseConfigFile-compatible record.
 * Adds placeholder promptFile fields (built-in prompts don't have file paths).
 *
 * Note: env var overrides (FOREMAN_EXPLORER_MODEL etc.) are already applied
 * in ROLE_CONFIGS at module import time via resolveModel() in roles.ts.
 */
function roleConfigsAsPhaseConfigFile(): PhaseConfigFile {
  const result: PhaseConfigFile = {};
  for (const [phaseName, config] of Object.entries(ROLE_CONFIGS)) {
    result[phaseName] = {
      model: config.model,
      maxBudgetUsd: config.maxBudgetUsd,
      allowedTools: [...config.allowedTools],
      reportFile: config.reportFile,
      promptFile: `${phaseName}.md`,
    };
  }
  return result;
}
