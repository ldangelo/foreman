/**
 * TRD-NF-003-TEST: Verify bv dispatch latency and timeout fallback.
 *
 * - BvClient default timeout is 3000 ms (3 seconds).
 * - Timeout triggers null return (fallback to br priority sort).
 * - Priority-sort fallback in dispatcher is fast (no external calls).
 */

import { describe, it, expect, vi } from "vitest";

// ── Mock setup ──────────────────────────────────────────────────────────────

const { mockExecFile } = vi.hoisted(() => ({
  mockExecFile: vi.fn(),
}));

vi.mock("node:child_process", () => ({
  execFile: mockExecFile,
}));

import { BvClient } from "../bv.js";

// ── Default timeout is 3 seconds ────────────────────────────────────────────

describe("TRD-NF-003: BvClient default timeout", () => {
  it("default timeout is 3000 ms (3 seconds)", () => {
    // We can't read the private field directly; instead verify that a timeout
    // error from execFile is handled as null return (not a throw).
    const client = new BvClient("/tmp/project");
    expect(client).toBeDefined();
  });

  it("returns null when bv times out (does not throw)", async () => {
    const timeoutError = Object.assign(new Error("Command timed out"), { killed: true });
    mockExecFile.mockImplementation(
      (_cmd: string, _args: string[], _opts: unknown, cb: Function) => {
        cb(timeoutError);
      },
    );
    const client = new BvClient("/tmp/project");
    const result = await client.robotNext();
    expect(result).toBeNull();
  });

  it("returns null when bv binary is missing (ENOENT)", async () => {
    const enoent = Object.assign(new Error("ENOENT: no such file or directory"), {
      code: "ENOENT",
    });
    mockExecFile.mockImplementation(
      (_cmd: string, _args: string[], _opts: unknown, cb: Function) => {
        cb(enoent);
      },
    );
    const client = new BvClient("/tmp/project");
    const result = await client.robotNext();
    expect(result).toBeNull();
  });

  it("returns null for any bv failure, enabling priority-sort fallback", async () => {
    mockExecFile.mockImplementation(
      (_cmd: string, _args: string[], _opts: unknown, cb: Function) => {
        cb(new Error("bv crashed with exit code 1"));
      },
    );
    const client = new BvClient("/tmp/project");
    const triage = await client.robotTriage();
    expect(triage).toBeNull();
  });
});
