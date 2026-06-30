interface SeedTaskOptions {
    title: string;
    type?: string;
    priority?: number;
    scenario?: Record<string, unknown>;
    approved?: boolean;
}
export interface TempProjectHarness {
    projectPath: string;
    cleanup(): void;
    seedTask(opts: SeedTaskOptions): Promise<string>;
    addDependency(blockedTaskId: string, blockerTaskId: string): Promise<void>;
    getTaskStatus(taskId: string): Promise<string | null>;
    getRunStatuses(): Promise<string[]>;
    waitForRunCount(count: number, timeoutMs?: number): Promise<void>;
    waitForTerminalRuns(count: number, timeoutMs?: number): Promise<void>;
    drainMergeQueue(): Promise<void>;
    readRepoFile(relativePath: string): string;
}
export declare function createTempProjectHarness(): Promise<TempProjectHarness>;
export {};
//# sourceMappingURL=temp-project-harness.d.ts.map