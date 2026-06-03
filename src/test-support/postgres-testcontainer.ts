import { execFileSync } from "node:child_process";
import { PostgreSqlContainer, type StartedPostgreSqlContainer } from "@testcontainers/postgresql";
import { destroyPool, initPool } from "../lib/db/pool-manager.js";

let container: StartedPostgreSqlContainer | null = null;
let databaseUrl: string | null = null;

export async function startPostgresTestcontainer(): Promise<string> {
  if (databaseUrl) return databaseUrl;

  container = await new PostgreSqlContainer("postgres:16-alpine")
    .withDatabase("foreman_test")
    .withUsername("postgres")
    .withPassword("postgres")
    .start();

  databaseUrl = container.getConnectionUri();
  execFileSync("npm", ["run", "db:migrate"], {
    cwd: process.cwd(),
    env: { ...process.env, DATABASE_URL: databaseUrl },
    stdio: "ignore",
  });

  await destroyPool();
  initPool({ databaseUrl });
  return databaseUrl;
}

export async function stopPostgresTestcontainer(): Promise<void> {
  await destroyPool();
  await container?.stop();
  container = null;
  databaseUrl = null;
}

export async function resetPostgresTestcontainer(): Promise<void> {
  await destroyPool();
  if (databaseUrl) initPool({ databaseUrl });
}
