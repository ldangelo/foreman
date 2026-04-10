const CONTROLLER_STATE_PATH = ".beads/issues.jsonl";

export const CONTROLLER_TRACKED_STATE_PATHS = [CONTROLLER_STATE_PATH] as const;

export function isIgnorableControllerPath(path: string): boolean {
  return path === CONTROLLER_STATE_PATH
    || path.startsWith(".omx/")
    || path.startsWith(".foreman/")
    || path.startsWith("SessionLogs/")
    || path === "SESSION_LOG.md"
    || path === "RUN_LOG.md"
    || path.startsWith("storage.sqlite3");
}
