import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { resolveArtifactPath } from "../lib/report-paths.js";

export interface FinalizeGuardConfig {
  worktreePath: string;
  reportDir: string;
}

export function readFinalizeReportFile(config: FinalizeGuardConfig, fileName: string): string {
  const path = resolveArtifactPath(config.worktreePath, join(config.reportDir, fileName));
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

export function extractExplorerScopedPaths(report: string): Set<string> {
  const paths = new Set<string>();
  const match = report.match(/#{2,4}\s*Edit First\b([\s\S]*?)(?=\n#{2,4}\s|\n##\s|$)/i);
  if (!match) return paths;
  for (const line of match[1].split(/\r?\n/)) {
    const candidates = [
      ...line.matchAll(/`([^`]+\.[A-Za-z0-9]+)`/g),
      ...line.matchAll(/\*\*([^*]+\.[A-Za-z0-9]+)\*\*/g),
    ].map((candidate) => candidate[1].trim());
    for (const candidate of candidates) {
      if (!candidate || candidate.includes(" ")) continue;
      paths.add(candidate.replace(/^\.\//, "").replace(/:\d+(?:-\d+)?$/, ""));
    }
  }
  return paths;
}

// Placeholder values that do not constitute a real justification. These are
// accepted as "non-justification" so a developer cannot blow through the guard
// by appending TODO/blank entries. Case-insensitive; matched against the
// trimmed justification text. Keep this list narrow and grounded in observed
// stubs (TODO/TBD/NONE/blank/punctuation) rather than a long word list.
const SYMBOL_ONLY_JUSTIFICATION = /^(?!.*[\p{L}\p{N}]).+$/u;
const LEADING_PLACEHOLDER = /^\s*(TODO|TBD|TBA|N\/A|NA|NONE)\b/i;
// PLACEHOLDER as a stub must be followed by punctuation (comma/colon/semicolon/period)
// so the literal English word in legitimate justifications is not matched.
const PLACEHOLDER_STUB = /^\s*PLACEHOLDER\s*[,;:.]/i;
// Minimum substantive length for a real justification. Anything shorter than
// ~12 characters is almost certainly a stub or accidental acceptance. We do
// not enforce a specific keyword vocabulary because the developer prompt
// (developer.md:116-119) accepts a wide range of legitimate phrasings
// ("per AGENTS documentation discipline", "config/test coupling", etc.).
const MIN_JUSTIFICATION_LENGTH = 12;

// Parse the developer's ## Scope Expansions section as a structured per-file
// map of (file path) -> (justification text). Returns an empty map if the
// section is missing. Each bullet line is expected to be of the form:
//
//   - `path/to/file` — justification text here
//   - `path/to/file`: justification text here
//   - path/to/file — justification text here
//
// File paths may contain hyphens (e.g. heartbeat-manager.ts,
// finalize-guards.ts). We split on the separator character rather than
// matching the path regex, so hyphens in file names are preserved.
function parseScopeExpansions(report: string): Map<string, string> {
  const result = new Map<string, string>();
  const sectionMatch = report.match(/##\s*Scope Expansions\b([\s\S]*?)(?=\n##\s|$)/i);
  if (!sectionMatch) return result;

  for (const rawLine of sectionMatch[1].split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line.startsWith('-') && !line.startsWith('*')) continue;
    const body = line.replace(/^[-*]\s+/, '');

    // Try em-dash separator first, then " - " (double-hyphen, which renders as
    // em-dash in some editors), then colon. Each must have content on both
    // sides.
    let file = '';
    let justification = '';
    const emDashMatch = body.match(/^`?([^`]+?)`?\s+(?:\u2014|--)\s+(.+)$/);
    const colonMatch = body.match(/^`?([^`]+?)`?\s*:\s+(.+)$/);
    if (emDashMatch) {
      file = emDashMatch[1].trim();
      justification = emDashMatch[2].trim();
    } else if (colonMatch) {
      file = colonMatch[1].trim();
      justification = colonMatch[2].trim();
    } else {
      continue;
    }
    // Strip any remaining surrounding backticks from the file path.
    file = file.replace(/^`+|`+$/g, '').trim();
    if (file) result.set(file, justification);
  }
  return result;
}

function isValidJustification(text: string): boolean {
  const trimmed = text.trim();
  if (trimmed.length === 0) return false;
  if (SYMBOL_ONLY_JUSTIFICATION.test(trimmed)) return false;
  if (LEADING_PLACEHOLDER.test(trimmed)) return false;
  if (PLACEHOLDER_STUB.test(trimmed)) return false;
  if (trimmed.length < MIN_JUSTIFICATION_LENGTH) return false;
  return true;
}

export function reportJustifiesOutOfScope(report: string, file: string): boolean {
  // The developer contract (developer.md:116-119) requires each out-of-scope
  // file to have a structured entry under ## Scope Expansions with a real
  // justification. Parse the section strictly and require a substantive,
  // non-placeholder justification for the specific file. No keyword fallback
  // across the rest of the report — a file mentioned in any other section
  // (Decisions & Trade-offs, CI Findings Addressed, etc.) does NOT count as
  // justified, because the contract is the section.
  const expansions = parseScopeExpansions(report);
  const justification = expansions.get(file);
  if (justification === undefined) return false;
  return isValidJustification(justification);
}

export function findFinalizeScopeViolations(config: FinalizeGuardConfig, changedFiles: string[]): string[] {
  const explorerReport = readFinalizeReportFile(config, "EXPLORER_REPORT.md");
  const developerReport = readFinalizeReportFile(config, "DEVELOPER_REPORT.md");
  const allowedPaths = extractExplorerScopedPaths(explorerReport);
  if (allowedPaths.size === 0) return [];

  return changedFiles.filter((file) => {
    const normalized = file.replace(/^\.\//, "");
    if (allowedPaths.has(normalized)) return false;
    if (normalized.startsWith(config.reportDir)) return false;
    if (reportJustifiesOutOfScope(developerReport, normalized)) return false;
    return true;
  });
}

export function finalizeValidationCommands(changedFiles: string[]): string[] {
  const commands = new Set<string>();
  if (changedFiles.some((file) => file.startsWith("packages/foreman_server/") && /\.(ex|exs)$/.test(file))) {
    commands.add("cd packages/foreman_server && mix test");
  }
  if (changedFiles.some((file) => file.startsWith("clients/cockpit/") && /\.go$/.test(file))) {
    commands.add("cd clients/cockpit && go test ./...");
  }
  if (changedFiles.some((file) => file.startsWith("src/defaults/workflows/") || file.startsWith("src/defaults/prompts/"))) {
    commands.add("npx vitest run src/orchestrator/__tests__/workflow-loader.test.ts src/orchestrator/__tests__/workflow-remediation-routing.test.ts --reporter=dot");
  }
  return [...commands];
}

/**
 * Classify a finalize test failure as MODIFIED_FILES, UNRELATED_FILES, or UNKNOWN
 * by extracting failing test file paths from the raw test output and matching them
 * against the files changed between origin/<baseBranch> and HEAD.
 */
export type FinalizeFailureClassification = "MODIFIED_FILES" | "UNRELATED_FILES" | "UNKNOWN";

export function classifyFinalizeTestFailure(testOutput: string, changedFiles: string[]): FinalizeFailureClassification {
  if (!changedFiles.length) return "UNKNOWN";

  const failingPaths = extractFailingTestPaths(testOutput);
  if (failingPaths.size === 0) return "UNKNOWN";

  const normalize = (file: string) => file.replace(/^\.\//, "").replace(/\\/g, "/");
  const changed = new Set(changedFiles.map(normalize));
  const changedDirectories = new Set<string>();
  const strippedExtensions = new Set<string>();
  for (const path of changed) {
    const dir = path.replace(/[/\\][^/\\]+$/, "");
    if (dir !== path) changedDirectories.add(dir);
    strippedExtensions.add(path.replace(/\.[^.]+$/, ""));
    // __tests__/foo.test.ts -> src/foo.ts (test-companion map)
    const jsTestMatch = path.match(/__tests__\/(.+?)\.test\.(?:tsx?|jsx?|mjs|cjs)$/);
    if (jsTestMatch) {
      changed.add(`src/${jsTestMatch[1]}.ts`);
      changed.add(`src/${jsTestMatch[1]}.tsx`);
    }
  }

  let modifiedHits = 0;
  let unrelatedHits = 0;
  for (const failingPath of failingPaths) {
    const normalized = normalize(failingPath);
    const matchesChanged = changed.has(normalized)
      || [...changedDirectories].some((dir) => normalized.startsWith(dir + "/"))
      || strippedExtensions.has(normalized);
    if (matchesChanged) {
      modifiedHits++;
    } else {
      unrelatedHits++;
    }
  }

  if (modifiedHits > 0 && unrelatedHits === 0) return "MODIFIED_FILES";
  if (unrelatedHits > 0 && modifiedHits === 0) return "UNRELATED_FILES";
  return "UNKNOWN";
}

/**
 * Parse well-known test runner output formats (vitest, jest, mix, go, cargo, pytest, dotnet)
 * and return the set of failing test file paths referenced in the output.
 */
export function extractFailingTestPaths(testOutput: string): Set<string> {
  const paths = new Set<string>();

  // vitest / jest: lines prefixed with "FAIL" / "✗" with a test file path
  const jsFailLine = /^(?:FAIL|✗)\s+(.+?\.(?:test|spec)\.(?:ts|tsx|js|jsx|mjs|cjs))\b/gm;
  for (const match of testOutput.matchAll(jsFailLine)) {
    paths.add(match[1].trim());
  }
  const jsChevLine = /^\s*❯\s+(.+?\.(?:test|spec)\.(?:ts|tsx|js|jsx|mjs|cjs))\s/gm;
  for (const match of testOutput.matchAll(jsChevLine)) {
    paths.add(match[1].trim());
  }
  // Stack trace references to a test file
  const jsStack = /^[\s]*at\s+.+?\s+\(?(.+?\.(?:test|spec)\.(?:ts|tsx|js|jsx|mjs|cjs)):\d+:\d+\)?/gm;
  for (const match of testOutput.matchAll(jsStack)) {
    paths.add(match[1].trim());
  }

  // Elixir mix: "** (ExUnit.AssertionError) ... ** test/path/file_test.exs:12"
  const exUnitPath = /\*\*\s+(test\/.+\.exs?)/g;
  for (const match of testOutput.matchAll(exUnitPath)) {
    paths.add(match[1]);
  }
  const mixFile = /(^|\s)(test\/[^\s]+\.exs?):\d+/gm;
  for (const match of testOutput.matchAll(mixFile)) {
    paths.add(match[2]);
  }

  // Go: "FAIL    github.com/foo/bar/path 0.123s" — package path → directory
  const goFail = /^FAIL\s+(github\.com\/[^\s]+)\s+[\d.]+s/gm;
  for (const match of testOutput.matchAll(goFail)) {
    const trimmed = match[1].replace(/^github\.com\/[^/]+\/?/, "");
    paths.add(trimmed || ".");
  }
  const goFile = /(?:^|\s+)\/([^\s]+\.go):\d+/gm;
  for (const match of testOutput.matchAll(goFile)) {
    paths.add(match[1]);
  }

  // Cargo: file+line refs in stack traces "src/foo.rs:12"
  const cargoFile = /(^|\s)(src\/[^\s]+\.rs):\d+/gm;
  for (const match of testOutput.matchAll(cargoFile)) {
    paths.add(match[2]);
  }

  // Pytest: "FAILED path/to/test_file.py::test_name - AssertionError"
  const pytestFail = /^FAILED\s+([^\s:]+\.py)::/gm;
  for (const match of testOutput.matchAll(pytestFail)) {
    paths.add(match[1]);
  }

  // .NET: "file.cs(12,3): error ..."
  const dotnetFail = /^(.+?\.cs)\(\d+,\d+\):\s+error\b/gm;
  for (const match of testOutput.matchAll(dotnetFail)) {
    paths.add(match[1].trim());
  }

  return paths;
}
