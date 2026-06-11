import { describe, it, expect } from "vitest";
import { getTaskBackend } from "../feature-flags.js";
import type { TaskBackend } from "../feature-flags.js";

describe("getTaskBackend — TRD-024: native task store is the only supported backend", () => {
  it("returns 'native' (the only supported backend)", () => {
    expect(getTaskBackend()).toBe("native");
  });
});

describe("getTaskBackend — return type is TaskBackend", () => {
  it("result is assignable to TaskBackend type", () => {
    // This is a compile-time assertion: if TaskBackend changes, this line
    // will produce a TypeScript error during `tsc --noEmit`.
    const result: TaskBackend = getTaskBackend();
    expect(result).toBe("native");
  });
});