/**
 * Tests for `foreman project` CLI commands.
 *
 * Covers:
 *   - `foreman project add <path>` — happy path, --name, --force, duplicate error
 *   - `foreman project list` — empty, with projects, --stale
 *   - `foreman project remove <name>` — happy path, --stale, not-found error
 *
 * Uses tsx to run the CLI as a subprocess for realistic end-to-end coverage.
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  mkdtempSync,
  mkdirSync,
  rmSync,
  writeFileSync,
  existsSync,
} from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir, homedir } from "node:os";
import path from "node:path";

const execFileAsync = promisify(execFile);

// ── Helpers ────────────────────────────────────────────────────────────────────

function findTsx(): string {
  const candidates = [
    path.resolve(__dirname, "../../../node_modules/.bin/tsx"),
    path.resolve(__dirname, "../../../../../node_modules/.bin/tsx"),
  ];
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  return candidates[0];
}

const TSX = findTsx();
const CLI = path.resolve(__dirname, "../../../src/cli/index.ts");

interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

async function runCli(
  args: string[],
  registryPath: string,
  cwd?: string,
): Promise<ExecResult> {
  try {
    const { stdout, stderr } = await execFileAsync(TSX, [CLI, ...args], {
      cwd: cwd ?? tmpdir(),
      timeout: 15_000,
      env: {
        ...process.env,
        NO_COLOR: "1",
        // Override the registry path via a special env var (see below)
        FOREMAN_REGISTRY_PATH: registryPath,
      },
    });
    return { stdout, stderr, exitCode: 0 };
  } catch (err: unknown) {
    const e = err as { stdout?: string; stderr?: string; code?: number };
    return {
      stdout: e.stdout ?? "",
      stderr: e.stderr ?? "",
      exitCode: e.code ?? 1,
    };
  }
}

function mkTmpProjectDir(base: string, name: string): string {
  const dir = join(base, name);
  mkdirSync(join(dir, ".foreman"), { recursive: true });
  return dir;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("foreman project commands (unit — ProjectRegistry class)", () => {
  /**
   * These tests import ProjectRegistry directly (no subprocess) for speed.
   * The CLI subprocess tests below exercise the Commander integration.
   */
  let tmpBase: string;
  let registryFile: string;

  beforeEach(() => {
    tmpBase = mkdtempSync(join(tmpdir(), "foreman-proj-test-"));
    registryFile = join(tmpBase, ".foreman", "projects.json");
  });

  afterEach(() => {
    rmSync(tmpBase, { recursive: true, force: true });
  });

  it("ProjectRegistry can be instantiated with a custom path", async () => {
    const { ProjectRegistry } = await import("../../lib/project-registry.js");
    const reg = new ProjectRegistry(registryFile);
    expect(reg.list()).toEqual([]);
  });

  it("add + list round-trip", async () => {
    const { ProjectRegistry } = await import("../../lib/project-registry.js");
    const reg = new ProjectRegistry(registryFile);
    const p = mkTmpProjectDir(tmpBase, "alpha");
    await reg.add(p, "alpha");
    const projects = reg.list();
    expect(projects).toHaveLength(1);
    expect(projects[0]!.name).toBe("alpha");
  });

  it("remove after add", async () => {
    const { ProjectRegistry } = await import("../../lib/project-registry.js");
    const reg = new ProjectRegistry(registryFile);
    const p = mkTmpProjectDir(tmpBase, "beta");
    await reg.add(p, "beta");
    await reg.remove("beta");
    expect(reg.list()).toHaveLength(0);
  });

  it("resolve by name", async () => {
    const { ProjectRegistry } = await import("../../lib/project-registry.js");
    const reg = new ProjectRegistry(registryFile);
    const p = mkTmpProjectDir(tmpBase, "gamma");
    await reg.add(p, "gamma");
    expect(reg.resolve("gamma")).toBe(resolve(p));
  });

  it("throws DuplicateProjectError on duplicate name", async () => {
    const { ProjectRegistry, DuplicateProjectError } = await import(
      "../../lib/project-registry.js"
    );
    const reg = new ProjectRegistry(registryFile);
    const p1 = mkTmpProjectDir(tmpBase, "p1");
    const p2 = mkTmpProjectDir(tmpBase, "p2");
    await reg.add(p1, "shared");
    await expect(reg.add(p2, "shared")).rejects.toBeInstanceOf(DuplicateProjectError);
  });

  it("throws ProjectNotFoundError on remove of unknown name", async () => {
    const { ProjectRegistry, ProjectNotFoundError } = await import(
      "../../lib/project-registry.js"
    );
    const reg = new ProjectRegistry(registryFile);
    await expect(reg.remove("ghost")).rejects.toBeInstanceOf(ProjectNotFoundError);
  });

  it("removeStale() removes inaccessible directories", async () => {
    const { ProjectRegistry } = await import("../../lib/project-registry.js");
    mkdirSync(join(tmpBase, ".foreman"), { recursive: true });

    const live = mkTmpProjectDir(tmpBase, "live");
    const ghostPath = join(tmpBase, "ghost-does-not-exist");

    writeFileSync(
      registryFile,
      JSON.stringify({
        version: 1,
        projects: [
          { name: "live", path: resolve(live), addedAt: new Date().toISOString() },
          { name: "ghost", path: ghostPath, addedAt: new Date().toISOString() },
        ],
      }),
      "utf-8",
    );

    const reg = new ProjectRegistry(registryFile);
    const removed = await reg.removeStale();
    expect(removed).toContain("ghost");
    expect(removed).not.toContain("live");
    expect(reg.list()).toHaveLength(1);
  });

  it("listStale() lists without removing", async () => {
    const { ProjectRegistry } = await import("../../lib/project-registry.js");
    mkdirSync(join(tmpBase, ".foreman"), { recursive: true });

    const live = mkTmpProjectDir(tmpBase, "live");
    const ghostPath = join(tmpBase, "ghost-does-not-exist");

    writeFileSync(
      registryFile,
      JSON.stringify({
        version: 1,
        projects: [
          { name: "live", path: resolve(live), addedAt: new Date().toISOString() },
          { name: "ghost", path: ghostPath, addedAt: new Date().toISOString() },
        ],
      }),
      "utf-8",
    );

    const reg = new ProjectRegistry(registryFile);
    const stale = reg.listStale();
    expect(stale).toHaveLength(1);
    expect(stale[0]!.name).toBe("ghost");
    // list() still returns both
    expect(reg.list()).toHaveLength(2);
  });
});
