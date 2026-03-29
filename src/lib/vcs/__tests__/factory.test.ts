/**
 * Tests for VcsBackendFactory.
 *
 * Tests the factory's ability to create backends from configs and env vars,
 * and its auto-detection logic.
 *
 * Covers: AC-T-003-1 through AC-T-003-5
 */

import { describe, it, expect, afterEach } from "vitest";
import {
  mkdtempSync,
  mkdirSync,
  rmSync,
  realpathSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { VcsBackendFactory, GitBackend, JujutsuBackend } from "../index.js";

const tempDirs: string[] = [];

function makeTempDir(prefix: string): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  for (const d of tempDirs) {
    rmSync(d, { recursive: true, force: true });
  }
  tempDirs.length = 0;
});

// ── resolveBackend ────────────────────────────────────────────────────────────

describe("VcsBackendFactory.resolveBackend", () => {
  it("returns 'git' for explicit git config", () => {
    expect(VcsBackendFactory.resolveBackend({ backend: 'git' }, '/tmp')).toBe('git');
  });

  it("returns 'jujutsu' for explicit jujutsu config", () => {
    expect(VcsBackendFactory.resolveBackend({ backend: 'jujutsu' }, '/tmp')).toBe('jujutsu');
  });

  // AC-T-003-1: Given a temp directory with .git/, auto-detect returns 'git'
  it("auto-detects 'git' when .git directory exists (AC-T-003-1)", () => {
    const dir = makeTempDir("foreman-factory-git-");
    mkdirSync(join(dir, '.git'));
    expect(VcsBackendFactory.resolveBackend({ backend: 'auto' }, dir)).toBe('git');
  });

  // AC-T-003-2: Given a temp directory with .jj/ and .git/, .jj takes precedence
  it("auto-detects 'jujutsu' when .jj directory exists (takes precedence over .git)", () => {
    const dir = makeTempDir("foreman-factory-jj-");
    mkdirSync(join(dir, '.jj'));
    mkdirSync(join(dir, '.git'));
    expect(VcsBackendFactory.resolveBackend({ backend: 'auto' }, dir)).toBe('jujutsu');
  });

  // AC-T-003-3: Given a temp directory with neither .git/ nor .jj/, an error is thrown
  it("throws an error when auto-detection finds neither .git nor .jj (AC-T-003-3)", () => {
    const dir = makeTempDir("foreman-factory-neither-");
    expect(() =>
      VcsBackendFactory.resolveBackend({ backend: 'auto' }, dir)
    ).toThrow(/auto-detection failed/);
    expect(() =>
      VcsBackendFactory.resolveBackend({ backend: 'auto' }, dir)
    ).toThrow(dir);
  });

  // AC-T-003-5: Given backend='invalid' as any, a descriptive error is thrown
  it("throws a descriptive error for invalid backend value (AC-T-003-5)", () => {
    expect(() =>
      VcsBackendFactory.resolveBackend({ backend: 'invalid' as never }, '/tmp')
    ).toThrow(/unrecognized backend/);
    expect(() =>
      VcsBackendFactory.resolveBackend({ backend: 'invalid' as never }, '/tmp')
    ).toThrow(/invalid/);
    expect(() =>
      VcsBackendFactory.resolveBackend({ backend: 'invalid' as never }, '/tmp')
    ).toThrow(/git.*jujutsu.*auto/i);
  });
});

// ── create (async) ────────────────────────────────────────────────────────────

