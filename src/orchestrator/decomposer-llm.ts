import type { DecompositionPlan } from "./types.js";

/**
 * LLM-powered PRD decomposer (future implementation).
 *
 * This will use OpenClaw sessions_spawn to call an LLM (e.g. Claude)
 * to produce a more nuanced decomposition than the heuristic approach.
 * The LLM can understand context, infer implicit tasks, estimate
 * complexity more accurately, and identify non-obvious dependencies.
 */
export async function decomposePrdWithLlm(
  _prdContent: string,
  _model?: string,
): Promise<DecompositionPlan> {
  throw new Error(
    "LLM decomposition not yet implemented. Use heuristic mode.",
  );
}
