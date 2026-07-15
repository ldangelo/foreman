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
      paths.add(candidate.replace(/^\.\//, ""));
    }
  }
  return paths;
}

export function reportJustifiesOutOfScope(report: string, file: string): boolean {
  const lower = report.toLowerCase();
  return lower.includes(file.toLowerCase()) && /\b(out-of-scope|outside scope|deviat|additional file|broadened|changed because)\b/i.test(report);
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
