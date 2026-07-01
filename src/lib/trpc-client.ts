/**
 * Removed legacy tRPC client shim.
 *
 * The Node daemon/tRPC backend was removed after the Elixir cutover. This file
 * remains temporarily so residual unreachable compatibility branches fail closed
 * until their callers are deleted.
 */

export type AppRouter = never;
export type TrpcClient = any;

export interface TrpcClientOptions {
  socketPath?: string;
  httpUrl?: string;
  timeoutMs?: number;
}

export function createTrpcClient(_options: TrpcClientOptions = {}): TrpcClient {
  throw new Error(
    "The legacy Node daemon tRPC API was removed after the Elixir backend cutover. Use an Elixir-routed command.",
  );
}
