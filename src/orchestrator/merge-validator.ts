import { execFile } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import type { MergeQueueConfig } from "./merge-config.js";

// Error code constants
export const MQ_002 = "MQ-002";
export const MQ_003 = "MQ-003";
export const MQ_004 = "MQ-004";
export const MQ_005 = "MQ-005";

export interface ValidationResult {
  valid: boolean;
  errorCode?: string;
  reason?: string;
}

/** Comment-line prefixes, keyed by file extension. */
const COMMENT_PREFIXES: Record<string, string[]> = {
  ".ts": ["//", "/*", "*"],
  ".js": ["//", "/*", "*"],
  ".tsx": ["//", "/*", "*"],
  ".jsx": ["//", "/*", "*"],
  ".py": ["#"],
  ".go": ["//", "/*", "*"],
  ".rs": ["//", "/*", "*"],
  ".rb": ["#"],
  ".sh": ["#"],
};

/**
 * Validates AI-resolved file content for common problems:
 * prose responses, syntax errors, residual conflict markers,
 * and markdown code-fence wrapping.
 */
export class MergeValidator {
  constructor(private config: MergeQueueConfig) {}

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
  proseDetection(content: string, fileExtension: string): boolean {
    if (content.length === 0) {
      return false;
    }

    const patterns = this.config.proseDetection[fileExtension];
    if (!patterns || patterns.length === 0) {
      return false;
    }

    const commentPrefixes = COMMENT_PREFIXES[fileExtension] ?? ["//", "#"];
    const lines = content.split("\n");

    let firstMeaningfulLine: string | undefined;
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed === "") {
        continue;
      }
      // Skip comment lines
      const isComment = commentPrefixes.some((prefix) =>
        trimmed.startsWith(prefix),
      );
      if (isComment) {
        continue;
      }
      firstMeaningfulLine = trimmed;
      break;
    }

    // If no meaningful line found (all comments/blanks), treat as prose
    if (firstMeaningfulLine === undefined) {
      return true;
    }

    // Check if the first meaningful line matches any code pattern
    for (const pattern of patterns) {
      const regex = new RegExp(pattern);
      if (regex.test(firstMeaningfulLine)) {
        return false; // Matches code pattern -> not prose
      }
    }

    return true; // No code pattern matched -> prose
  }

  /**
   * Runs a syntax checker command on the given content.
   *
   * - Looks up checker from config.syntaxCheckers by file extension
   * - If no checker mapped: returns { pass: true }
   * - Writes content to temp file, runs checker, returns pass/fail
   * - Timeout: 15 seconds
   */
  async syntaxCheck(
    filePath: string,
    content: string,
  ): Promise<{ pass: boolean; error?: string }> {
    const ext = path.extname(filePath);
    const checker = this.config.syntaxCheckers[ext];
    if (!checker) {
      return { pass: true };
    }

    const tmpDir = fs.mkdtempSync(
      path.join(os.tmpdir(), "foreman-syntax-check-"),
    );
    const tmpFile = path.join(tmpDir, `check${ext}`);

    try {
      fs.writeFileSync(tmpFile, content, "utf-8");

      const parts = checker.split(/\s+/);
      const cmd = parts[0];
      const args = [...parts.slice(1), tmpFile];

      return await new Promise<{ pass: boolean; error?: string }>((resolve) => {
        const child = execFile(
          cmd,
          args,
          { timeout: 15_000 },
          (error, _stdout, stderr) => {
            if (error) {
              resolve({
                pass: false,
                error: stderr || error.message,
              });
            } else {
              resolve({ pass: true });
            }
          },
        );

        // Handle the case where the child process doesn't even exist
        child.on("error", (err) => {
          resolve({ pass: false, error: err.message });
        });
      });
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  }

  /**
   * Returns true if content contains residual conflict markers.
   */
  conflictMarkerCheck(content: string): boolean {
    return /^<{7}|^={7}|^>{7}/m.test(content);
  }

  /**
   * Returns true if content is wrapped in triple-backtick fencing
   * (entire content is inside a code block).
   */
  markdownFencingCheck(content: string): boolean {
    const lines = content.split("\n");

    // Find first non-empty line
    let firstIdx = -1;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].trim() !== "") {
        firstIdx = i;
        break;
      }
    }

    // Find last non-empty line
    let lastIdx = -1;
    for (let i = lines.length - 1; i >= 0; i--) {
      if (lines[i].trim() !== "") {
        lastIdx = i;
        break;
      }
    }

    if (firstIdx === -1 || lastIdx === -1 || firstIdx === lastIdx) {
      return false;
    }

    const firstLine = lines[firstIdx].trim();
    const lastLine = lines[lastIdx].trim();

    return firstLine.startsWith("```") && lastLine === "```";
  }

  /**
   * Run the full validation pipeline on resolved content.
   * Checks in order: conflict markers, markdown fencing, prose detection, syntax.
   * Returns { valid: true } or { valid: false, errorCode, reason }.
   */
  async validate(
    filePath: string,
    content: string,
    fileExtension: string,
  ): Promise<ValidationResult> {
    // 1. Conflict markers
    if (this.conflictMarkerCheck(content)) {
      return {
        valid: false,
        errorCode: MQ_004,
        reason: "Content contains residual conflict markers",
      };
    }

    // 2. Markdown fencing
    if (this.markdownFencingCheck(content)) {
      return {
        valid: false,
        errorCode: MQ_005,
        reason: "Content is wrapped in markdown code fencing",
      };
    }

    // 3. Prose detection
    if (this.proseDetection(content, fileExtension)) {
      return {
        valid: false,
        errorCode: MQ_003,
        reason: "Content appears to be prose/explanation rather than code",
      };
    }

    // 4. Syntax check
    const syntaxResult = await this.syntaxCheck(filePath, content);
    if (!syntaxResult.pass) {
      return {
        valid: false,
        errorCode: MQ_002,
        reason: `Syntax check failed: ${syntaxResult.error ?? "unknown error"}`,
      };
    }

    return { valid: true };
  }
}
