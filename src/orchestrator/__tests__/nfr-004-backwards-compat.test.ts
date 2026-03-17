/**
 * TRD-NF-004-TEST: Verify in-flight run compatibility.
 *
 * Monitor handles "issue not found" / "404" errors as transient during
 * migration, not as hard failures. This allows existing SQLite run records
 * with sd-format seed IDs to be processed safely.
 */

import { describe, it, expect } from "vitest";
import { isNotFoundError } from "../monitor.js";

describe("TRD-NF-004: monitor transient error detection (isNotFoundError)", () => {
  it("'not found' is treated as transient", () => {
    expect(isNotFoundError(new Error("Issue not found: bd-abc"))).toBe(true);
  });

  it("'Not Found' (capitalised) is treated as transient", () => {
    expect(isNotFoundError(new Error("Not Found"))).toBe(true);
  });

  it("'404' in message is treated as transient", () => {
    expect(isNotFoundError(new Error("HTTP 404: resource missing"))).toBe(true);
  });

  it("database connection error is NOT transient", () => {
    expect(isNotFoundError(new Error("Database connection lost"))).toBe(false);
  });

  it("permission denied is NOT transient", () => {
    expect(isNotFoundError(new Error("EPERM: permission denied"))).toBe(false);
  });

  it("generic unexpected error is NOT transient", () => {
    expect(isNotFoundError(new Error("Unexpected token < in JSON"))).toBe(false);
  });

  it("non-Error values are handled (string)", () => {
    expect(isNotFoundError("not found somewhere")).toBe(true);
  });

  it("non-Error values are handled (unrelated string)", () => {
    expect(isNotFoundError("connection refused")).toBe(false);
  });
});
