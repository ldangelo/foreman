export function isIgnorableControllerPath(path: string): boolean {
  return path === ".tasks/issues.jsonl"
    || path === ".tasks/last-touched"
    || path.startsWith(".omx/")
    || path.startsWith(".foreman/")
    || path.startsWith("SessionLogs/")
    || path === "SESSION_LOG.md"
    || path === "RUN_LOG.md"
    || path.startsWith("storage.");
}
