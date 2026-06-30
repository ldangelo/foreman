import type { PhaseTrace, PhaseTraceWriteResult } from "./pi-observability-types.js";
export declare function getPhaseTracePaths(worktreePath: string, seedId: string, phase: string, runId?: string): PhaseTraceWriteResult;
export declare function writePhaseTrace(trace: PhaseTrace): Promise<PhaseTraceWriteResult>;
//# sourceMappingURL=pi-observability-writer.d.ts.map