import type { MergeQueueConfig } from "./merge-config.js";
export declare const MQ_002 = "MQ-002";
export declare const MQ_003 = "MQ-003";
export declare const MQ_004 = "MQ-004";
export declare const MQ_005 = "MQ-005";
export interface ValidationResult {
    valid: boolean;
    errorCode?: string;
    reason?: string;
}
/**
 * Validates AI-resolved file content for common problems:
 * prose responses, syntax errors, residual conflict markers,
 * and markdown code-fence wrapping.
 */
export declare class MergeValidator {
    private config;
    constructor(config: MergeQueueConfig);
    /**
     * Returns true if the content appears to be prose/explanation rather than code.
     *
     * Uses a language-aware first-line heuristic: finds the first non-empty,
     * non-comment line and checks whether it matches any known code pattern
     * for the given file extension.
     *
     * - If a code pattern matches: NOT prose -> return false
     * - If no code pattern matches: IS prose -> return true
     * - For unmapped extensions: return false (accept as code)
     * - For empty content: return false
     */
    proseDetection(content: string, fileExtension: string): boolean;
    /**
     * Runs a syntax checker command on the given content.
     *
     * - Looks up checker from config.syntaxCheckers by file extension
     * - If no checker mapped: returns { pass: true }
     * - Writes content to temp file, runs checker, returns pass/fail
     * - Timeout: 15 seconds
     */
    syntaxCheck(filePath: string, content: string): Promise<{
        pass: boolean;
        error?: string;
    }>;
    /**
     * Returns true if content contains residual conflict markers.
     */
    conflictMarkerCheck(content: string): boolean;
    /**
     * Returns true if content is wrapped in triple-backtick fencing
     * (entire content is inside a code block).
     */
    markdownFencingCheck(content: string): boolean;
    /**
     * Run the full validation pipeline on resolved content.
     * Checks in order: conflict markers, markdown fencing, prose detection, syntax.
     * Returns { valid: true } or { valid: false, errorCode, reason }.
     */
    validate(filePath: string, content: string, fileExtension: string): Promise<ValidationResult>;
}
//# sourceMappingURL=merge-validator.d.ts.map