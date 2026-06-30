import { Command } from "commander";
interface PhaseEvent {
    timestamp?: string;
    message: string;
}
interface RecentToolEvent {
    kind: "start" | "end";
    tool: string;
    detail?: string;
}
export declare function tailLines(content: string, count: number): string[];
export declare function tailFileLines(path: string, count: number, maxBytes?: number): string[];
export declare function extractPhaseEvents(errContent: string): PhaseEvent[];
export declare function extractRecentToolEvents(logContent: string, limit: number): RecentToolEvent[];
export declare const logsCommand: Command;
export {};
//# sourceMappingURL=logs.d.ts.map