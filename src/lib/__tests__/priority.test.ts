import { describe, it, expect } from "vitest";
import { normalizePriority, formatPriorityForBr } from "../priority.js";

describe("normalizePriority — P-prefixed strings", () => {
  it('converts "P0" to 0', () => {
    expect(normalizePriority("P0")).toBe(0);
  });

  it('converts "P1" to 1', () => {
    expect(normalizePriority("P1")).toBe(1);
  });

  it('converts "P2" to 2', () => {
    expect(normalizePriority("P2")).toBe(2);
  });

  it('converts "P3" to 3', () => {
    expect(normalizePriority("P3")).toBe(3);
  });

  it('converts "P4" to 4', () => {
    expect(normalizePriority("P4")).toBe(4);
  });
});

describe("normalizePriority — numeric strings", () => {
  it('converts "0" to 0', () => {
    expect(normalizePriority("0")).toBe(0);
  });

  it('converts "1" to 1', () => {
    expect(normalizePriority("1")).toBe(1);
  });

  it('converts "2" to 2', () => {
    expect(normalizePriority("2")).toBe(2);
  });

  it('converts "3" to 3', () => {
    expect(normalizePriority("3")).toBe(3);
  });

  it('converts "4" to 4', () => {
    expect(normalizePriority("4")).toBe(4);
  });
});

describe("normalizePriority — numeric pass-through", () => {
  it("passes 0 through unchanged", () => {
    expect(normalizePriority(0)).toBe(0);
  });

  it("passes 1 through unchanged", () => {
    expect(normalizePriority(1)).toBe(1);
  });

  it("passes 2 through unchanged", () => {
    expect(normalizePriority(2)).toBe(2);
  });

  it("passes 3 through unchanged", () => {
    expect(normalizePriority(3)).toBe(3);
  });

  it("passes 4 through unchanged", () => {
    expect(normalizePriority(4)).toBe(4);
  });
});

describe("normalizePriority — invalid inputs return 4", () => {
  it('returns 4 for "P5" (out of range)', () => {
    expect(normalizePriority("P5")).toBe(4);
  });

  it('returns 4 for "high"', () => {
    expect(normalizePriority("high")).toBe(4);
  });

  it('returns 4 for "medium"', () => {
    expect(normalizePriority("medium")).toBe(4);
  });

  it('returns 4 for "low"', () => {
    expect(normalizePriority("low")).toBe(4);
  });

  it('returns 4 for empty string ""', () => {
    expect(normalizePriority("")).toBe(4);
  });

  it("returns 4 for null cast as string", () => {
    expect(normalizePriority(null as unknown as string)).toBe(4);
  });

  it("returns 4 for undefined cast as string", () => {
    expect(normalizePriority(undefined as unknown as string)).toBe(4);
  });

  it("returns 4 for out-of-range number 5", () => {
    expect(normalizePriority(5)).toBe(4);
  });

  it("returns 4 for negative number -1", () => {
    expect(normalizePriority(-1)).toBe(4);
  });
});

describe("formatPriorityForBr", () => {
  it('formats "P2" as "2"', () => {
    expect(formatPriorityForBr("P2")).toBe("2");
  });

  it("formats numeric 3 as \"3\"", () => {
    expect(formatPriorityForBr(3)).toBe("3");
  });

  it('formats invalid "high" as "4" (default)', () => {
    expect(formatPriorityForBr("high")).toBe("4");
  });

  it('formats "P0" as "0"', () => {
    expect(formatPriorityForBr("P0")).toBe("0");
  });

  it('formats "4" as "4"', () => {
    expect(formatPriorityForBr("4")).toBe("4");
  });
});
