import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  acquireLock,
  releaseLock,
  isProcessAlive,
  readLockFile,
  writeLockFile,
  removeLockFile,
  getLockFilePath,
  DispatcherAlreadyRunningError,
} from "../dispatcher-lock.js";

describe("dispatcher-lock", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-lock-test-"));
    // Create the .foreman subdirectory
    mkdirSync(join(tmpDir, ".foreman"), { recursive: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // ── isProcessAlive ───────────────────────────────────────────────────

  describe("isProcessAlive", () => {
    it("returns true for the current process", () => {
      expect(isProcessAlive(process.pid)).toBe(true);
    });

    it("returns false for a non-existent PID", () => {
      // PID 999999999 is astronomically unlikely to exist
      expect(isProcessAlive(999_999_999)).toBe(false);
    });
  });

  // ── getLockFilePath ──────────────────────────────────────────────────

  describe("getLockFilePath", () => {
    it("returns the expected path", () => {
      expect(getLockFilePath(tmpDir)).toBe(join(tmpDir, ".foreman", "foreman.pid"));
    });
  });

  // ── readLockFile / writeLockFile / removeLockFile ────────────────────

  describe("readLockFile", () => {
    it("returns null when lock file does not exist", () => {
      expect(readLockFile(tmpDir)).toBeNull();
    });

    it("returns the PID written by writeLockFile", () => {
      writeLockFile(tmpDir);
      const pid = readLockFile(tmpDir);
      expect(pid).toBe(process.pid);
    });

    it("returns null for non-numeric content", () => {
      writeFileSync(getLockFilePath(tmpDir), "not-a-pid", "utf-8");
      expect(readLockFile(tmpDir)).toBeNull();
    });

    it("returns null for zero PID", () => {
      writeFileSync(getLockFilePath(tmpDir), "0", "utf-8");
      expect(readLockFile(tmpDir)).toBeNull();
    });
  });

  describe("removeLockFile", () => {
    it("removes an existing lock file", () => {
      writeLockFile(tmpDir);
      expect(existsSync(getLockFilePath(tmpDir))).toBe(true);
      removeLockFile(tmpDir);
      expect(existsSync(getLockFilePath(tmpDir))).toBe(false);
    });

    it("does not throw when file does not exist", () => {
      expect(() => removeLockFile(tmpDir)).not.toThrow();
    });
  });

  // ── acquireLock ──────────────────────────────────────────────────────

  describe("acquireLock", () => {
    it("creates a PID file with current process PID", async () => {
      await acquireLock(tmpDir);
      const pid = readLockFile(tmpDir);
      expect(pid).toBe(process.pid);
    });

    it("overwrites a stale lock file (dead process)", async () => {
      // Write a PID that is definitely not alive
      writeFileSync(getLockFilePath(tmpDir), "999999999", "utf-8");
      await acquireLock(tmpDir);
      const pid = readLockFile(tmpDir);
      expect(pid).toBe(process.pid);
    });

    it("throws DispatcherAlreadyRunningError when current process holds the lock", async () => {
      // Simulate a live dispatcher by writing our own PID
      writeLockFile(tmpDir);

      // Remove THEN re-acquire to ensure clean state, then manually write our PID
      // We need to write a different PID that IS alive
      // Use process.pid (current process) as the "other" dispatcher
      // We need a different project path to avoid the lock we just released
      const altDir = mkdtempSync(join(tmpdir(), "foreman-lock-alt-"));
      mkdirSync(join(altDir, ".foreman"), { recursive: true });
      writeFileSync(getLockFilePath(altDir), String(process.pid), "utf-8");

      try {
        await expect(acquireLock(altDir)).rejects.toThrow(DispatcherAlreadyRunningError);
        await expect(acquireLock(altDir)).rejects.toThrow(`foreman run already active (pid ${process.pid})`);
      } finally {
        rmSync(altDir, { recursive: true, force: true });
      }
    });

    it("DispatcherAlreadyRunningError has the correct pid property", async () => {
      const altDir = mkdtempSync(join(tmpdir(), "foreman-lock-pid-"));
      mkdirSync(join(altDir, ".foreman"), { recursive: true });
      writeFileSync(getLockFilePath(altDir), String(process.pid), "utf-8");

      try {
        let caught: DispatcherAlreadyRunningError | undefined;
        try {
          await acquireLock(altDir);
        } catch (e) {
          caught = e as DispatcherAlreadyRunningError;
        }
        expect(caught).toBeInstanceOf(DispatcherAlreadyRunningError);
        expect(caught!.pid).toBe(process.pid);
      } finally {
        rmSync(altDir, { recursive: true, force: true });
      }
    });
  });

  // ── releaseLock ──────────────────────────────────────────────────────

  describe("releaseLock", () => {
    it("removes the lock file", async () => {
      await acquireLock(tmpDir);
      expect(existsSync(getLockFilePath(tmpDir))).toBe(true);
      releaseLock(tmpDir);
      expect(existsSync(getLockFilePath(tmpDir))).toBe(false);
    });

    it("is idempotent — does not throw if lock does not exist", () => {
      expect(() => releaseLock(tmpDir)).not.toThrow();
    });
  });

  // ── acquireLock with --force ─────────────────────────────────────────

  describe("acquireLock with force=true", () => {
    it("proceeds even when a stale lock file exists (dead PID)", async () => {
      writeFileSync(getLockFilePath(tmpDir), "999999999", "utf-8");
      await acquireLock(tmpDir, { force: true });
      expect(readLockFile(tmpDir)).toBe(process.pid);
    });

    it("creates the lock when no prior lock exists", async () => {
      await acquireLock(tmpDir, { force: true });
      expect(readLockFile(tmpDir)).toBe(process.pid);
    });
  });

  // ── acquireLock creates .foreman dir ────────────────────────────────

  describe("acquireLock directory creation", () => {
    it("creates .foreman directory if it does not exist", async () => {
      const newDir = mkdtempSync(join(tmpdir(), "foreman-lock-new-"));
      // Do NOT create .foreman — acquireLock should create it
      try {
        await acquireLock(newDir);
        expect(existsSync(join(newDir, ".foreman", "foreman.pid"))).toBe(true);
      } finally {
        rmSync(newDir, { recursive: true, force: true });
      }
    });
  });
});
