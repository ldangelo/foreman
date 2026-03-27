/**
 * TRD-032 & TRD-032-TEST: ConflictResolver jj conflict marker adaptation.
 *
 * Verifies:
 * - ConflictResolver.setVcsBackend() configures the backend
 * - ConflictResolver.hasConflictMarkers() detects both git and jj markers
 * - AI prompt (Tier 3) is backend-aware: describes jj markers for jujutsu backend
 * - Backward compatibility: git markers still detected when backend=git
 * - MergeValidator.conflictMarkerCheck() detects jj markers in resolved content
 *
 * @see TRD-2026-004-vcs-backend-abstraction.md §6.4
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import * as os from "node:os";
import {
  ConflictResolver,
  type Tier3Result,
} from "../conflict-resolver.js";
import { MergeValidator } from "../merge-validator.js";
import { DEFAULT_MERGE_CONFIG } from "../merge-config.js";

// ── Mock pi-runner ────────────────────────────────────────────────────────

vi.mock("../pi-sdk-runner.js", () => ({
  runWithPiSdk: vi.fn(),
}));

import { runWithPiSdk } from "../pi-sdk-runner.js";
const mockRunWithPi = vi.mocked(runWithPiSdk);

// Clear mock call history between tests
afterEach(() => {
  vi.clearAllMocks();
});

// ── Conflict content fixtures ──────────────────────────────────────────────

/** Git-style conflict markers */
const GIT_CONFLICT_FILE = [
  "const a = 1;",
  "<<<<<<< HEAD",
  "const b = 'main';",
  "=======",
  "const b = 'feature';",
  ">>>>>>> feature/branch",
  "const c = 3;",
  "",
].join("\n");

/** Jujutsu diff-style conflict markers (format 2) */
const JJ_DIFF_CONFLICT_FILE = [
  "const a = 1;",
  "<<<<<<< Conflict 1 of 1",
  "%%%%%%% Changes from base to side #1",
  "-const b = 'original';",
  "+const b = 'side1';",
  "+++++++ Contents of side #2",
  "const b = 'side2';",
  ">>>>>>>",
  "const c = 3;",
  "",
].join("\n");

/** A clean file (no markers) */
const CLEAN_FILE = [
  "const a = 1;",
  "const b = 'merged';",
  "const c = 3;",
  "",
].join("\n");

// ── Helper ────────────────────────────────────────────────────────────────

function makeSuccessPiResult(cwd: string, filePath: string, content: string, costUsd = 0.006) {
  mockRunWithPi.mockImplementation(async (opts) => {
    const fullPath = path.join(opts.cwd, filePath);
    await fs.mkdir(path.dirname(fullPath), { recursive: true });
    await fs.writeFile(fullPath, content, "utf-8");
    return {
      success: true,
      costUsd,
      turns: 2,
      toolCalls: 3,
      toolBreakdown: { Read: 1, Write: 2 },
      tokensIn: 1000,
      tokensOut: 500,
    };
  });
}

// ── setVcsBackend / getVcsBackend ─────────────────────────────────────────

describe("TRD-032: ConflictResolver.setVcsBackend", () => {
  it("defaults to 'git'", () => {
    const resolver = new ConflictResolver("/tmp", DEFAULT_MERGE_CONFIG);
    expect(resolver.getVcsBackend()).toBe("git");
  });

  it("setVcsBackend('jujutsu') changes the backend", () => {
    const resolver = new ConflictResolver("/tmp", DEFAULT_MERGE_CONFIG);
    resolver.setVcsBackend("jujutsu");
    expect(resolver.getVcsBackend()).toBe("jujutsu");
  });

  it("setVcsBackend('git') restores git backend", () => {
    const resolver = new ConflictResolver("/tmp", DEFAULT_MERGE_CONFIG);
    resolver.setVcsBackend("jujutsu");
    resolver.setVcsBackend("git");
    expect(resolver.getVcsBackend()).toBe("git");
  });
});

// ── hasConflictMarkers ────────────────────────────────────────────────────

