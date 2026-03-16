import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { getTaskBackend } from "../feature-flags.js";
import type { TaskBackend } from "../feature-flags.js";

describe("getTaskBackend — default behaviour", () => {
  beforeEach(() => {
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  afterEach(() => {
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  it("returns 'sd' when FOREMAN_TASK_BACKEND is not set", () => {
    expect(getTaskBackend()).toBe("sd");
  });
});

describe("getTaskBackend — explicit values", () => {
  afterEach(() => {
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  it("returns 'sd' when FOREMAN_TASK_BACKEND='sd'", () => {
    process.env.FOREMAN_TASK_BACKEND = "sd";
    expect(getTaskBackend()).toBe("sd");
  });

  it("returns 'br' when FOREMAN_TASK_BACKEND='br'", () => {
    process.env.FOREMAN_TASK_BACKEND = "br";
    expect(getTaskBackend()).toBe("br");
  });
});

describe("getTaskBackend — unrecognised values fall back to 'sd'", () => {
  afterEach(() => {
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  it("returns 'sd' for unrecognised value 'unknown'", () => {
    process.env.FOREMAN_TASK_BACKEND = "unknown";
    expect(getTaskBackend()).toBe("sd");
  });

  it("returns 'sd' for empty string", () => {
    process.env.FOREMAN_TASK_BACKEND = "";
    expect(getTaskBackend()).toBe("sd");
  });

  it("returns 'sd' for value 'BR' (case-sensitive)", () => {
    process.env.FOREMAN_TASK_BACKEND = "BR";
    expect(getTaskBackend()).toBe("sd");
  });
});

describe("getTaskBackend — return type is TaskBackend union", () => {
  it("result is assignable to TaskBackend type", () => {
    // This is a compile-time assertion: if TaskBackend changes, this line
    // will produce a TypeScript error during `tsc --noEmit`.
    const result: TaskBackend = getTaskBackend();
    expect(result === "sd" || result === "br").toBe(true);
  });
});
