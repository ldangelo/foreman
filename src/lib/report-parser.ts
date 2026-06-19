/**
 * QA Report Parser — extracts structured failure items from QA_REPORT.md markdown.
 *
 * Expected format from QA agents:
 * ### Category
 * **File:** <file path>
 * **Command:** <command that failed>
 * **Failure Output:** <output from the failure>
 * **Requested Fix:** <description of what Developer should fix>
 */

export interface QAFailureItem {
  category: string;
  file?: string;
  command?: string;
  failureOutput?: string;
  requestedFix?: string;
}

export interface ParsedQAReport {
  verdict: "pass" | "fail" | "unknown";
  items: QAFailureItem[];
  rawContent: string;
}

/**
 * Parse a QA_REPORT.md markdown string into structured failure items.
 * Also extracts the verdict (PASS/FAIL) from the report.
 */
export function parseQAFailures(content: string): ParsedQAReport {
  const items: QAFailureItem[] = [];

  // Extract verdict
  const verdictMatch = content.match(/##\s*Verdict:\s*(PASS|FAIL)/i);
  const verdict = verdictMatch
    ? (verdictMatch[1].toLowerCase() as "pass" | "fail")
    : "unknown";

  // Parse each failure item block
  // Pattern: ### Category\n**File:** ...\n**Command:** ...\n**Failure Output:** ...\n**Requested Fix:** ...
  // Note: Field order is required (File, Command, Failure Output, Requested Fix)
  const itemPattern = /###\s*([^\n]+)\n(?:\*\*File:\*\*\s*([^\n]+)\n)?(?:\*\*Command:\*\*\s*([^\n]+)\n)?(?:\*\*Failure Output:\*\*\s*([\s\S]*?)(?=\n###|\n\*\*Requested Fix:|$))?(?:\*\*Requested Fix:\*\*\s*([\s\S]*?)(?=\n###|$))?/gi;

  let match;
  while ((match = itemPattern.exec(content)) !== null) {
    const [, category, file, command, failureOutput, requestedFix] = match;

    // Clean up extracted values
    const cleanCategory = category.trim();
    const cleanFile = file?.trim();
    const cleanCommand = command?.trim();
    const cleanFailureOutput = failureOutput?.trim().replace(/\n{3,}/g, "\n\n");
    const cleanRequestedFix = requestedFix?.trim().replace(/\n{3,}/g, "\n\n");

    // Only add items that have meaningful content (at least a category)
    if (cleanCategory && cleanCategory.toLowerCase() !== "pass" && cleanCategory.toLowerCase() !== "fail") {
      items.push({
        category: cleanCategory,
        file: cleanFile || undefined,
        command: cleanCommand || undefined,
        failureOutput: cleanFailureOutput || undefined,
        requestedFix: cleanRequestedFix || undefined,
      });
    }
  }

  return {
    verdict,
    items,
    rawContent: content,
  };
}

/**
 * Generate a structured checklist string for injecting into Developer prompts.
 * Format: - [ ] [category] file: <brief description>
 */
export function formatFailureChecklist(items: QAFailureItem[]): string {
  if (!items.length) return "";

  const lines = items.map((item) => {
    const filePart = item.file ? ` \`${item.file}\`: ` : ": ";
    const summary = item.failureOutput
      ? item.failureOutput.split("\n")[0].slice(0, 100)
      : item.requestedFix?.split("\n")[0].slice(0, 100) ?? "See details below";
    return `- [ ] **${item.category}**${filePart}${summary}${item.requestedFix ? ` [Requested fix: ${item.requestedFix.slice(0, 150)}]` : ""}`;
  });

  return `\n## Structured QA Failure Checklist\n\n${lines.join("\n")}\n`;
}

/**
 * Diff previous and current QA failure items to track resolution state.
 * Returns items with resolution status.
 */
export interface TrackedFailureItem extends QAFailureItem {
  status: "new" | "resolved" | "still_failing" | "blocked";
}

export function diffQAFailures(
  previousItems: QAFailureItem[],
  currentItems: QAFailureItem[]
): TrackedFailureItem[] {
  const tracked: TrackedFailureItem[] = [];

  // Build a map from currentItems for O(1) lookup and to capture fresh data
  const currentMap = new Map<string, QAFailureItem>();
  for (const curr of currentItems) {
    currentMap.set(itemKey(curr), curr);
  }

  // Mark previous items as resolved or still_failing using fresh data from currentItems
  for (const prev of previousItems) {
    const key = itemKey(prev);
    const currentItem = currentMap.get(key);
    if (currentItem) {
      // Item still failing — use fresh data from currentItems
      tracked.push({
        ...currentItem,
        status: "still_failing",
      });
      currentMap.delete(key); // Remove from map to track what's left as new
    } else {
      // Item resolved — use previous data
      tracked.push({
        ...prev,
        status: "resolved",
      });
    }
  }

  // Remaining items in currentMap are new items
  for (const item of currentMap.values()) {
    tracked.push({
      ...item,
      status: "new",
    });
  }

  return tracked;
}

function itemKey(item: QAFailureItem): string {
  return `${item.category}|${item.file ?? ""}|${item.command ?? ""}`;
}
