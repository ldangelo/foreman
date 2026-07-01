export type ForemanBackendMode = "node" | "elixir";

type Env = Record<string, string | undefined>;

export function migrationComplete(_env: Env = process.env): boolean {
  return true;
}

export function foremanBackendMode(_env: Env = process.env): ForemanBackendMode {
  return "elixir";
}

export function nodeDaemonAllowed(_env: Env = process.env): boolean {
  return false;
}

export function nodeDaemonDisabledMessage(_env: Env = process.env): string {
  return "The Node daemon scheduler was removed after the Elixir backend cutover. Use 'foreman server start' for the Elixir backend.";
}
