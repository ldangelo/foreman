/**
 * Tests for TRD-022: Make --br-only default behavior in sling command.
 *
 * Verifies:
 * - When neither --sd-only nor --br-only is specified, brOnly defaults to true
 * - --br-only flag is retained (no-op when already default)
 * - --sd-only combined with --br-only is not the scope here (handled by TRD-021)
 */

import { describe, it, expect } from "vitest";
import { resolveDefaultBrOnly } from "../commands/sling.js";

describe("TRD-022: resolveDefaultBrOnly()", () => {
  it("sets brOnly=true when neither flag is provided", () => {
    const opts: { sdOnly?: boolean; brOnly?: boolean } = {};
    resolveDefaultBrOnly(opts);
    expect(opts.brOnly).toBe(true);
  });

  it("sets brOnly=true when both flags are explicitly false", () => {
    const opts = { sdOnly: false, brOnly: false };
    resolveDefaultBrOnly(opts);
    expect(opts.brOnly).toBe(true);
  });

  it("does not change brOnly when it is already true (--br-only explicit is a no-op)", () => {
    const opts = { sdOnly: false, brOnly: true };
    resolveDefaultBrOnly(opts);
    expect(opts.brOnly).toBe(true);
  });

  it("does not set brOnly when sdOnly is true (sdOnly takes precedence)", () => {
    const opts = { sdOnly: true, brOnly: false };
    resolveDefaultBrOnly(opts);
    // sdOnly=true prevents the default — sdOnly flag is still set
    expect(opts.brOnly).toBe(false);
  });

  it("does not mutate opts when brOnly is already true", () => {
    const opts = { sdOnly: false, brOnly: true };
    const before = { ...opts };
    resolveDefaultBrOnly(opts);
    expect(opts).toEqual(before);
  });

  it("default br behavior: opts with no flags results in brOnly=true sdOnly=false", () => {
    const opts: { sdOnly?: boolean; brOnly?: boolean } = {};
    resolveDefaultBrOnly(opts);
    expect(opts.brOnly).toBe(true);
    expect(opts.sdOnly).toBeUndefined(); // untouched
  });
});
