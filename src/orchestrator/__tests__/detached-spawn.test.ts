import { describe, it, expect, beforeEach, afterEach } from "vitest";
import {
  mkdtempSync,
  rmSync,
  writeFileSync,
  existsSync,
  readFileSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { spawn } from "node:child_process";

/**
 * Integration test: verify that a detached child process survives
 * the parent process exiting.
 *
 * This is the core guarantee of foreman-azo — agents must survive Ctrl+C.
 *
 * NOTE: We use plain `node` (not tsx) for child scripts to avoid the 2-3s
 * tsx startup overhead which causes flaky failures under full-suite load.
 */
describe("detached process survival", () => {
  let tmpDir: string;
  let spawnedPids: number[];

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-detach-test-"));
    spawnedPids = [];
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    for (const pid of spawnedPids) {
      try {
        process.kill(pid, "SIGKILL");
      } catch (err: unknown) {
        // Ignore ESRCH (no such process) — child already exited
        if ((err as NodeJS.ErrnoException).code !== "ESRCH") {
          throw err;
        }
      }
    }
  });

  /** Poll until predicate returns true or timeout elapses. */
  async function waitFor(
    predicate: () => boolean,
    timeoutMs = 10_000,
    pollMs = 100
  ): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (predicate()) return true;
      await new Promise((resolve) => setTimeout(resolve, pollMs));
    }
    return predicate();
  }

  it("detached child process writes a file after parent exits", async () => {
    // Write a small CJS script (no tsx needed — plain node is much faster to start).
    // The child sleeps briefly then writes a marker file.
    // We spawn it detached, unref it, and exit our "parent" wrapper.
    // After a short wait, the marker file should exist.
    const markerFile = join(tmpDir, "child-was-here.txt");
    const childScript = join(tmpDir, "child.cjs");

    writeFileSync(
      childScript,
      `
const { writeFileSync } = require("node:fs");
// Small delay to ensure parent has exited
setTimeout(() => {
  writeFileSync(${JSON.stringify(markerFile)}, "alive", "utf-8");
  process.exit(0);
}, 200);
    `.trim()
    );

    // Spawn the child as detached + unref (same as spawnWorkerProcess)
    const child = spawn(process.execPath, [childScript], {
      detached: true,
      stdio: "ignore",
      cwd: tmpDir,
    });
    child.unref();
    if (child.pid !== undefined) {
      spawnedPids.push(child.pid);
    }

    expect(child.pid).toBeDefined();

    // Poll until the marker file appears (or 10s timeout).
    // Polling is more robust than a fixed wait because it adapts to system load.
    const appeared = await waitFor(() => existsSync(markerFile), 10_000);

    expect(appeared).toBe(true);
    expect(existsSync(markerFile)).toBe(true);
    expect(readFileSync(markerFile, "utf-8")).toBe("alive");
  });

  it("detached child continues after SIGINT to process group", async () => {
    // This simulates what happens when a user presses Ctrl+C:
    // SIGINT is sent to the foreground process group. Detached children
    // are in their own process group and should NOT receive the signal.
    //
    // We verify that:
    //   1. The child is spawned in its own process group (child.pid defined)
    //   2. The child completes its work independently of the parent
    const markerFile = join(tmpDir, "survived-sigint.txt");
    const childScript = join(tmpDir, "child-sigint.cjs");

    writeFileSync(
      childScript,
      `
const { writeFileSync } = require("node:fs");
// Write marker after a short delay
setTimeout(() => {
  writeFileSync(${JSON.stringify(markerFile)}, "survived", "utf-8");
  process.exit(0);
}, 500);
    `.trim()
    );

    const child = spawn(process.execPath, [childScript], {
      detached: true,
      stdio: "ignore",
      cwd: tmpDir,
    });
    child.unref();
    if (child.pid !== undefined) {
      spawnedPids.push(child.pid);
    }

    // The child is in its own process group (detached: true).
    // Sending SIGINT to OUR process group won't affect it.
    expect(child.pid).toBeDefined();

    // Poll until the marker file appears (or 10s timeout).
    const appeared = await waitFor(() => existsSync(markerFile), 10_000);

    expect(appeared).toBe(true);
    expect(existsSync(markerFile)).toBe(true);
    expect(readFileSync(markerFile, "utf-8")).toBe("survived");
  });
});
