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
