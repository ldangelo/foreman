import { PostgresAdapter, type ProjectRow } from "../lib/db/postgres-adapter.js";
import { PostgresStore } from "../lib/postgres-store.js";
export declare function startPostgresTestcontainer(): Promise<string>;
export declare function stopPostgresTestcontainer(): Promise<void>;
export declare function resetPostgresTestcontainer(): Promise<void>;
export declare function createPostgresProjectFixture(prefix?: string): Promise<{
    adapter: PostgresAdapter;
    store: PostgresStore;
    project: ProjectRow;
}>;
//# sourceMappingURL=postgres-testcontainer.d.ts.map