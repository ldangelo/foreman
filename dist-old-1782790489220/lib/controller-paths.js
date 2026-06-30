export function isIgnorableControllerPath(path) {
    return path === ".beads/issues.jsonl"
        || path === ".beads/last-touched"
        || path.startsWith(".omx/")
        || path.startsWith(".foreman/")
        || path.startsWith("SessionLogs/")
        || path === "SESSION_LOG.md"
        || path === "RUN_LOG.md"
        || path.startsWith("storage.");
}
//# sourceMappingURL=controller-paths.js.map