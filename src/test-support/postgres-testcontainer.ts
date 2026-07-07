export interface PostgresTestcontainerHandle {
  databaseUrl: string;
  stop(): Promise<void>;
}

export async function startPostgresTestcontainer(): Promise<string> {
  throw new Error("Postgres testcontainer support was removed with the legacy Postgres runtime; use Elixir-backed e2e harnesses instead.");
}

export async function startPostgresTestcontainerHandle(): Promise<PostgresTestcontainerHandle> {
  const databaseUrl = await startPostgresTestcontainer();
  return { databaseUrl, stop: async () => undefined };
}
