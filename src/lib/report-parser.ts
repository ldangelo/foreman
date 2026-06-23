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

export interface AcceptanceCriterion {
  id: string;
  text: string;
}

export interface AcceptanceCoverageResult {
  ok: boolean;
  criteria: AcceptanceCriterion[];
  missing: AcceptanceCriterion[];
  reportHasAcceptanceSection: boolean;
}

export interface AcceptanceCoverageOptions {
  /** Only these criteria must be covered for the current phase. */
  relevant?: (criterion: AcceptanceCriterion) => boolean;
  /** Treat explicit deferred/not-in-scope notes as covered for phase-limited gates. */
  allowDeferred?: boolean;
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

const ACCEPTANCE_SECTION_RE = /(?:^|\n)##\s+Acceptance Contract\b[^\n]*\n([\s\S]*?)(?=\n##\s+|$)/i;
const HAS_ACCEPTANCE_SECTION_RE = /^##\s+Acceptance Contract\b/im;

export function parseAcceptanceContract(content: string): AcceptanceCriterion[] {
  const section = content.match(ACCEPTANCE_SECTION_RE)?.[1] ?? "";
  if (!section.trim()) return [];

  const criteria: AcceptanceCriterion[] = [];
  for (const line of section.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const bullet = trimmed.match(/^(?:[-*]|\d+[.)])\s+(?:\[[ xX]\]\s*)?(.*)$/);
    if (!bullet) continue;
    const text = cleanAcceptanceText(bullet[1]);
    if (!text || /^carry the same acceptance contract/i.test(text)) continue;
    const idMatch = text.match(/^\[?([A-Z]{1,4}-?\d{1,3}|AC\d{1,3}|C\d{1,3})\]?\s*[:—-]\s*(.+)$/i);
    criteria.push({
      id: idMatch?.[1]?.toUpperCase() ?? `AC${criteria.length + 1}`,
      text: idMatch?.[2]?.trim() ?? text,
    });
  }
  return criteria;
}

export function validateAcceptanceCoverage(
  explorerReport: string,
  phaseReport: string,
  options: AcceptanceCoverageOptions = {},
): AcceptanceCoverageResult {
  const criteria = parseAcceptanceContract(explorerReport);
  if (criteria.length === 0) {
    return { ok: true, criteria, missing: [], reportHasAcceptanceSection: true };
  }

  const reportHasAcceptanceSection = HAS_ACCEPTANCE_SECTION_RE.test(phaseReport);
  const normalizedReport = normalizeAcceptanceText(phaseReport);
  const criteriaToCheck = options.relevant ? criteria.filter(options.relevant) : criteria;
  const missing = criteriaToCheck.filter((criterion) => {
    if (criterionCovered(criterion, normalizedReport)) return false;
    return !(options.allowDeferred && criterionDeferred(criterion, phaseReport));
  });
  return {
    ok: reportHasAcceptanceSection && missing.length === 0,
    criteria,
    missing,
    reportHasAcceptanceSection,
  };
}

function criterionDeferred(criterion: AcceptanceCriterion, phaseReport: string): boolean {
  const section = phaseReport.match(ACCEPTANCE_SECTION_RE)?.[1] ?? phaseReport;
  const normalizedId = normalizeAcceptanceText(criterion.id);
  const normalizedCriterion = normalizeAcceptanceText(criterion.text);
  const deferredPattern = /\b(deferred|not\s+in\s+(?:test\s+)?scope|blocked\s+on\s+implementation|requires?\s+developer|developer\s+implementation|not\s+applicable|n\/a)\b/i;
  return section.split(/\r?\n/).some((line) => {
    const normalizedLine = normalizeAcceptanceText(line);
    if (!deferredPattern.test(line)) return false;
    if (normalizedId && normalizedLine.includes(normalizedId)) return true;
    if (normalizedCriterion && normalizedLine.includes(normalizedCriterion)) return true;
    return false;
  });
}

function criterionCovered(criterion: AcceptanceCriterion, normalizedReport: string): boolean {
  if (normalizeAcceptanceText(criterion.id).length >= 2 && normalizedReport.includes(normalizeAcceptanceText(criterion.id))) {
    return true;
  }
  const normalizedCriterion = normalizeAcceptanceText(criterion.text);
  if (normalizedCriterion && normalizedReport.includes(normalizedCriterion)) return true;
  const significantTokens = normalizedCriterion
    .split(" ")
    .filter((token) => token.length >= 4)
    .slice(0, 8);
  return significantTokens.length >= 3 && significantTokens.every((token) => normalizedReport.includes(token));
}

function cleanAcceptanceText(text: string): string {
  return text
    .replace(/^\*\*([^*]+)\*\*\s*[:—-]?\s*/, "$1: ")
    .replace(/`([^`]+)`/g, "$1")
    .trim();
}

function normalizeAcceptanceText(text: string): string {
  return text
    .toLowerCase()
    .replace(/`([^`]+)`/g, "$1")
    .replace(/[^a-z0-9/_.-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function itemKey(item: QAFailureItem): string {
  return `${item.category}|${item.file ?? ""}|${item.command ?? ""}`;
}