describe("VcsBackendFactory.create", () => {
  // AC-T-003-4: Explicit backend selection — GitBackend regardless of directory contents
  it("creates GitBackend for backend='git' regardless of directory contents (AC-T-003-4)", async () => {
    const dir = makeTempDir("foreman-factory-explicit-git-");
    // Intentionally no .git/ — explicit selection should ignore directory state
    const b = await VcsBackendFactory.create({ backend: 'git' }, dir);
    expect(b).toBeInstanceOf(GitBackend);
    expect(b.name).toBe('git');
  });

  it("creates JujutsuBackend for backend='jujutsu'", async () => {
    const b = await VcsBackendFactory.create({ backend: 'jujutsu' }, '/tmp');
    expect(b).toBeInstanceOf(JujutsuBackend);
    expect(b.name).toBe('jujutsu');
  });

  // AC-T-003-1: Given a temp dir with .git/, create({backend:'auto'}) returns GitBackend
  it("creates GitBackend when auto and .git dir exists (AC-T-003-1)", async () => {
    const dir = makeTempDir("foreman-factory-auto-git-");
    mkdirSync(join(dir, '.git'));
    const b = await VcsBackendFactory.create({ backend: 'auto' }, dir);
    expect(b).toBeInstanceOf(GitBackend);
    expect(b.name).toBe('git');
  });

  // AC-T-003-2: Given a temp dir with .jj/ and .git/, create({backend:'auto'}) returns JujutsuBackend
  it("creates JujutsuBackend when auto and .jj dir exists (takes precedence, AC-T-003-2)", async () => {
    const dir = makeTempDir("foreman-factory-auto-jj-");
    mkdirSync(join(dir, '.jj'));
    mkdirSync(join(dir, '.git'));
    const b = await VcsBackendFactory.create({ backend: 'auto' }, dir);
    expect(b).toBeInstanceOf(JujutsuBackend);
    expect(b.name).toBe('jujutsu');
  });

  // AC-T-003-3: Given a temp dir with neither, create({backend:'auto'}) throws
  it("throws an error when auto and neither .git nor .jj exists (AC-T-003-3)", async () => {
    const dir = makeTempDir("foreman-factory-auto-neither-");
    await expect(
      VcsBackendFactory.create({ backend: 'auto' }, dir)
    ).rejects.toThrow(/auto-detection failed/);
  });

  // AC-T-003-5: Given backend='invalid' as any, create() throws descriptive error
  it("throws a descriptive error for invalid backend value (AC-T-003-5)", async () => {
    await expect(
      VcsBackendFactory.create({ backend: 'invalid' as never }, '/tmp')
    ).rejects.toThrow(/unrecognized backend/);
  });

  it("sets projectPath correctly on the created backend", async () => {
    const dir = makeTempDir("foreman-factory-path-");
    mkdirSync(join(dir, '.git'));
    const b = (await VcsBackendFactory.create({ backend: 'git' }, dir)) as GitBackend;
    expect(b.projectPath).toBe(dir);
  });
});

// ── createSync ────────────────────────────────────────────────────────────────

describe("VcsBackendFactory.createSync", () => {
  it("creates GitBackend for backend='git'", () => {
    const b = VcsBackendFactory.createSync({ backend: 'git' }, '/tmp');
    expect(b).toBeInstanceOf(GitBackend);
    expect(b.name).toBe('git');
  });

  it("creates JujutsuBackend for backend='jujutsu'", () => {
    const b = VcsBackendFactory.createSync({ backend: 'jujutsu' }, '/tmp');
    expect(b).toBeInstanceOf(JujutsuBackend);
    expect(b.name).toBe('jujutsu');
  });

  it("auto-detects GitBackend when .git directory exists", () => {
    const dir = makeTempDir("foreman-factory-sync-git-");
    mkdirSync(join(dir, '.git'));
    const b = VcsBackendFactory.createSync({ backend: 'auto' }, dir);
    expect(b).toBeInstanceOf(GitBackend);
  });

  it("auto-detects JujutsuBackend when .jj directory exists (takes precedence)", () => {
    const dir = makeTempDir("foreman-factory-sync-jj-");
    mkdirSync(join(dir, '.jj'));
    mkdirSync(join(dir, '.git'));
    const b = VcsBackendFactory.createSync({ backend: 'auto' }, dir);
    expect(b).toBeInstanceOf(JujutsuBackend);
  });

  it("throws when auto-detection finds neither .git nor .jj", () => {
    const dir = makeTempDir("foreman-factory-sync-neither-");
    expect(() =>
      VcsBackendFactory.createSync({ backend: 'auto' }, dir)
    ).toThrow(/auto-detection failed/);
  });

  it("sets projectPath correctly on the created backend", () => {
    const b = VcsBackendFactory.createSync({ backend: 'git' }, '/custom/path') as GitBackend;
    expect(b.projectPath).toBe('/custom/path');
  });
});

// ── fromEnv ───────────────────────────────────────────────────────────────────

describe("VcsBackendFactory.fromEnv", () => {
  it("returns GitBackend when env is undefined", async () => {
    const b = await VcsBackendFactory.fromEnv('/tmp', undefined);
    expect(b).toBeInstanceOf(GitBackend);
  });

  it("returns GitBackend when env is 'git'", async () => {
    const b = await VcsBackendFactory.fromEnv('/tmp', 'git');
    expect(b).toBeInstanceOf(GitBackend);
  });

  it("returns JujutsuBackend when env is 'jujutsu'", async () => {
    const b = await VcsBackendFactory.fromEnv('/tmp', 'jujutsu');
    expect(b).toBeInstanceOf(JujutsuBackend);
  });

  it("returns GitBackend for unrecognized env value", async () => {
    const b = await VcsBackendFactory.fromEnv('/tmp', 'mercurial');
    expect(b).toBeInstanceOf(GitBackend);
  });

  it("projectPath is set correctly on the returned backend", async () => {
    const b = (await VcsBackendFactory.fromEnv('/custom/path', 'git')) as GitBackend;
    expect(b.projectPath).toBe('/custom/path');
  });
});
