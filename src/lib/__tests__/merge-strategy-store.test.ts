import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { ForemanStore } from '../store.js';

describe('merge_strategy in runs table', () => {
  let store: ForemanStore;
  let tmpDir: string;
  let projectId: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'foreman-merge-test-'));
    store = new ForemanStore(join(tmpDir, 'test.db'));
    const project = store.registerProject('test-project', tmpDir);
    projectId = project.id;
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  const makeRun = (mergeStrategy: 'auto' | 'pr' | 'none' | undefined) =>
    store.createRun(projectId, 'seed-1', 'developer', undefined, {
      mergeStrategy,
    });

  const get = (id: string) => store.getRun(id)?.merge_strategy;

  it('stores and retrieves merge_strategy: pr', () => {
    const run = makeRun('pr');
    expect(run.merge_strategy).toBe('pr');
    expect(get(run.id)).toBe('pr');
  });

  it('stores and retrieves merge_strategy: none', () => {
    const run = makeRun('none');
    expect(run.merge_strategy).toBe('none');
    expect(get(run.id)).toBe('none');
  });

  it('defaults to merge_strategy: auto when not specified', () => {
    const run = makeRun(undefined);
    expect(run.merge_strategy).toBe('auto');
    expect(get(run.id)).toBe('auto');
  });

  it('stores and retrieves merge_strategy: auto explicitly', () => {
    const run = makeRun('auto');
    expect(run.merge_strategy).toBe('auto');
    expect(get(run.id)).toBe('auto');
  });

  it('updateRun can change merge_strategy', () => {
    const run = makeRun('none');
    expect(run.merge_strategy).toBe('none');
    store.updateRun(run.id, { merge_strategy: 'pr' });
    expect(get(run.id)).toBe('pr');
  });

  it('migration adds merge_strategy column with default auto', () => {
    // The migration `ALTER TABLE runs ADD COLUMN merge_strategy TEXT DEFAULT 'auto'`
    // runs during store construction so the column is available from the start.
    const run = makeRun(undefined);
    expect(run.merge_strategy).toBe('auto');
    expect(get(run.id)).toBe('auto');
  });
});
