import type { PiRunOptions, PiRunResult } from "./pi-sdk-runner.js";
import { runWithPiSdk } from "./pi-sdk-runner.js";

export interface PhaseRunnerContext {
  phaseName: string;
  seedId: string;
  seedTitle: string;
  seedType?: string;
  seedDescription?: string;
  worktreePath: string;
  targetBranch?: string;
}

export interface PhaseRunnerOptions extends PiRunOptions {
  context: PhaseRunnerContext;
}

export type ConfiguredPhaseRunner = (opts: PhaseRunnerOptions) => Promise<PiRunResult>;

function getRuntimeMode(): string {
  return process.env.FOREMAN_RUNTIME_MODE?.trim().toLowerCase() || "normal";
}

async function loadConfiguredRunner(): Promise<ConfiguredPhaseRunner> {
  const runtimeMode = getRuntimeMode();
  if (runtimeMode !== "test") {
    return (opts) => runWithPiSdk(opts);
  }

  const modulePath = process.env.FOREMAN_PHASE_RUNNER_MODULE;
  if (!modulePath) {
    throw new Error(
      "FOREMAN_RUNTIME_MODE=test requires FOREMAN_PHASE_RUNNER_MODULE to be set",
    );
  }

  const exportName = process.env.FOREMAN_PHASE_RUNNER_EXPORT || "runDeterministicPhase";
  const loaded = await import(modulePath);
  const runner = loaded[exportName] as ConfiguredPhaseRunner | undefined;
  if (typeof runner !== "function") {
    throw new Error(
      `Configured phase runner export '${exportName}' was not found in ${modulePath}`,
    );
  }
  return runner;
}

export async function runPhaseSession(opts: PhaseRunnerOptions): Promise<PiRunResult> {
  const runner = await loadConfiguredRunner();
  return runner(opts);
}
