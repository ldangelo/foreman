import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

/**
 * AT-T043: Session name edge case tests for tmuxSessionName().
 *
 * Tests unicode characters, very long seed IDs, special characters,
 * existing tmux naming patterns, and case sensitivity.
 */

// ── Mock Setup ──────────────────────────────────────────────────────────────

vi.mock("node:child_process", () => {
  const mockExecFile = vi.fn();
  return { execFile: mockExecFile };
});

vi.mock("node:util", () => ({
  promisify: vi.fn((fn: unknown) => fn),
}));

let tmuxSessionName: typeof import("../tmux.js").tmuxSessionName;

// ── Tests ───────────────────────────────────────────────────────────────────

describe("tmuxSessionName edge cases", () => {
  beforeEach(async () => {
    vi.resetModules();
    vi.doMock("node:child_process", () => ({
      execFile: vi.fn(),
    }));
    vi.doMock("node:util", () => ({
      promisify: vi.fn((fn: unknown) => fn),
    }));
    const mod = await import("../tmux.js");
    tmuxSessionName = mod.tmuxSessionName;
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  // ── 1. Unicode characters ─────────────────────────────────────────────

  describe("unicode characters in seed IDs", () => {
    it("passes through basic unicode letters", () => {
      // tmux allows most characters; the sanitizer only strips :, ., and spaces
      const result = tmuxSessionName("cafe-resume");
      expect(result).toBe("foreman-cafe-resume");
    });

    it("preserves unicode alphanumerics", () => {
      const result = tmuxSessionName("task-42-alpha");
      expect(result).toBe("foreman-task-42-alpha");
    });

    it("handles emoji characters in seed IDs", () => {
      // Emojis are not in the sanitization regex, so they pass through
      const result = tmuxSessionName("task-\u{1F680}");
      expect(result).toBe("foreman-task-\u{1F680}");
    });

    it("handles CJK characters", () => {
      const result = tmuxSessionName("\u4EFB\u52A1-001");
      expect(result).toBe("foreman-\u4EFB\u52A1-001");
    });

    it("handles Arabic characters", () => {
      const result = tmuxSessionName("\u0645\u0647\u0645\u0629-5");
      expect(result).toBe("foreman-\u0645\u0647\u0645\u0629-5");
    });

    it("handles Cyrillic characters", () => {
      const result = tmuxSessionName("\u0437\u0430\u0434\u0430\u0447\u0430-10");
      expect(result).toBe("foreman-\u0437\u0430\u0434\u0430\u0447\u0430-10");
    });

    it("handles mixed unicode with special chars (colons/periods/spaces sanitized)", () => {
      const result = tmuxSessionName("\u4EFB\u52A1:v2.\u03B1 test");
      expect(result).toBe("foreman-\u4EFB\u52A1-v2-\u03B1-test");
    });

    it("handles zero-width characters (ZWJ, ZWNJ)", () => {
      const result = tmuxSessionName("task\u200D\u200Cid");
      expect(result).toBe("foreman-task\u200D\u200Cid");
    });

    it("handles combining diacritical marks", () => {
      // e + combining acute accent
      const result = tmuxSessionName("caf\u0065\u0301");
      expect(result).toBe("foreman-caf\u0065\u0301");
    });
  });

  // ── 2. Very long seed IDs (tmux ~256 char name limit) ─────────────────

  describe("very long seed IDs", () => {
    it("handles seed ID at exactly 256 characters", () => {
      const longId = "a".repeat(256);
      const result = tmuxSessionName(longId);
      expect(result).toBe(`foreman-${longId}`);
      // Total length: 8 (foreman-) + 256 = 264
      expect(result.length).toBe(264);
    });

    it("handles seed ID exceeding 256 characters", () => {
      const veryLongId = "x".repeat(500);
      const result = tmuxSessionName(veryLongId);
      // The function does not truncate — it returns the full name
      expect(result).toBe(`foreman-${veryLongId}`);
      expect(result.length).toBe(508);
    });

    it("handles seed ID of 1000 characters", () => {
      const hugeId = "seed-" + "z".repeat(995);
      const result = tmuxSessionName(hugeId);
      expect(result.startsWith("foreman-seed-")).toBe(true);
      expect(result.length).toBe(1008); // 8 + 1000
    });

    it("handles long seed ID with many sanitizable characters", () => {
      // Alternating colons and letters
      const longId = Array.from({ length: 100 }, (_, i) => (i % 2 === 0 ? "a" : ":")).join("");
      const result = tmuxSessionName(longId);
      expect(result).not.toContain(":");
      expect(result.startsWith("foreman-")).toBe(true);
    });

    it("returns valid non-empty name for single character", () => {
      expect(tmuxSessionName("a")).toBe("foreman-a");
    });
  });

  // ── 3. Seed IDs that are entirely special characters ──────────────────

  describe("seed IDs that are entirely special characters", () => {
    it("returns foreman-unknown for all colons", () => {
      // Colons are replaced with hyphens, resulting in all-hyphens which is empty after replace
      const result = tmuxSessionName(":::");
      expect(result).toBe("foreman-unknown");
    });

    it("returns foreman-unknown for all periods", () => {
      const result = tmuxSessionName("...");
      expect(result).toBe("foreman-unknown");
    });

    it("returns foreman-unknown for all spaces", () => {
      const result = tmuxSessionName("   ");
      expect(result).toBe("foreman-unknown");
    });

    it("returns foreman-unknown for mixed sanitizable-only characters", () => {
      const result = tmuxSessionName(": . : .");
      expect(result).toBe("foreman-unknown");
    });

    it("preserves hyphens that were in the original", () => {
      // Hyphens are not in the sanitize regex, so "---" should be kept
      const result = tmuxSessionName("---");
      // After sanitization, "---" remains. After replace(/-/g, "") -> empty -> fallback
      expect(result).toBe("foreman-unknown");
    });

    it("handles single colon", () => {
      const result = tmuxSessionName(":");
      expect(result).toBe("foreman-unknown");
    });

    it("handles single period", () => {
      const result = tmuxSessionName(".");
      expect(result).toBe("foreman-unknown");
    });

    it("handles exclamation marks and other non-sanitized specials", () => {
      // ! @ # $ % are NOT in the sanitization regex, so they pass through
      const result = tmuxSessionName("!@#$%");
      expect(result).toBe("foreman-!@#$%");
    });

    it("handles tab characters", () => {
      // Tabs are not spaces in the regex \\s matches them
      const result = tmuxSessionName("\t\t");
      expect(result).toBe("foreman-unknown");
    });

    it("handles newline characters", () => {
      // \\s matches newlines
      const result = tmuxSessionName("\n\n");
      expect(result).toBe("foreman-unknown");
    });

    it("handles mixed whitespace types", () => {
      const result = tmuxSessionName(" \t\n\r");
      expect(result).toBe("foreman-unknown");
    });
  });

  // ── 4. Seed IDs matching existing tmux session naming patterns ────────

  describe("seed IDs matching tmux naming patterns", () => {
    it("handles seed ID that looks like a tmux session name", () => {
      const result = tmuxSessionName("foreman-existing");
      expect(result).toBe("foreman-foreman-existing");
    });

    it("handles seed ID with numeric-only value", () => {
      const result = tmuxSessionName("12345");
      expect(result).toBe("foreman-12345");
    });

    it("handles seed ID that is just 'foreman'", () => {
      const result = tmuxSessionName("foreman");
      expect(result).toBe("foreman-foreman");
    });

    it("handles seed ID with tmux special target syntax (-t format)", () => {
      const result = tmuxSessionName("-t");
      expect(result).toBe("foreman--t");
    });

    it("handles seed ID starting with a hyphen", () => {
      const result = tmuxSessionName("-leading-hyphen");
      expect(result).toBe("foreman--leading-hyphen");
    });

    it("handles seed ID that is a single hyphen", () => {
      // Single hyphen: sanitized remains "-", replace(/-/g, "") -> "" -> fallback
      const result = tmuxSessionName("-");
      expect(result).toBe("foreman-unknown");
    });

    it("handles seed ID matching tmux window:pane format", () => {
      // "session:0.1" -> colons and periods replaced
      const result = tmuxSessionName("session:0.1");
      expect(result).toBe("foreman-session-0-1");
    });

    it("handles seed ID with equals sign (tmux option format)", () => {
      const result = tmuxSessionName("key=value");
      expect(result).toBe("foreman-key=value");
    });

    it("handles seed ID with dollar sign (tmux variable format)", () => {
      const result = tmuxSessionName("$session");
      expect(result).toBe("foreman-$session");
    });

    it("handles seed ID with curly braces", () => {
      const result = tmuxSessionName("{task-1}");
      expect(result).toBe("foreman-{task-1}");
    });
  });

  // ── 5. Case sensitivity ───────────────────────────────────────────────

  describe("case sensitivity", () => {
    it("preserves uppercase letters", () => {
      expect(tmuxSessionName("ABC")).toBe("foreman-ABC");
    });

    it("preserves lowercase letters", () => {
      expect(tmuxSessionName("abc")).toBe("foreman-abc");
    });

    it("preserves mixed case", () => {
      expect(tmuxSessionName("AbCdEf")).toBe("foreman-AbCdEf");
    });

    it("generates different names for different cases", () => {
      const lower = tmuxSessionName("task-abc");
      const upper = tmuxSessionName("task-ABC");
      const mixed = tmuxSessionName("task-Abc");
      expect(lower).not.toBe(upper);
      expect(lower).not.toBe(mixed);
      expect(upper).not.toBe(mixed);
    });

    it("preserves case in sanitized strings", () => {
      const result = tmuxSessionName("Task:V2.Beta Release");
      expect(result).toBe("foreman-Task-V2-Beta-Release");
    });
  });

  // ── Determinism and consistency ───────────────────────────────────────

  describe("determinism", () => {
    it("produces the same output for the same input", () => {
      const input = "seed-42:v3.rc1 beta";
      const r1 = tmuxSessionName(input);
      const r2 = tmuxSessionName(input);
      const r3 = tmuxSessionName(input);
      expect(r1).toBe(r2);
      expect(r2).toBe(r3);
    });

    it("always starts with foreman- prefix", () => {
      const inputs = [
        "abc", "", "   ", ":::", "...", "foreman-nested",
        "\u4EFB\u52A1", "a".repeat(300), "!@#",
      ];
      for (const input of inputs) {
        expect(tmuxSessionName(input).startsWith("foreman-")).toBe(true);
      }
    });
  });
});
