/**
 * DaemonManager — manages ForemanDaemon lifecycle as a child process.
 *
 * Responsibilities:
 * - Spawn ForemanDaemon as a detached child process on `start()`
 * - Write PID to ~/.foreman/daemon.pid
 * - Detect already-running daemon (check PID + socket existence)
 * - Stop daemon on `stop()` (kill PID, clean up socket)
 * - Clean up stale socket on crash (detect stale socket before starting)
 * - Report status (running/not running/error)
 *
 * @module daemon-manager
 */
export declare class DaemonAlreadyRunningError extends Error {
    readonly pid: number;
    readonly code = "DAEMON_ALREADY_RUNNING";
    constructor(pid: number);
}
export declare class DaemonNotRunningError extends Error {
    readonly code = "DAEMON_NOT_RUNNING";
    constructor();
}
export declare class DaemonStartError extends Error {
    readonly code = "DAEMON_START_ERROR";
    constructor(cause: unknown);
}
export interface DaemonStatus {
    running: boolean;
    pid: number | null;
    socketPath: string;
}
export declare class DaemonManager {
    #private;
    private childProcess;
    constructor(options?: {
        socketPath?: string;
        pidPath?: string;
        stdoutPath?: string;
        stderrPath?: string;
    });
    /** Path to the PID file. */
    get pidPath(): string;
    private readonly __pidPath;
    /** Path to the Unix socket (alias for socketPath getter). */
    get socketPath(): string;
    private readonly __socketPath;
    /** Path to the daemon stdout log. */
    get stdoutPath(): string;
    private readonly __stdoutPath;
    /** Path to the daemon stderr log. */
    get stderrPath(): string;
    private readonly __stderrPath;
    /** Check if a daemon is currently running (PID exists + socket exists). */
    isRunning(): boolean;
    /** Get daemon status. */
    status(): DaemonStatus;
    /** Start the daemon as a detached child process.
     *
     * @throws DaemonAlreadyRunningError if a daemon is already running.
     * @throws DaemonStartError if the child process fails to spawn.
     */
    start(): void;
    /** Stop the daemon (kill PID + remove socket).
     *
     * @throws DaemonNotRunningError if no daemon is running.
     */
    stop(): void;
}
//# sourceMappingURL=daemon-manager.d.ts.map