export type ElixirServerStatus = {
    running: boolean;
    pid?: number;
    url: string;
    pidPath: string;
};
export declare class ElixirServerManager {
    readonly url: string;
    readonly port: number;
    readonly pidPath: string;
    readonly packagePath: string;
    readonly authToken?: string;
    constructor(opts?: {
        port?: number;
        pidPath?: string;
        packagePath?: string;
        authToken?: string;
    });
    status(): ElixirServerStatus;
    health(): Promise<{
        ok: boolean;
        body?: unknown;
        error?: string;
    }>;
    doctor(): Promise<{
        ok: boolean;
        body?: unknown;
        error?: string;
    }>;
    metrics(): Promise<{
        ok: boolean;
        body?: unknown;
        error?: string;
    }>;
    private getJson;
    ensureRunning(): Promise<ElixirServerStatus>;
    start(): void;
    stop(): void;
    private readPid;
    private authHeaders;
}
//# sourceMappingURL=elixir-server-manager.d.ts.map