describe("TRD-032: ConflictResolver.hasConflictMarkers", () => {
  it("detects git-style conflict markers (<<<<<<<, =======, >>>>>>>)", () => {
    const resolver = new ConflictResolver("/tmp", DEFAULT_MERGE_CONFIG);
    expect(resolver.hasConflictMarkers(GIT_CONFLICT_FILE)).toBe(true);
  });

  it("detects jj diff-style markers (<<<<<<<, %%%%%%%, +++++++)", () => {
    const resolver = new ConflictResolver("/tmp", DEFAULT_MERGE_CONFIG);
    expect(resolver.hasConflictMarkers(JJ_DIFF_CONFLICT_FILE)).toBe(true);
  });

  it("returns false for clean content (no markers)", () => {
    const resolver = new ConflictResolver("/tmp", DEFAULT_MERGE_CONFIG);
    expect(resolver.hasConflictMarkers(CLEAN_FILE)).toBe(false);
  });

  it("detects <<<<<<< alone as a conflict marker", () => {
    const resolver = new ConflictResolver("/tmp", DEFAULT_MERGE_CONFIG);
    const content = "line1\n<<<<<<< HEAD\nline3\n";
    expect(resolver.hasConflictMarkers(content)).toBe(true);
  });

  it("detects %%%%%%% alone as a jj conflict marker", () => {
    const resolver = new ConflictResolver("/tmp", DEFAULT_MERGE_CONFIG);
    const content = "line1\n%%%%%%%\nline3\n";
    expect(resolver.hasConflictMarkers(content)).toBe(true);
  });

  it("detects +++++++ alone as a jj conflict marker", () => {
    const resolver = new ConflictResolver("/tmp", DEFAULT_MERGE_CONFIG);
    const content = "line1\n+++++++\nline3\n";
    expect(resolver.hasConflictMarkers(content)).toBe(true);
  });

  it("does not detect partial marker strings as conflicts", () => {
    const resolver = new ConflictResolver("/tmp", DEFAULT_MERGE_CONFIG);
    // <6 characters — should not match 7-char marker
    const content = "// <<<<<< only 6 lt signs\n// normal code";
    expect(resolver.hasConflictMarkers(content)).toBe(false);
  });

  it("works the same regardless of backend setting (markers are always detected)", () => {
    const gitResolver = new ConflictResolver("/tmp", DEFAULT_MERGE_CONFIG);
    gitResolver.setVcsBackend("git");

    const jjResolver = new ConflictResolver("/tmp", DEFAULT_MERGE_CONFIG);
    jjResolver.setVcsBackend("jujutsu");

    // Both should detect jj markers
    expect(gitResolver.hasConflictMarkers(JJ_DIFF_CONFLICT_FILE)).toBe(true);
    expect(jjResolver.hasConflictMarkers(JJ_DIFF_CONFLICT_FILE)).toBe(true);

    // Both should detect git markers
    expect(gitResolver.hasConflictMarkers(GIT_CONFLICT_FILE)).toBe(true);
    expect(jjResolver.hasConflictMarkers(GIT_CONFLICT_FILE)).toBe(true);
  });
});

// ── Tier 3 AI prompt: backend-aware ──────────────────────────────────────

describe("TRD-032: Tier 3 AI prompt is backend-aware", () => {
  let tmpDir: string;

  beforeEach(async () => {
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "foreman-jj-t3-"));
  });

  it("git backend: prompt describes git conflict markers", async () => {
    const resolver = new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG);
    resolver.setVcsBackend("git");

    makeSuccessPiResult(tmpDir, "src/file.ts", CLEAN_FILE);

    await resolver.attemptTier3Resolution("src/file.ts", GIT_CONFLICT_FILE);

    expect(mockRunWithPi).toHaveBeenCalledOnce();
    const { prompt } = mockRunWithPi.mock.calls[0][0];

    // Should describe git markers
    expect(prompt).toContain("git merge conflict");
    expect(prompt).toContain("<<<<<<< HEAD");
    expect(prompt).toContain("=======");
    expect(prompt).toContain(">>>>>>>");

    // Should NOT describe jj markers in git mode
    expect(prompt).not.toContain("Jujutsu");
    expect(prompt).not.toContain("%%%%%%%");
  });

  it("jujutsu backend: prompt describes jj conflict markers", async () => {
    const resolver = new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG);
    resolver.setVcsBackend("jujutsu");

    makeSuccessPiResult(tmpDir, "src/file.ts", CLEAN_FILE);

    await resolver.attemptTier3Resolution("src/file.ts", JJ_DIFF_CONFLICT_FILE);

    expect(mockRunWithPi).toHaveBeenCalledOnce();
    const { prompt } = mockRunWithPi.mock.calls[0][0];

    // Should describe jj markers
    expect(prompt).toContain("Jujutsu");
    expect(prompt).toContain("%%%%%%%");
    expect(prompt).toContain("+++++++");

    // Should mention that git markers may also appear in colocated repos
    expect(prompt).toContain("<<<<<<");
    expect(prompt).toContain(">>>>>>>");
  });

  it("jujutsu backend prompt includes instructions to remove all marker types", async () => {
    const resolver = new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG);
    resolver.setVcsBackend("jujutsu");

    makeSuccessPiResult(tmpDir, "src/file.ts", CLEAN_FILE);

    await resolver.attemptTier3Resolution("src/file.ts", JJ_DIFF_CONFLICT_FILE);

    const { prompt } = mockRunWithPi.mock.calls[0][0];
    expect(prompt).toContain("<<<<<<<");
    expect(prompt).toContain("%%%%%%%");
    expect(prompt).toContain(">>>>>>>");
    expect(prompt).toContain("+++++++");
    expect(prompt).toContain("-------");
  });
});

