/**
 * Unit tests for the --no-llm title/description derivation in
 * create-from-text.ts (formerly inline in bead.ts).
 *
 * The original implementation hard-sliced the input at 200 UTF-16 code units,
 * which could cut a word in half or split a surrogate pair (producing a lone
 * surrogate in the title). splitTitleFromText() keeps the 200-code-unit cap
 * but prefers word boundaries and never splits surrogate pairs.
 */
import { describe, expect, it } from "vitest";
import { splitTitleFromText } from "../create-from-text.js";

/** True when the string contains an unpaired UTF-16 surrogate code unit. */
function hasLoneSurrogate(s: string): boolean {
  return /(?:^|[^\uD800-\uDBFF])[\uDC00-\uDFFF]|[\uD800-\uDBFF](?![\uDC00-\uDFFF])/.test(s);
}

describe("splitTitleFromText", () => {
  it("returns short text as the title with no description", () => {
    expect(splitTitleFromText("Fix the login bug")).toEqual({
      title: "Fix the login bug",
      description: undefined,
    });
  });

  it("returns text of exactly 200 chars untouched", () => {
    const text = "a".repeat(200);
    expect(splitTitleFromText(text)).toEqual({ title: text, description: undefined });
  });

  it("splits long text at a word boundary instead of mid-word", () => {
    const text = `${"a".repeat(190)} ${"b".repeat(100)}`;
    const { title, description } = splitTitleFromText(text);
    expect(title).toBe("a".repeat(190));
    expect(description).toBe("b".repeat(100));
  });

  it("never produces a title longer than 200 code units", () => {
    const text = `word ${"x".repeat(400)}`;
    const { title } = splitTitleFromText(text);
    expect(title.length).toBeLessThanOrEqual(200);
  });

  it("hard-cuts a long unbroken string at 200 code units", () => {
    const text = "z".repeat(300);
    const { title, description } = splitTitleFromText(text);
    expect(title).toBe("z".repeat(200));
    expect(description).toBe("z".repeat(100));
  });

  it("does not split a surrogate pair straddling the 200-unit boundary", () => {
    // 199 ASCII chars, then emoji (2 code units each): the first emoji's
    // high surrogate sits at index 199, so a naive slice(0, 200) would
    // produce a lone surrogate at the end of the title.
    const text = "x".repeat(199) + "😀".repeat(30);
    const { title, description } = splitTitleFromText(text);
    expect(title).toBe("x".repeat(199));
    expect(hasLoneSurrogate(title)).toBe(false);
    expect(description).toBe("😀".repeat(30));
  });

  it("hard-cuts pure-emoji text on a code-point boundary", () => {
    const text = "😀".repeat(150); // 300 code units, no whitespace
    const { title, description } = splitTitleFromText(text);
    expect(title).toBe("😀".repeat(100)); // 200 code units, all complete pairs
    expect(hasLoneSurrogate(title)).toBe(false);
    expect(description).toBe("😀".repeat(50));
  });

  it("does not leave the separator whitespace on either side of the split", () => {
    const text = `${"a".repeat(198)}   ${"b".repeat(50)}`;
    const { title, description } = splitTitleFromText(text);
    expect(title).toBe("a".repeat(198));
    expect(description).toBe("b".repeat(50));
  });
});
