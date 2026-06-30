import { mkdir } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { getForemanHomePath } from "./foreman-paths.js";
export function getRunReportsDir(projectId, seedId, runId) {
    return getForemanHomePath("reports", projectId, seedId, runId);
}
export async function ensureRunReportsDir(projectId, seedId, runId) {
    const dir = getRunReportsDir(projectId, seedId, runId);
    await mkdir(dir, { recursive: true });
    return dir;
}
export function resolveArtifactPath(worktreePath, artifactPath) {
    return isAbsolute(artifactPath) ? artifactPath : join(worktreePath, artifactPath);
}
//# sourceMappingURL=report-paths.js.map