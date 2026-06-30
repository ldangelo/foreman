export type BlockingSeverity = "critical" | "high" | "medium";
export interface CodeRabbitFinding {
    severity: BlockingSeverity;
    source: "review-comment" | "issue-comment";
    author: string;
    path?: string;
    line?: number;
    body: string;
    url?: string;
}
export interface FailedCheckFinding {
    name: string;
    status?: string;
    conclusion?: string;
    url?: string;
}
export interface PrReviewContext {
    prNumber: number;
    prUrl?: string;
    headSha?: string;
    blockingFindings: CodeRabbitFinding[];
    failedChecks: FailedCheckFinding[];
}
export interface PrWaitSnapshot {
    prNumber: number;
    prUrl?: string;
    headSha?: string;
    mergeable?: string;
    mergeStateStatus?: string;
    checks: GhCheck[];
    codeRabbitComments: number;
    codeRabbitReviews?: number;
}
export interface PrWaitStatus {
    checksTerminal: boolean;
    pendingChecks: string[];
    failedChecks: FailedCheckFinding[];
    codeRabbitSeen: boolean;
    codeRabbitComplete: boolean;
    mergeConflict: boolean;
    mergeConflictReason?: string;
}
export interface PrReadyStability {
    ready: boolean;
    readySince?: number;
    stable: boolean;
}
export interface GhComment {
    user?: {
        login?: string;
    };
    body?: string;
    path?: string;
    line?: number;
    html_url?: string;
}
export interface GhCheck {
    name?: string;
    context?: string;
    status?: string;
    state?: string;
    conclusion?: string;
    detailsUrl?: string;
    details_url?: string;
}
export interface GhReview {
    user?: {
        login?: string;
    };
    author?: {
        login?: string;
    };
    body?: string;
    state?: string;
    submittedAt?: string;
}
export declare function summarizePrWaitStatus(snapshot: PrWaitSnapshot): PrWaitStatus;
export declare function isPrWaitStatusReady(status: PrWaitStatus): boolean;
export declare function updatePrReadyStability(status: PrWaitStatus, readySince: number | undefined, now: number, stabilityMs: number): PrReadyStability;
export declare function parseBlockingSeverity(text: string): BlockingSeverity | undefined;
export declare function parseCodeRabbitFindings(comments: GhComment[], source: CodeRabbitFinding["source"]): CodeRabbitFinding[];
export declare function parseFailedChecks(statusCheckRollup: GhCheck[]): FailedCheckFinding[];
export declare function collectPrReviewContext(projectPath: string, prNumber: number): Promise<PrReviewContext>;
export declare function collectPrWaitSnapshot(projectPath: string, prNumber: number): Promise<PrWaitSnapshot>;
export declare function writePrReviewFindings(worktreePath: string, context: PrReviewContext, reportDir?: string): Promise<void>;
export declare function writePrWaitReport(worktreePath: string, snapshot: PrWaitSnapshot, timedOut: boolean, reportDir?: string): Promise<void>;
export declare function renderPrWaitReport(snapshot: PrWaitSnapshot, timedOut: boolean): string;
export declare function renderPrReviewFindings(context: PrReviewContext): string;
//# sourceMappingURL=pr-review-context.d.ts.map