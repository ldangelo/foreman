export declare function registerDirectDaemonProcess(options?: {
    pidPath?: string;
    socketPath?: string;
    pid?: number;
}): (() => void) | null;
export declare class ForemanDaemon {
    #private;
    private readonly fastify;
    private _running;
    private _socketPath;
    private _httpPort;
    private _useSocket;
    private _dispatchInterval;
    private _githubPoller;
    private _jiraPoller;
    private jiraClient;
    constructor(options?: {
        socketPath?: string;
        httpPort?: number;
    });
    get socketPath(): string;
    get httpPort(): number;
    get running(): boolean;
    /** Start the daemon. Validates Postgres, then listens on socket or HTTP. */
    start(): Promise<void>;
    /** Stop the daemon and release all resources. */
    stop(): Promise<void>;
}
//# sourceMappingURL=index.d.ts.map