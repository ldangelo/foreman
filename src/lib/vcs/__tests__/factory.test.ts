/**
 * TRD-003-TEST: VcsBackendFactory verification.
 *
 * Tests:
 * 1. Explicit 'git' backend selection → returns GitBackend
 * 2. Explicit 'jujutsu' backend selection → returns JujutsuBackend
 * 3. Auto-detection with .git/ → returns GitBackend
 * 4. Auto-detection with .jj/ → returns JujutsuBackend
 * 5. Auto-detection with both .jj/ and .git/ → JujutsuBackend wins
 * 6. Auto-detection with neither → throws descriptive error
 *
 * Tests use temporary directories (no actual git/jj CLI calls needed for factory logic).
 */

import { describe, it, expect, afterEach } from 'vitest';
import {
  mkdtempSync,
  mkdirSync,
  rmSync,
  realpathSync,
} from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { VcsBackendFactory, GitBackend, JujutsuBackend } from '../index.js';
import type { VcsConfig } from '../types.js';

// ── Helpers ──────────────────────────────────────────────────────────────────

const tempDirs: string[] = [];

function makeTempDir(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'foreman-factory-test-')));
  tempDirs.push(dir);
  return dir;
}

function makeDirWithGit(): string {
  const dir = makeTempDir();
  mkdirSync(join(dir, '.git'));
  return dir;
}

function makeDirWithJj(): string {
  const dir = makeTempDir();
  mkdirSync(join(dir, '.jj'));
  return dir;
}

function makeDirWithBoth(): string {
  const dir = makeTempDir();
  mkdirSync(join(dir, '.git'));
  mkdirSync(join(dir, '.jj'));
  return dir;
}

afterEach(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.length = 0;
});

// ── Explicit backend selection ────────────────────────────────────────────────

describe('VcsBackendFactory.create — explicit backend selection', () => {
  it('returns GitBackend when backend is "git"', async () => {
    const dir = makeTempDir();
    const config: VcsConfig = { backend: 'git' };
    const backend = await VcsBackendFactory.create(config, dir);
    expect(backend).toBeInstanceOf(GitBackend);
  });

  it('returns JujutsuBackend when backend is "jujutsu"', async () => {
    const dir = makeTempDir();
    const config: VcsConfig = { backend: 'jujutsu' };
    const backend = await VcsBackendFactory.create(config, dir);
    expect(backend).toBeInstanceOf(JujutsuBackend);
  });

  it('passes the projectPath to GitBackend constructor', async () => {
    const dir = makeTempDir();
    const config: VcsConfig = { backend: 'git' };
    const backend = await VcsBackendFactory.create(config, dir) as GitBackend;
    expect(backend.projectPath).toBe(dir);
  });

  it('passes the projectPath to JujutsuBackend constructor', async () => {
    const dir = makeTempDir();
    const config: VcsConfig = { backend: 'jujutsu' };
    const backend = await VcsBackendFactory.create(config, dir) as JujutsuBackend;
    expect(backend.projectPath).toBe(dir);
  });

  it('explicit git backend ignores absence of .git directory', async () => {
    // Factory must NOT do filesystem detection for explicit backends
    const dir = makeTempDir(); // no .git or .jj
    const config: VcsConfig = { backend: 'git' };
    const backend = await VcsBackendFactory.create(config, dir);
    expect(backend).toBeInstanceOf(GitBackend);
  });

  it('explicit jujutsu backend ignores absence of .jj directory', async () => {
    const dir = makeTempDir(); // no .git or .jj
    const config: VcsConfig = { backend: 'jujutsu' };
    const backend = await VcsBackendFactory.create(config, dir);
    expect(backend).toBeInstanceOf(JujutsuBackend);
  });
});

// ── Auto-detection ────────────────────────────────────────────────────────────

describe('VcsBackendFactory.create — auto-detection', () => {
  it('detects GitBackend when only .git/ exists', async () => {
    const dir = makeDirWithGit();
    const config: VcsConfig = { backend: 'auto' };
    const backend = await VcsBackendFactory.create(config, dir);
    expect(backend).toBeInstanceOf(GitBackend);
  });

  it('detects JujutsuBackend when only .jj/ exists', async () => {
    const dir = makeDirWithJj();
    const config: VcsConfig = { backend: 'auto' };
    const backend = await VcsBackendFactory.create(config, dir);
    expect(backend).toBeInstanceOf(JujutsuBackend);
  });

  it('.jj/ takes precedence over .git/ in colocated repos', async () => {
    const dir = makeDirWithBoth(); // has both .git/ and .jj/
    const config: VcsConfig = { backend: 'auto' };
    const backend = await VcsBackendFactory.create(config, dir);
    expect(backend).toBeInstanceOf(JujutsuBackend);
  });

  it('throws descriptive error when neither .git/ nor .jj/ exists', async () => {
    const dir = makeTempDir(); // no .git or .jj
    const config: VcsConfig = { backend: 'auto' };
    await expect(VcsBackendFactory.create(config, dir)).rejects.toThrow(
      /No VCS detected/,
    );
  });

  it('error message includes the project path for debugging', async () => {
    const dir = makeTempDir();
    const config: VcsConfig = { backend: 'auto' };
    await expect(VcsBackendFactory.create(config, dir)).rejects.toThrow(dir);
  });

  it('error message mentions both expected directory names', async () => {
    const dir = makeTempDir();
    const config: VcsConfig = { backend: 'auto' };
    await expect(VcsBackendFactory.create(config, dir)).rejects.toThrow(
      /\.git.*\.jj|\.jj.*\.git/,
    );
  });
});

// ── Config sub-options pass-through ──────────────────────────────────────────

describe('VcsBackendFactory.create — VcsConfig sub-options', () => {
  it('accepts git sub-config without error', async () => {
    const dir = makeTempDir();
    const config: VcsConfig = { backend: 'git', git: { useTown: true } };
    const backend = await VcsBackendFactory.create(config, dir);
    expect(backend).toBeInstanceOf(GitBackend);
  });

  it('accepts jujutsu sub-config without error', async () => {
    const dir = makeTempDir();
    const config: VcsConfig = { backend: 'jujutsu', jujutsu: { minVersion: '0.25.0' } };
    const backend = await VcsBackendFactory.create(config, dir);
    expect(backend).toBeInstanceOf(JujutsuBackend);
  });

  it('accepts auto with both sub-configs and detects by filesystem', async () => {
    const dir = makeDirWithGit();
    const config: VcsConfig = {
      backend: 'auto',
      git: { useTown: false },
      jujutsu: { minVersion: '0.25.0' },
    };
    const backend = await VcsBackendFactory.create(config, dir);
    expect(backend).toBeInstanceOf(GitBackend);
  });
});

// ── Return type ───────────────────────────────────────────────────────────────

describe('VcsBackendFactory.create — return type', () => {
  it('returns a value assignable to VcsBackend (structural typing)', async () => {
    const dir = makeTempDir();
    const config: VcsConfig = { backend: 'git' };
    const backend = await VcsBackendFactory.create(config, dir);
    // Check that all interface methods exist on the returned object
    expect(typeof backend.getRepoRoot).toBe('function');
    expect(typeof backend.createWorkspace).toBe('function');
    expect(typeof backend.merge).toBe('function');
    expect(typeof backend.getFinalizeCommands).toBe('function');
  });
});
