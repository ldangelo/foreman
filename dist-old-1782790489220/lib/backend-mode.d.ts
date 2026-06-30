export type ForemanBackendMode = "node" | "elixir";
type Env = Record<string, string | undefined>;
export declare function migrationComplete(env?: Env): boolean;
export declare function foremanBackendMode(env?: Env): ForemanBackendMode;
export declare function nodeDaemonAllowed(env?: Env): boolean;
export declare function nodeDaemonDisabledMessage(env?: Env): string;
export {};
//# sourceMappingURL=backend-mode.d.ts.map