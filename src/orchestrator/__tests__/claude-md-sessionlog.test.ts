import { describe, it, expect } from "vitest";
import { readFileSync } from "fs";
import { resolve } from "path";

/**
 * Verifies that CLAUDE.md (the agent context file placed in every worktree)
 * contains the required Session Logging section so agents know they must
 * create SESSION_LOG.md for audit and debugging purposes.
 *
 * NOTE: `process.cwd()` is expected to be the project root when vitest is
 * invoked via `npm test` (the standard invocation pattern). Tests will fail
 * if vitest is run from a different working directory.
 */
describe("CLAUDE.md session logging requirement", () => {
  const claudeMd = readFileSync(resolve(process.cwd(), "CLAUDE.md"), "utf-8");

  it("contains a Session Logging section", () => {
    expect(claudeMd).toContain("### Session Logging");
  });

  it("mentions SESSION_LOG.md as a required file", () => {
    expect(claudeMd).toContain("SESSION_LOG.md");
  });

  it("explains that session logging is required, not optional", () => {
    expect(claudeMd).toContain("required");
  });

  it("references the automatic worker log path", () => {
    expect(claudeMd).toContain("~/.foreman/logs/");
  });

  it("provides a SESSION_LOG.md format with Metadata section", () => {
    expect(claudeMd).toContain("## Metadata");
  });

  it("provides a SESSION_LOG.md format with Key Activities section", () => {
    expect(claudeMd).toContain("## Key Activities");
  });

  it("provides a SESSION_LOG.md format with Artifacts Created section", () => {
    expect(claudeMd).toContain("## Artifacts Created");
  });

  it("session logging section appears after Session Protocol section", () => {
    const protocolIdx = claudeMd.indexOf("### Session Protocol");
    const loggingIdx = claudeMd.indexOf("### Session Logging");
    expect(protocolIdx).toBeGreaterThan(-1);
    expect(loggingIdx).toBeGreaterThan(-1);
    expect(loggingIdx).toBeGreaterThan(protocolIdx);
  });
});
