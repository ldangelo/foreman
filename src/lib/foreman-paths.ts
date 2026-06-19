import { homedir } from "node:os";
import { join } from "node:path";

const FOREMAN_HOME_ENV = "FOREMAN_HOME";

/**
 * Resolve Foreman's global home directory.
 *
 * Defaults to ~/.foreman and can be overridden in tests via FOREMAN_HOME.
 */
export function getForemanHomeDir(): string {
  const override = process.env[FOREMAN_HOME_ENV]?.trim();
  if (override) {
    return override;
  }
  return join(homedir(), ".foreman");
}

export function getForemanHomePath(...segments: string[]): string {
  return join(getForemanHomeDir(), ...segments);
}
