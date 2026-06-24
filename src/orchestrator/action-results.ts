import type { PhaseResult } from "./pipeline-executor.js";

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

export function assertPhaseActionResult(action: string, result: unknown): PhaseResult {
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    throw new Error(`Action ${action} must return a phase result object`);
  }
  const phaseResult = result as Partial<PhaseResult>;
  if (typeof phaseResult.success !== "boolean") {
    throw new Error(`Action ${action} returned invalid phase result: success must be a boolean`);
  }
  for (const key of ["costUsd", "turns", "tokensIn", "tokensOut"] as const) {
    if (!isFiniteNumber(phaseResult[key])) {
      throw new Error(`Action ${action} returned invalid phase result: ${key} must be a finite number`);
    }
  }
  if (phaseResult.error !== undefined && typeof phaseResult.error !== "string") {
    throw new Error(`Action ${action} returned invalid phase result: error must be a string`);
  }
  if (phaseResult.outputText !== undefined && typeof phaseResult.outputText !== "string") {
    throw new Error(`Action ${action} returned invalid phase result: outputText must be a string`);
  }
  return result as PhaseResult;
}
