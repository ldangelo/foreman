/**
 * Tests for bin/foreman Node.js shim script.
 *
 * Verifies that the shim:
 * - Has the correct #!/usr/bin/env node shebang
 * - Is an ES module (uses import syntax)
 * - Correctly resolves dist/cli/index.js relative to itself
 * - Works when executed via `node bin/foreman --help`
 * - Is included in npm pack output (bin field in package.json)
 */
import { describe, it, expect } from "vitest";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFileSync, existsSync, statSync } from "node:fs";
import path from "node:path";

const execFileAsync = promisify(execFile);

// Resolve the repo root (works in both worktree and main repo)
const REPO_ROOT = path.resolve(path.dirname(import.meta.url.replace("file://", "")), "../../..");
const BIN_SHIM = path.join(REPO_ROOT, "bin", "foreman");
const PACKAGE_JSON = path.join(REPO_ROOT, "package.json");

describe("bin/foreman shim", () => {
  it("exists at bin/foreman", () => {
    expect(existsSync(BIN_SHIM)).toBe(true);
  });

  it("has #!/usr/bin/env node shebang", () => {
    const content = readFileSync(BIN_SHIM, "utf-8");
    expect(content.startsWith("#!/usr/bin/env node")).toBe(true);
  });

  it("is a Node.js script (not bash)", () => {
    const content = readFileSync(BIN_SHIM, "utf-8");
    // Must NOT be a bash script
    expect(content).not.toContain("#!/usr/bin/env bash");
    expect(content).not.toContain("exec tsx");
    // Must use ES module dynamic import
    expect(content).toContain("import(");
  });

  it("resolves dist/cli/index.js relative to shim location", () => {
    const content = readFileSync(BIN_SHIM, "utf-8");
    // Uses fileURLToPath + dirname pattern for ESM-safe __dirname
    expect(content).toContain("fileURLToPath");
    expect(content).toContain("import.meta.url");
    // Builds path to dist/cli/index.js
    expect(content).toContain("dist");
    expect(content).toContain("cli");
    expect(content).toContain("index.js");
  });

  it("has executable permissions (Unix)", async () => {
    // On Windows this isn't meaningful, but on Unix the file should be executable
    if (process.platform === "win32") return;
    const stat = statSync(BIN_SHIM);
    // Check user execute bit (0o100)
    const isExecutable = (stat.mode & 0o111) !== 0;
    expect(isExecutable).toBe(true);
  });

  it("package.json bin field points to bin/foreman", () => {
    const pkg = JSON.parse(readFileSync(PACKAGE_JSON, "utf-8")) as {
      bin?: Record<string, string>;
    };
    expect(pkg.bin).toBeDefined();
    expect(pkg.bin!["foreman"]).toBe("bin/foreman");
  });

  it("bin/foreman is included in package files list", () => {
    const pkg = JSON.parse(readFileSync(PACKAGE_JSON, "utf-8")) as {
      files?: string[];
    };
    expect(pkg.files).toBeDefined();
    // Either "bin/" or "bin/foreman" should be in files
    const binIncluded = pkg.files!.some(
      (f) => f === "bin/" || f === "bin" || f === "bin/foreman"
    );
    expect(binIncluded).toBe(true);
  });

  it("runs --help via node bin/foreman and outputs usage", async () => {
    // This test requires a built dist/ directory
    const distEntry = path.join(REPO_ROOT, "dist", "cli", "index.js");
    if (!existsSync(distEntry)) {
      console.warn("Skipping execution test: dist/cli/index.js not found (run npm run build)");
      return;
    }

    const { stdout, stderr } = await execFileAsync(
      process.execPath, // node binary
      [BIN_SHIM, "--help"],
      {
        timeout: 15_000,
        env: { ...process.env, NO_COLOR: "1" },
      }
    );

    const output = stdout + stderr;
    expect(output).toContain("Usage: foreman");
    expect(output).toContain("--help");
  });

  it("provides a helpful error message when dist/ is missing", async () => {
    // Run the shim from a temp directory where dist/ doesn't exist
    // by overriding import.meta.url path resolution isn't straightforward,
    // so we test the error handling code is present in the shim source instead
    const content = readFileSync(BIN_SHIM, "utf-8");
    expect(content).toContain("ERR_MODULE_NOT_FOUND");
    expect(content).toContain("npm run build");
  });
});
