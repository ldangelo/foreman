export type CodeRabbitCliSeverity = "critical" | "major" | "minor" | "trivial" | "info";
export type CodeRabbitCliStatus = "passed" | "failed" | "skipped";
export interface CodeRabbitCliFinding {
    severity: CodeRabbitCliSeverity;
    fileName: string;
    comment?: string;
    codegenInstructions?: string;
    suggestions: string[];
}
export interface CodeRabbitCliResult {
    status: CodeRabbitCliStatus;
    baseBranch: string;
    command: string;
    blockingFindings: CodeRabbitCliFinding[];
    nonBlockingFindings: CodeRabbitCliFinding[];
    ignoredFindings?: CodeRabbitCliFinding[];
    details: string;
    rawEventsPath: string;
    findingsPath: string;
    reportPath: string;
    stderr?: string;
    malformedLines: string[];
}
export declare function runCodeRabbitCliReview(args: {
    worktreePath: string;
    baseBranch: string;
    reportDir: string;
    log: (msg: string) => void;
    /** Number of CodeRabbit review retries for transient rate limits. Defaults to 3. */
    rateLimitRetries?: number;
    /** Backoff delays between rate-limit retries. Defaults to 30s, 60s, 120s. */
    rateLimitRetryDelaysMs?: number[];
}): Promise<CodeRabbitCliResult>;
//# sourceMappingURL=coderabbit-cli-review.d.ts.map