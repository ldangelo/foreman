export interface MergeQueueConfig {
    tier2SafetyCheck: {
        maxDiscardedLines: number;
        maxDiscardedPercent: number;
    };
    costControls: {
        maxFileLines: number;
        maxSessionBudgetUsd: number;
    };
    syntaxCheckers: Record<string, string>;
    proseDetection: Record<string, string[]>;
    testAfterMerge: "ai-only" | "always" | "never";
}
export declare const DEFAULT_MERGE_CONFIG: MergeQueueConfig;
export declare function loadMergeConfig(projectPath: string): MergeQueueConfig;
//# sourceMappingURL=merge-config.d.ts.map