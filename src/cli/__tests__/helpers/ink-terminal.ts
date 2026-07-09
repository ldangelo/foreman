import { PassThrough, Writable } from "node:stream";
import type { ReactElement } from "react";
import { render as renderInk, type Instance } from "ink";

const ANSI_PATTERN = /\u001B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\u0007]*(?:\u0007|\u001B\\))/g;

class InkTerminalStdin extends PassThrough {
  isTTY = true;
  isRaw = false;

  setRawMode(enabled: boolean): this {
    this.isRaw = enabled;
    return this;
  }

  ref(): this {
    return this;
  }

  unref(): this {
    return this;
  }
}

class InkTerminalOutput extends Writable {
  isTTY = true;
  columns: number;
  rows: number;
  private chunks: string[] = [];

  constructor({ columns, rows }: { columns: number; rows: number }) {
    super();
    this.columns = columns;
    this.rows = rows;
  }

  _write(chunk: Buffer | string, _encoding: BufferEncoding, callback: (error?: Error | null) => void): void {
    this.chunks.push(Buffer.isBuffer(chunk) ? chunk.toString("utf8") : chunk);
    callback();
  }

  output(): string {
    return this.chunks.join("");
  }

  plainOutput(): string {
    return stripAnsi(this.output());
  }

  clearOutput(): void {
    this.chunks = [];
  }
}

export interface InkTerminalHarness {
  stdin: InkTerminalStdin;
  stdout: InkTerminalOutput;
  stderr: InkTerminalOutput;
  instance: Instance;
  output: () => string;
  plainOutput: () => string;
  clearOutput: () => void;
  send: (input: string) => Promise<void>;
  sendKey: (key: "enter" | "escape" | "up" | "down" | "tab" | "backspace" | "delete") => Promise<void>;
  waitForOutput: (expected: string | RegExp, options?: { timeoutMs?: number }) => Promise<string>;
  cleanup: () => Promise<void>;
}

export function stripAnsi(value: string): string {
  return value.replace(ANSI_PATTERN, "");
}

export async function renderInkTerminal(element: ReactElement, options: { columns?: number; rows?: number } = {}): Promise<InkTerminalHarness> {
  const stdin = new InkTerminalStdin();
  const stdout = new InkTerminalOutput({ columns: options.columns ?? 160, rows: options.rows ?? 40 });
  const stderr = new InkTerminalOutput({ columns: options.columns ?? 160, rows: options.rows ?? 40 });
  let renderCount = 0;

  const instance = renderInk(element, {
    stdin: stdin as unknown as NodeJS.ReadStream,
    stdout: stdout as unknown as NodeJS.WriteStream,
    stderr: stderr as unknown as NodeJS.WriteStream,
    patchConsole: false,
    exitOnCtrlC: false,
    debug: true,
    onRender: () => {
      renderCount += 1;
    },
  });

  await waitFor(() => renderCount > 0, { timeoutMs: 500 });
  await waitFor(() => stdin.isRaw, { timeoutMs: 500 });
  const settle = async (): Promise<void> => {
    await new Promise<void>((resolve) => setImmediate(resolve));
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    await new Promise<void>((resolve) => setImmediate(resolve));
  };

  const send = async (input: string): Promise<void> => {
    const before = renderCount;
    stdin.write(input);
    await settle();
    if (renderCount === before) await settle();
  };

  return {
    stdin,
    stdout,
    stderr,
    instance,
    output: () => stdout.output(),
    plainOutput: () => stdout.plainOutput(),
    clearOutput: () => stdout.clearOutput(),
    send,
    sendKey: async (key) => {
      await send(keyBytes(key));
    },
    waitForOutput: async (expected, waitOptions = {}) => {
      try {
        await waitFor(() => {
          const output = stdout.plainOutput();
          return typeof expected === "string" ? output.includes(expected) : expected.test(output);
        }, { timeoutMs: waitOptions.timeoutMs ?? 1000 });
      } catch (err: unknown) {
        const expectedText = typeof expected === "string" ? expected : expected.toString();
        throw new Error(`Timed out waiting for Ink terminal output: ${expectedText}\n${stdout.plainOutput().slice(-2000)}`, { cause: err });
      }
      return stdout.plainOutput();
    },
    cleanup: async () => {
      instance.unmount();
      instance.cleanup();
      stdin.destroy();
      stdout.destroy();
      stderr.destroy();
      await settle();
    },
  };
}

function keyBytes(key: "enter" | "escape" | "up" | "down" | "tab" | "backspace" | "delete"): string {
  switch (key) {
    case "enter":
      return "\r";
    case "escape":
      return "\u001B";
    case "up":
      return "\u001B[A";
    case "down":
      return "\u001B[B";
    case "tab":
      return "\t";
    case "backspace":
      return "\u007F";
    case "delete":
      return "\u001B[3~";
  }
}

async function waitFor(predicate: () => boolean, options: { timeoutMs: number }): Promise<void> {
  const started = Date.now();
  while (!predicate()) {
    if (Date.now() - started > options.timeoutMs) {
      throw new Error("Timed out waiting for Ink terminal output");
    }
    await new Promise<void>((resolve) => setTimeout(resolve, 10));
  }
}
