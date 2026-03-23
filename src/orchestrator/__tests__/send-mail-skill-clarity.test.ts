/**
 * Tests for bd-7ynm: Finalize agent wastes tool call checking 'which send-mail'
 * before discovering send_mail tool.
 *
 * Verifies that all default prompt files clearly explain that /send-mail is a
 * native Pi skill, not a bash command or binary, to prevent agents from running
 * `which send-mail` before discovering the native tool.
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const DEFAULT_PROMPTS_DIR = join(PROJECT_ROOT, "src", "defaults", "prompts", "default");
const SKILLS_DIR = join(PROJECT_ROOT, "src", "defaults", "skills");

const PHASES = ["explorer", "developer", "qa", "reviewer", "finalize"] as const;

describe("bd-7ynm: /send-mail skill clarity in default prompts", () => {
  for (const phase of PHASES) {
    describe(`default/${phase}.md`, () => {
      it("clarifies /send-mail is a native Pi skill, not a bash binary", () => {
        const content = readFileSync(join(DEFAULT_PROMPTS_DIR, `${phase}.md`), "utf-8");
        expect(content).toContain("native Pi skill");
      });

      it("explicitly warns NOT to use `which` to locate send-mail", () => {
        const content = readFileSync(join(DEFAULT_PROMPTS_DIR, `${phase}.md`), "utf-8");
        expect(content).toContain("which send-mail");
        // The "Do NOT" should appear before "which send-mail" in the same sentence
        expect(content.toLowerCase()).toMatch(/do not.*which send-mail/s);
      });

      it("still contains the /send-mail --help invocation", () => {
        const content = readFileSync(join(DEFAULT_PROMPTS_DIR, `${phase}.md`), "utf-8");
        expect(content).toContain("/send-mail --help");
      });
    });
  }
});

describe("bd-7ynm: send-mail skill definition clarity", () => {
  it("SKILL.md clarifies Pi handles bash execution (not the agent)", () => {
    const skillMd = readFileSync(join(SKILLS_DIR, "send-mail", "SKILL.md"), "utf-8");
    // Should NOT say "Run this bash command:" (old misleading wording)
    expect(skillMd).not.toContain("Run this bash command");
    // Should clarify Pi handles it
    expect(skillMd.toLowerCase()).toMatch(/pi will execute|pi handles/);
  });

  it("send-mail.yaml prompt clarifies Pi handles bash execution", () => {
    const yaml = readFileSync(join(SKILLS_DIR, "send-mail.yaml"), "utf-8");
    // Should NOT say just "Run this bash command:" without clarification
    expect(yaml).not.toContain("Run this bash command:");
    // Should clarify Pi handles it
    expect(yaml.toLowerCase()).toMatch(/pi will execute|pi handles/);
  });
});