// ── MergeValidator: jj marker detection ──────────────────────────────────

describe("TRD-032: MergeValidator.conflictMarkerCheck handles jj markers", () => {
  it("detects git-style conflict markers in resolved content", () => {
    const validator = new MergeValidator(DEFAULT_MERGE_CONFIG);

    // Should detect residual git markers
    expect(validator.conflictMarkerCheck(GIT_CONFLICT_FILE)).toBe(true);
  });

  it("detects jj diff-style markers in resolved content", () => {
    const validator = new MergeValidator(DEFAULT_MERGE_CONFIG);

    expect(validator.conflictMarkerCheck(JJ_DIFF_CONFLICT_FILE)).toBe(true);
  });

  it("returns false for clean content (backward compat)", () => {
    const validator = new MergeValidator(DEFAULT_MERGE_CONFIG);

    expect(validator.conflictMarkerCheck(CLEAN_FILE)).toBe(false);
  });

  it("detects %%%%%%% as jj marker", () => {
    const validator = new MergeValidator(DEFAULT_MERGE_CONFIG);
    const content = "line1\n%%%%%%%\nline2\n";
    expect(validator.conflictMarkerCheck(content)).toBe(true);
  });

  it("detects +++++++ as jj marker", () => {
    const validator = new MergeValidator(DEFAULT_MERGE_CONFIG);
    const content = "line1\n+++++++\nline2\n";
    expect(validator.conflictMarkerCheck(content)).toBe(true);
  });

  it("does not detect short sequences as markers", () => {
    const validator = new MergeValidator(DEFAULT_MERGE_CONFIG);
    // Exactly 6 chars — below 7 threshold
    const content = "const x = '<<<<<<'; // 6 lt\n";
    expect(validator.conflictMarkerCheck(content)).toBe(false);
  });
});

// ── Backward compatibility ─────────────────────────────────────────────────

describe("TRD-032: Backward compatibility — git conflict resolution unchanged", () => {
  let tmpDir: string;

  beforeEach(async () => {
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "foreman-jj-compat-"));
  });

  it("existing git Tier 3 behavior is preserved when no setVcsBackend called", async () => {
    const resolver = new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG);
    // Default: no setVcsBackend() call

    makeSuccessPiResult(tmpDir, "src/compat.ts", CLEAN_FILE);

    const result = await resolver.attemptTier3Resolution("src/compat.ts", GIT_CONFLICT_FILE);

    expect(result.success).toBe(true);
    expect(mockRunWithPi).toHaveBeenCalledOnce();
    const { prompt } = mockRunWithPi.mock.calls[0][0];
    expect(prompt).toContain("git merge conflict");
  });

  it("ConflictResolver can be constructed without setVcsBackend and works correctly", () => {
    const resolver = new ConflictResolver("/tmp", DEFAULT_MERGE_CONFIG);

    // These should not throw
    expect(resolver.getVcsBackend()).toBe("git");
    expect(resolver.hasConflictMarkers(GIT_CONFLICT_FILE)).toBe(true);
    expect(resolver.hasConflictMarkers(CLEAN_FILE)).toBe(false);
  });
});
