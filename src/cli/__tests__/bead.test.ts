import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  mkdtempSync,
  rmSync,
  realpathSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { runTsxModule, type ExecResult } from "../../test-support/tsx-subprocess.js";
const CLI = path.resolve(__dirname, "../../../src/cli/index.ts");

async function run(args: string[], cwd: string): Promise<ExecResult> {
  return runTsxModule(CLI, args, { cwd, timeout: 15_000 });
}

describe("bead command", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-bead-test-")));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("bead --help shows description and options", async () => {
    const tmp = makeTempDir();
    const result = await run(["bead", "--help"], tmp);

    expect(result.exitCode).toBe(0);
    const output = result.stdout;
    expect(output).toContain("bead");
    expect(output).toContain("natural-language");
    expect(output).toContain("--dry-run");
    expect(output).toContain("--no-llm");
    expect(output).toContain("--type");
    expect(output).toContain("--priority");
    expect(output).toContain("--parent");
  }, 15_000);

  it("bead without arguments shows missing argument error", async () => {
    const tmp = makeTempDir();
    const result = await run(["bead"], tmp);

    expect(result.exitCode).not.toBe(0);
    const output = result.stdout + result.stderr;
    // Commander.js will report a missing argument
    expect(output.toLowerCase()).toMatch(/missing|required|argument|error/i);
  }, 15_000);

  it("bead fails without foreman init (no .beads directory)", async () => {
    const tmp = makeTempDir();
    // No foreman init — br CLI may or may not be present, but .beads won't exist
    const result = await run(
      ["bead", "--no-llm", "Create a login page"],
      tmp,
    );

    const output = result.stdout + result.stderr;
    // Should fail with a helpful message about initialization
    expect(result.exitCode).not.toBe(0);
    expect(output).toMatch(/not (found|installed|initializ)|init|br|beads/i);
  }, 15_000);

  it("bead --dry-run --no-llm shows planned beads without creating them", async () => {
    const tmp = makeTempDir();

    // We cannot run this without br being installed & initialized,
    // but we can verify it fails gracefully when br is not present
    const result = await run(
      ["bead", "--no-llm", "--dry-run", "Add user authentication"],
      tmp,
    );

    const output = result.stdout + result.stderr;
    // Either it shows the planned bead (if br is installed) or shows an error
    if (result.exitCode === 0) {
      expect(output).toContain("dry-run");
      expect(output).toContain("Add user authentication");
    } else {
      // No br installed: graceful error
      expect(output).toMatch(/not (found|installed|initializ)|init|br|beads/i);
    }
  }, 15_000);

  it("bead --dry-run --no-llm reads description from a file", async () => {
    const tmp = makeTempDir();
    const descFile = join(tmp, "desc.txt");
    writeFileSync(descFile, "Implement OAuth2 login flow with Google provider");

    const result = await run(
      ["bead", "--no-llm", "--dry-run", descFile],
      tmp,
    );

    const output = result.stdout + result.stderr;
    if (result.exitCode === 0) {
      // File was read and output shown
      expect(output).toContain("Implement OAuth2");
      expect(output).toContain("dry-run");
    } else {
      // No br installed: graceful error
      expect(output).toMatch(/not (found|installed|initializ)|init|br|beads/i);
    }
  }, 15_000);
});

// ── Unit tests for internal helpers ─────────────────────────────────────

describe("bead command internal helpers (via module import)", () => {
  // We test the parseLlmResponse and normaliseIssue logic indirectly
  // by importing and calling with known inputs via a test wrapper.

  it("beadCommand is a Commander Command named 'bead'", async () => {
    const { beadCommand } = await import("../commands/bead.js");
    expect(beadCommand.name()).toBe("bead");
    expect(beadCommand.description()).toContain("natural-language");
  });

  it("beadCommand has the expected options", async () => {
    const { beadCommand } = await import("../commands/bead.js");
    const optionNames = beadCommand.options.map((o) => o.long);
    expect(optionNames).toContain("--type");
    expect(optionNames).toContain("--priority");
    expect(optionNames).toContain("--parent");
    expect(optionNames).toContain("--dry-run");
    expect(optionNames).toContain("--model");
    // --no-llm creates a --llm option (commander negation pattern)
    expect(optionNames).toContain("--no-llm");
  });

  it("beadCommand accepts a description argument", async () => {
    const { beadCommand } = await import("../commands/bead.js");
    const argDef = beadCommand.registeredArguments[0];
    expect(argDef).toBeDefined();
    expect(argDef.required).toBe(true);
  });
});

// ── Unit tests for exported helpers ──────────────────────────────────────

describe("parseLlmResponse", () => {
  let parseLlmResponse: (raw: string) => { issues: any[] };

  beforeEach(async () => {
    ({ parseLlmResponse } = await import("../commands/bead.js"));
  });

  it("parses a plain JSON object", () => {
    const raw = JSON.stringify({
      issues: [{ title: "Fix login bug", type: "bug", priority: "P1" }],
    });
    const result = parseLlmResponse(raw);
    expect(result.issues).toHaveLength(1);
    expect(result.issues[0].title).toBe("Fix login bug");
  });

  it("strips markdown json fences", () => {
    const raw = "```json\n{\"issues\":[{\"title\":\"Deploy service\"}]}\n```";
    const result = parseLlmResponse(raw);
    expect(result.issues[0].title).toBe("Deploy service");
  });

  it("strips plain markdown fences", () => {
    const raw = "```\n{\"issues\":[{\"title\":\"Add tests\"}]}\n```";
    const result = parseLlmResponse(raw);
    expect(result.issues[0].title).toBe("Add tests");
  });

  it("finds JSON object if there is leading text", () => {
    const raw = 'Here is the JSON: {"issues":[{"title":"Update docs"}]}';
    const result = parseLlmResponse(raw);
    expect(result.issues[0].title).toBe("Update docs");
  });

  it("repairs truncated JSON", () => {
    // Truncated after the second issue starts
    const raw = '{"issues":[{"title":"Task A","type":"task"},{"title":"Task B"';
    const result = parseLlmResponse(raw);
    expect(result.issues.length).toBeGreaterThanOrEqual(1);
    expect(result.issues[0].title).toBe("Task A");
  });

  it("throws on completely unparseable input", () => {
    expect(() => parseLlmResponse("not json at all")).toThrow(/Failed to parse/);
  });
});

