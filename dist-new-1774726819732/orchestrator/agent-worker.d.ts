#!/usr/bin/env node
/**
 * Agent Worker — standalone process that runs a single SDK agent.
 *
 * Spawned as a detached child process by the dispatcher. Survives parent exit.
 * Reads config from a JSON file passed as argv[2], runs the SDK query(),
 * and updates the SQLite store with progress/completion.
 *
 * Usage: tsx agent-worker.ts <config-file>
 */
export {};
//# sourceMappingURL=agent-worker.d.ts.map