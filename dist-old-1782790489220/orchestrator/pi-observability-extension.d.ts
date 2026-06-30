import type { ExtensionFactory } from "@mariozechner/pi-coding-agent";
import type { FinalizePhaseTraceOptions, PhaseTrace, PhaseTraceLiveEvent, PhaseTraceMetadata } from "./pi-observability-types.js";
export declare function getForbiddenVcsAction(command: string | undefined, phase: string): "git commit" | "git push" | undefined;
export declare function createPhaseTrace(metadata: PhaseTraceMetadata): PhaseTrace;
export declare function createPiObservabilityExtension(trace: PhaseTrace): ExtensionFactory;
export declare function createPiObservabilityExtensionWithEmitter(trace: PhaseTrace, emit?: (event: PhaseTraceLiveEvent) => void): ExtensionFactory;
export declare function finalizePhaseTrace(trace: PhaseTrace, options: FinalizePhaseTraceOptions): PhaseTrace;
//# sourceMappingURL=pi-observability-extension.d.ts.map