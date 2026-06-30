import { execFileSync } from "node:child_process";
import { PostgreSqlContainer } from "@testcontainers/postgresql";
import { randomUUID } from "node:crypto";
import { destroyPool, initPool } from "../lib/db/pool-manager.js";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import { PostgresStore } from "../lib/postgres-store.js";
let container = null;
let databaseUrl = null;
export async function startPostgresTestcontainer() {
    if (databaseUrl)
        return databaseUrl;
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
export async function stopPostgresTestcontainer() {
    await destroyPool();
    await container?.stop();
    container = null;
    databaseUrl = null;
}
export async function resetPostgresTestcontainer() {
    await destroyPool();
    if (databaseUrl)
        initPool({ databaseUrl });
}
export async function createPostgresProjectFixture(prefix = "pg-test") {
    await startPostgresTestcontainer();
    const adapter = new PostgresAdapter();
    const suffix = randomUUID().slice(0, 8);
    const project = await adapter.createProject({
        name: `${prefix}-${suffix}`,
        path: `/tmp/${prefix}-${suffix}`,
        defaultBranch: "main",
    });
    return {
        adapter,
        store: new PostgresStore(project.id, adapter),
        project,
    };
}
//# sourceMappingURL=postgres-testcontainer.js.map