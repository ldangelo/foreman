import { PassThrough } from "node:stream";
import { EventEmitter } from "node:events";
import { describe, it, expect, vi } from "vitest";
import { PiRpcClient } from "../pi-rpc-client.js";
import type { PiEvent } from "../pi-rpc-client.js";

// ── Helper: build a fake ChildProcess ────────────────────────────────────────

function makeMockProcess() {
  const stdin = new PassThrough();
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const proc = Object.assign(new EventEmitter(), { stdin, stdout, stderr });
  return { proc, stdin, stdout, stderr };
}

/**
 * Read all buffered data from a PassThrough stream as a UTF-8 string.
 * Uses a small async tick so the readline interface has time to flush.
 */
async function drainStdin(stdin: PassThrough): Promise<string> {
  return new Promise<string>((resolve) => {
    let buf = "";
    stdin.on("data", (chunk: Buffer) => {
      buf += chunk.toString("utf8");
    });
    // Allow the current microtask queue to drain before resolving
    setImmediate(() => resolve(buf));
  });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("PiRpcClient — sendCommand()", () => {
  it("writes a JSON line with \\n for cmd:prompt", async () => {
    const { proc, stdin } = makeMockProcess();
    const client = new PiRpcClient(proc as never, { watchdogTimeoutMs: 5000 });

    const collectedChunks: string[] = [];
    stdin.on("data", (chunk: Buffer) => collectedChunks.push(chunk.toString("utf8")));

    await client.sendCommand({ cmd: "prompt", text: "hello" });

    // Give the stream a tick to flush
    await new Promise((r) => setImmediate(r));

    const written = collectedChunks.join("");
    expect(written).toBe(JSON.stringify({ cmd: "prompt", text: "hello" }) + "\n");

    client.destroy();
  });

  it("writes correct JSON for cmd:set_model", async () => {
    const { proc, stdin } = makeMockProcess();
    const client = new PiRpcClient(proc as never, { watchdogTimeoutMs: 5000 });

    const collectedChunks: string[] = [];
    stdin.on("data", (chunk: Buffer) => collectedChunks.push(chunk.toString("utf8")));

    await client.sendCommand({ cmd: "set_model", model: "claude-sonnet-4-6" });
    await new Promise((r) => setImmediate(r));

    const written = collectedChunks.join("");
    expect(written).toBe(
      JSON.stringify({ cmd: "set_model", model: "claude-sonnet-4-6" }) + "\n"
    );

    client.destroy();
  });

  it("writes correct JSON for cmd:set_context with files array", async () => {
    const { proc, stdin } = makeMockProcess();
    const client = new PiRpcClient(proc as never, { watchdogTimeoutMs: 5000 });

    const collectedChunks: string[] = [];
    stdin.on("data", (chunk: Buffer) => collectedChunks.push(chunk.toString("utf8")));

    const files = [
      { path: "/src/index.ts", content: "export default 42;" },
      { path: "/src/util.ts", content: "export const noop = () => {};" },
    ];
    await client.sendCommand({ cmd: "set_context", files });
    await new Promise((r) => setImmediate(r));

    const written = collectedChunks.join("");
    expect(written).toBe(JSON.stringify({ cmd: "set_context", files }) + "\n");

    client.destroy();
  });
});

describe("PiRpcClient — stdout event parsing", () => {
  it("emits 'event' with parsed object when stdout emits agent_end JSONL", async () => {
    const { proc, stdout } = makeMockProcess();
    const client = new PiRpcClient(proc as never, { watchdogTimeoutMs: 5000 });

    const received: PiEvent[] = [];
    client.on("event", (e: PiEvent) => received.push(e));

    stdout.write('{"type":"agent_end","reason":"completed"}\n');
    await new Promise((r) => setImmediate(r));

    expect(received).toHaveLength(1);
    expect(received[0]).toEqual({ type: "agent_end", reason: "completed" });

    client.destroy();
  });

  it("emits 'event' with parsed object when stdout emits turn_end JSONL", async () => {
    const { proc, stdout } = makeMockProcess();
    const client = new PiRpcClient(proc as never, { watchdogTimeoutMs: 5000 });

    const received: PiEvent[] = [];
    client.on("event", (e: PiEvent) => received.push(e));

    stdout.write('{"type":"turn_end","turnNumber":5}\n');
    await new Promise((r) => setImmediate(r));

    expect(received).toHaveLength(1);
    expect(received[0]).toEqual({ type: "turn_end", turnNumber: 5 });

    client.destroy();
  });

  it("does NOT emit 'event' for invalid JSON lines and does not crash", async () => {
    const { proc, stdout } = makeMockProcess();
    const client = new PiRpcClient(proc as never, { watchdogTimeoutMs: 5000 });

    const received: PiEvent[] = [];
    const errors: Error[] = [];
    client.on("event", (e: PiEvent) => received.push(e));
    client.on("error", (e: Error) => errors.push(e));

    // Write some garbage lines followed by a valid line to confirm no crash
    stdout.write("not json at all\n");
    stdout.write("{broken json\n");
    stdout.write('{"type":"agent_start"}\n');
    await new Promise((r) => setImmediate(r));

    // Only the valid JSON line should have been emitted
    expect(received).toHaveLength(1);
    expect(received[0]).toEqual({ type: "agent_start" });
    expect(errors).toHaveLength(0);

    client.destroy();
  });
});

describe("PiRpcClient — lifecycle events", () => {
  it("emits 'close' when stdout stream ends", async () => {
    const { proc, stdout } = makeMockProcess();
    const client = new PiRpcClient(proc as never, { watchdogTimeoutMs: 5000 });

    let closeFired = false;
    client.on("close", () => {
      closeFired = true;
    });

    // End the stdout stream to simulate process exit
    stdout.end();
    await new Promise((r) => setImmediate(r));

    expect(closeFired).toBe(true);
  });
});

describe("PiRpcClient — watchdog timeout", () => {
  it("emits 'error' when no stdout activity within watchdogTimeoutMs", async () => {
    vi.useFakeTimers();

    const { proc } = makeMockProcess();
    const client = new PiRpcClient(proc as never, { watchdogTimeoutMs: 50 });

    const errors: Error[] = [];
    client.on("error", (e: Error) => errors.push(e));

    // Advance time past watchdog threshold
    vi.advanceTimersByTime(100);

    expect(errors).toHaveLength(1);
    expect(errors[0].message).toContain("watchdog timeout");

    client.destroy();
    vi.useRealTimers();
  });

  it("resets watchdog timer when stdout activity occurs", async () => {
    vi.useFakeTimers();

    const { proc, stdout } = makeMockProcess();
    const client = new PiRpcClient(proc as never, { watchdogTimeoutMs: 50 });

    const errors: Error[] = [];
    client.on("error", (e: Error) => errors.push(e));

    // Advance to just before timeout, then send a line
    vi.advanceTimersByTime(40);
    stdout.write('{"type":"agent_start"}\n');

    // Advance 40ms more — without the reset this would have fired at t=50
    vi.advanceTimersByTime(40);

    // No error should have fired yet (next timeout is at t=40+50=90)
    expect(errors).toHaveLength(0);

    client.destroy();
    vi.useRealTimers();
  });
});

describe("PiRpcClient — backpressure", () => {
  it("resolves sendCommand after 'drain' event when stdin.write returns false", async () => {
    const { proc, stdin } = makeMockProcess();
    const client = new PiRpcClient(proc as never, { watchdogTimeoutMs: 5000 });

    // Make write() return false on the first call to simulate backpressure.
    // The implementation should wait for 'drain' before resolving.
    vi.spyOn(stdin, "write").mockReturnValueOnce(false);

    let resolved = false;
    const promise = client.sendCommand({ cmd: "prompt", text: "backpressure test" }).then(() => {
      resolved = true;
    });

    // Not yet resolved — write returned false and drain has not fired
    await new Promise((r) => setImmediate(r));
    expect(resolved).toBe(false);

    // Fire drain to unblock the write
    stdin.emit("drain");

    await promise;
    expect(resolved).toBe(true);

    client.destroy();
  });
});

describe("PiRpcClient — constructor validation", () => {
  it("throws if child process has no stdout", () => {
    const proc = Object.assign(new EventEmitter(), {
      stdin: new PassThrough(),
      stdout: null,
      stderr: new PassThrough(),
    });

    expect(() => new PiRpcClient(proc as never)).toThrow(
      "PiRpcClient requires a child process with stdout pipe"
    );
  });
});
