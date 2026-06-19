import { mkdir } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { getForemanHomePath } from "./foreman-paths.js";

export function getRunReportsDir(projectId: string, seedId: string, runId: string): string {
  return getForemanHomePath("reports", projectId, seedId, runId);
}

export async function ensureRunReportsDir(projectId: string, seedId: string, runId: string): Promise<string> {
  const dir = getRunReportsDir(projectId, seedId, runId);
  await mkdir(dir, { recursive: true });
  return dir;
}

export function resolveArtifactPath(worktreePath: string, artifactPath: string): string {
  return isAbsolute(artifactPath) ? artifactPath : join(worktreePath, artifactPath);
}
