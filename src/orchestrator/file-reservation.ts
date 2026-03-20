/**
 * File reservation helpers for the Agent Mail integration.
 *
 * TRD-021: File Reservation Integration
 *
 * Extracted into a separate module so that unit tests can import
 * parseFilesFromExplorerReport without triggering the top-level main()
 * call in agent-worker.ts.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Parse file paths mentioned in EXPLORER_REPORT.md.
 * Looks for lines containing paths that start with "src/" or match
 * *.ts/*.js/*.tsx/*.jsx/*.mts/*.mjs patterns, optionally wrapped in
 * backticks or listed with a dash prefix.
 * Returns a deduplicated list of relative file paths.
 * Returns [] if the report does not exist or has no file paths.
 */
export function parseFilesFromExplorerReport(worktreePath: string): string[] {
  const reportPath = join(worktreePath, "EXPLORER_REPORT.md");
  let content: string;
  try {
    content = readFileSync(reportPath, "utf-8");
  } catch {
    return [];
  }

  const seen = new Set<string>();
  const results: string[] = [];

  // Match file paths:
  //   - Lines like "- src/foo.ts" or "- `src/foo.ts`"
  //   - Any path segment that starts with src/ or ends in .ts/.js/.tsx/.jsx
  const pathPattern = /(?:^|\s|`|"|')((src\/[^\s`"')\]>]+|[^\s`"')\]>]+\.(?:ts|tsx|js|jsx|mts|mjs)))/gm;

  let match: RegExpExecArray | null;
  while ((match = pathPattern.exec(content)) !== null) {
    const candidate = match[1].replace(/[`"'.,;:)}\]]+$/, ""); // strip trailing punctuation
    if (candidate && !seen.has(candidate)) {
      seen.add(candidate);
      results.push(candidate);
    }
  }

  return results;
}