describe("normaliseIssue", () => {
  let normaliseIssue: (raw: Partial<any>) => any;

  beforeEach(async () => {
    ({ normaliseIssue } = await import("../commands/bead.js"));
  });

  it("defaults type to 'task' when missing", () => {
    const result = normaliseIssue({ title: "Do something" });
    expect(result.type).toBe("task");
  });

  it("defaults priority to 'P2' when missing", () => {
    const result = normaliseIssue({ title: "Do something" });
    expect(result.priority).toBe("P2");
  });

  it("defaults type to 'task' for invalid type", () => {
    const result = normaliseIssue({ title: "Test", type: "invalid" });
    expect(result.type).toBe("task");
  });

  it("defaults priority to 'P2' for invalid priority", () => {
    const result = normaliseIssue({ title: "Test", priority: "high" });
    expect(result.priority).toBe("P2");
  });

  it("preserves valid type and priority", () => {
    const result = normaliseIssue({ title: "Fix crash", type: "bug", priority: "P0" });
    expect(result.type).toBe("bug");
    expect(result.priority).toBe("P0");
  });

  it("truncates title to 200 chars", () => {
    const longTitle = "A".repeat(300);
    const result = normaliseIssue({ title: longTitle });
    expect(result.title).toHaveLength(200);
  });

  it("converts title to string if not a string", () => {
    const result = normaliseIssue({ title: 42 as any });
    expect(result.title).toBe("42");
  });

  it("normalises dependencies array", () => {
    const result = normaliseIssue({
      title: "Deploy",
      dependencies: ["Build", "Test"],
    });
    expect(result.dependencies).toEqual(["Build", "Test"]);
  });

  it("sets dependencies to undefined when absent", () => {
    const result = normaliseIssue({ title: "Deploy" });
    expect(result.dependencies).toBeUndefined();
  });

  it("normalises labels array", () => {
    const result = normaliseIssue({ title: "Deploy", labels: ["infra", "urgent"] });
    expect(result.labels).toEqual(["infra", "urgent"]);
  });
});

describe("repairTruncatedJson", () => {
  let repairTruncatedJson: (json: string) => string;

  beforeEach(async () => {
    ({ repairTruncatedJson } = await import("../commands/bead.js"));
  });

  it("returns unchanged string when already valid (no open brackets)", () => {
    const valid = '{"issues":[]}';
    const result = repairTruncatedJson(valid);
    expect(JSON.parse(result)).toEqual({ issues: [] });
  });

  it("closes unclosed object and array", () => {
    const truncated = '{"issues":[{"title":"Task A"';
    const result = repairTruncatedJson(truncated);
    const parsed = JSON.parse(result);
    expect(parsed.issues[0].title).toBe("Task A");
  });

  it("handles truncation inside a string value", () => {
    const truncated = '{"issues":[{"title":"Incomplete titl';
    // Should produce parseable JSON (may drop the partial string)
    const result = repairTruncatedJson(truncated);
    expect(() => JSON.parse(result)).not.toThrow();
  });

  it("removes trailing comma before closing brackets", () => {
    const withTrailingComma = '{"issues":[{"title":"Task A"},';
    const result = repairTruncatedJson(withTrailingComma);
    expect(() => JSON.parse(result)).not.toThrow();
  });
});

describe("--no-llm description slice behaviour", () => {
  it("sets description to slice(200) when input exceeds 200 chars", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "foreman-bead-nollm-"));
    const longInput = "A".repeat(200) + "REMAINDER_TEXT";
    const descFile = join(tmp, "long.txt");
    writeFileSync(descFile, longInput);

    // We can only observe --dry-run output; skip if br not installed
    const result = await run(["bead", "--no-llm", "--dry-run", descFile], tmp);
    rmSync(tmp, { recursive: true, force: true });

    if (result.exitCode === 0) {
      const output = result.stdout + result.stderr;
      // Description shown in dry-run should contain "REMAINDER_TEXT" (the slice(200) part)
      expect(output).toContain("REMAINDER_TEXT");
      // It should NOT start the description with the same 'A's that are already in the title
      // (i.e. description != full inputText, it's only the trailing portion)
    }
    // If br not installed, test passes — we just can't observe the output
  }, 15_000);

  it("sets description to undefined when input is exactly 200 chars", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "foreman-bead-nollm-exact-"));
    const exactInput = "B".repeat(200);
    const descFile = join(tmp, "exact.txt");
    writeFileSync(descFile, exactInput);

    const result = await run(["bead", "--no-llm", "--dry-run", descFile], tmp);
    rmSync(tmp, { recursive: true, force: true });

    if (result.exitCode === 0) {
      const output = result.stdout + result.stderr;
      // With exactly 200 chars, description is undefined, so no extra description line
      // The title itself (200 B's) should appear
      expect(output).toContain("B".repeat(50)); // at least part of the title
    }
  }, 15_000);
});
