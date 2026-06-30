import type { PiRunOptions, PiRunResult } from "./pi-sdk-runner.js";
export interface PhaseRunnerContext {
    phaseName: string;
    runId?: string;
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
export declare function runPhaseSession(opts: PhaseRunnerOptions): Promise<PiRunResult>;
//# sourceMappingURL=phase-runner.d.ts.map