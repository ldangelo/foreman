/**
 * Tests for VcsBackendFactory.
 *
 * Tests the factory's ability to create backends from configs and env vars,
 * and its auto-detection logic.
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

  it("auto-detects 'git' when no .jj directory", () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-factory-git-")));
    tempDirs.push(dir);
    expect(VcsBackendFactory.resolveBackend({ backend: 'auto' }, dir)).toBe('git');
  });

  it("auto-detects 'jujutsu' when .jj directory exists", () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-factory-jj-")));
    tempDirs.push(dir);
    mkdirSync(join(dir, '.jj'));
    expect(VcsBackendFactory.resolveBackend({ backend: 'auto' }, dir)).toBe('jujutsu');
  });
});

// ── create (async) ────────────────────────────────────────────────────────────

describe("VcsBackendFactory.create", () => {
  it("creates GitBackend for backend='git'", async () => {
    const b = await VcsBackendFactory.create({ backend: 'git' }, '/tmp');
    expect(b).toBeInstanceOf(GitBackend);
    expect(b.name).toBe('git');
  });

  it("creates JujutsuBackend for backend='jujutsu'", async () => {
    const b = await VcsBackendFactory.create({ backend: 'jujutsu' }, '/tmp');
    expect(b).toBeInstanceOf(JujutsuBackend);
    expect(b.name).toBe('jujutsu');
  });

  it("creates GitBackend when auto and no .jj dir", async () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-factory-auto-")));
    tempDirs.push(dir);
    const b = await VcsBackendFactory.create({ backend: 'auto' }, dir);
    expect(b).toBeInstanceOf(GitBackend);
  });

  it("creates JujutsuBackend when auto and .jj dir exists", async () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-factory-auto-jj-")));
    tempDirs.push(dir);
    mkdirSync(join(dir, '.jj'));
    const b = await VcsBackendFactory.create({ backend: 'auto' }, dir);
    expect(b).toBeInstanceOf(JujutsuBackend);
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
