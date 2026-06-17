export type ForemanBackendMode = "node" | "elixir";

type Env = Record<string, string | undefined>;

const truthy = new Set(["1", "true", "yes", "complete", "completed"]);

export function migrationComplete(env: Env = process.env): boolean {
  return truthy.has((env.FOREMAN_MIGRATION_COMPLETE ?? "").toLowerCase());
}

export function foremanBackendMode(env: Env = process.env): ForemanBackendMode {
  const configured = (env.FOREMAN_BACKEND ?? "").toLowerCase();
  if (configured === "elixir") return "elixir";
  if (configured === "node") return "node";
  return migrationComplete(env) ? "elixir" : "node";
}

export function nodeDaemonAllowed(env: Env = process.env): boolean {
  return foremanBackendMode(env) === "node" && !migrationComplete(env);
}

export function nodeDaemonDisabledMessage(env: Env = process.env): string {
  const mode = foremanBackendMode(env);
  const complete = migrationComplete(env);
  const reason = complete
    ? "FOREMAN_MIGRATION_COMPLETE is set"
    : `FOREMAN_BACKEND=${mode}`;
  return `${reason}; the Node daemon scheduler is disabled. Use 'foreman server start' for the Elixir backend, or set FOREMAN_BACKEND=node only for explicit legacy operation.`;
}
