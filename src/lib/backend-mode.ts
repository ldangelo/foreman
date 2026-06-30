export type ForemanBackendMode = "node" | "elixir";

type Env = Record<string, string | undefined>;

const truthy = new Set(["1", "true", "yes", "complete", "completed"]);

export function migrationComplete(env: Env = process.env): boolean {
  return truthy.has((env.FOREMAN_MIGRATION_COMPLETE ?? "").toLowerCase());
}

export function foremanBackendMode(env: Env = process.env): ForemanBackendMode {
  const configured = (env.FOREMAN_BACKEND ?? "").toLowerCase();
  if (configured === "node") return "node";
  if (configured === "elixir") return "elixir";
  return "elixir";
}

export function nodeDaemonAllowed(_env: Env = process.env): boolean {
  return false;
}

export function nodeDaemonDisabledMessage(_env: Env = process.env): string {
  return "The Node daemon scheduler was removed after the Elixir backend cutover. Use 'foreman server start' for the Elixir backend.";
}
