const truthy = new Set(["1", "true", "yes", "complete", "completed"]);
export function migrationComplete(env = process.env) {
    return truthy.has((env.FOREMAN_MIGRATION_COMPLETE ?? "").toLowerCase());
}
export function foremanBackendMode(env = process.env) {
    const configured = (env.FOREMAN_BACKEND ?? "").toLowerCase();
    if (configured === "node")
        return "node";
    if (configured === "elixir")
        return "elixir";
    return "elixir";
}
export function nodeDaemonAllowed(env = process.env) {
    return foremanBackendMode(env) === "node" && !migrationComplete(env);
}
export function nodeDaemonDisabledMessage(env = process.env) {
    const mode = foremanBackendMode(env);
    const complete = migrationComplete(env);
    const reason = complete
        ? "FOREMAN_MIGRATION_COMPLETE is set"
        : `FOREMAN_BACKEND=${mode}`;
    return `${reason}; the Node daemon scheduler is disabled. Use 'foreman server start' for the Elixir backend, or set FOREMAN_BACKEND=node only for explicit legacy operation.`;
}
//# sourceMappingURL=backend-mode.js.map