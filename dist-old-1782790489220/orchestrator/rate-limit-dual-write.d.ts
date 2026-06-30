import type { ForemanStore } from "../lib/store.js";
import type { PostgresStore } from "../lib/postgres-store.js";
export declare function createDualWriteStore(localStore: ForemanStore, pgStore: PostgresStore, preferRegisteredPostgres?: boolean, logFn?: (msg: string) => void): ForemanStore;
//# sourceMappingURL=rate-limit-dual-write.d.ts.map