/**
 * dispatcher-lock.ts
 *
 * PID lock file management for `foreman run`.
 *
 * Prevents duplicate dispatcher instances and provides mechanism to detect
 * and handle stale PID files from previously crashed dispatcher processes.
 *
 * Lock file location: <projectPath>/.foreman/foreman.pid
 */

import { readFileSync, writeFileSync, unlinkSync, existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";

export class DispatcherAlreadyRunningError extends Error {
  constructor(public readonly pid: number) {
    super(`foreman run already active (pid ${pid})`);
    this.name = "DispatcherAlreadyRunningError";
  }
}

/**
 * Check if a process is alive by sending signal 0.
 * Returns true if the process exists, false otherwise.
 */
export function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err: unknown) {
    // ESRCH = no such process → dead
    // EPERM = no permission but process exists → alive
    const code = (err as NodeJS.ErrnoException).code;
    return code === "EPERM";
  }
}

/**
 * Get the path to the PID lock file for a project.
 */
export function getLockFilePath(projectPath: string): string {
  return join(projectPath, ".foreman", "foreman.pid");
}

/**
 * Read the PID from the lock file.
 * Returns null if the file doesn't exist or contains invalid data.
 */
export function readLockFile(projectPath: string): number | null {
  const lockPath = getLockFilePath(projectPath);
  if (!existsSync(lockPath)) return null;

  try {
    const content = readFileSync(lockPath, "utf-8").trim();
    const pid = parseInt(content, 10);
    if (isNaN(pid) || pid <= 0) return null;
    return pid;
  } catch {
    return null;
  }
}

/**
 * Write the current process PID to the lock file.
 */
export function writeLockFile(projectPath: string): void {
  const lockPath = getLockFilePath(projectPath);
  mkdirSync(join(projectPath, ".foreman"), { recursive: true });
  writeFileSync(lockPath, String(process.pid), "utf-8");
}

/**
 * Remove the lock file (clean shutdown).
 * Non-fatal — silently ignores errors (e.g. already deleted).
 */
export function removeLockFile(projectPath: string): void {
  const lockPath = getLockFilePath(projectPath);
  try {
    unlinkSync(lockPath);
  } catch {
    // Ignore — file may already be gone
  }
}

export interface AcquireLockOpts {
  /** If true, kill any existing dispatcher and replace it */
  force?: boolean;
}

/**
 * Acquire the dispatcher lock for a project.
 *
 * Behavior:
 * - No lock file: write one and proceed
 * - Stale lock file (process dead): delete it and proceed
 * - Live lock file + force=false: throw DispatcherAlreadyRunningError
 * - Live lock file + force=true: SIGTERM the existing process, wait briefly, then acquire
 *
 * @throws {DispatcherAlreadyRunningError} if a live dispatcher is running and force=false
 */
export async function acquireLock(projectPath: string, opts: AcquireLockOpts = {}): Promise<void> {
  const existingPid = readLockFile(projectPath);

  if (existingPid !== null) {
    if (isProcessAlive(existingPid)) {
      if (!opts.force) {
        throw new DispatcherAlreadyRunningError(existingPid);
      }
      // --force: kill existing dispatcher
      try {
        process.kill(existingPid, "SIGTERM");
        // Wait up to 3 seconds for the process to exit
        for (let i = 0; i < 30; i++) {
          await new Promise<void>((resolve) => setTimeout(resolve, 100));
          if (!isProcessAlive(existingPid)) break;
        }
        // If still alive, send SIGKILL
        if (isProcessAlive(existingPid)) {
          process.kill(existingPid, "SIGKILL");
          await new Promise<void>((resolve) => setTimeout(resolve, 200));
        }
      } catch {
        // Process may have already exited — ignore
      }
    }
    // Either dead or forcefully killed — remove stale lock
    removeLockFile(projectPath);
  }

  writeLockFile(projectPath);
}

/**
 * Release the lock (alias for removeLockFile, cleaner API for call sites).
 */
export function releaseLock(projectPath: string): void {
  removeLockFile(projectPath);
}
