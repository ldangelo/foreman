/**
 * TRD-033-TEST: Merge Agent Schema Tests
 *
 * Tests for the merge_agent_configs table CRUD operations:
 * 1. upsertMergeAgentConfig — creates a new row if none exists
 * 2. upsertMergeAgentConfig — updates an existing row
 * 3. getMergeAgentConfig — returns null when no config exists
 * 4. getMergeAgentConfig — returns the stored row
 * 5. upsertMergeAgentConfig — partial update preserves unspecified fields
 * 6. enabled and pid fields round-trip correctly
 * 7. interval_seconds defaults and updates
 * 8. multiple projects have independent configs
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../store.js";

describe("ForemanStore — merge_agent_configs CRUD", () => {
  let store: ForemanStore;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-store-merge-agent-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("getMergeAgentConfig returns null when no config exists", () => {
    const project = store.registerProject("p1", "/p1");
    const result = store.getMergeAgentConfig(project.id);
    expect(result).toBeNull();
  });

  it("upsertMergeAgentConfig creates a new row when none exists", () => {
    const project = store.registerProject("p1", "/p1");
    const config = store.upsertMergeAgentConfig(project.id, {
      interval_seconds: 60,
      enabled: 1,
    });

    expect(config).toBeDefined();
    expect(config.project_id).toBe(project.id);
    expect(config.interval_seconds).toBe(60);
    expect(config.enabled).toBe(1);
    expect(config.pid).toBeNull();
    expect(config.created_at).toBeTruthy();
    expect(config.updated_at).toBeTruthy();
  });

  it("getMergeAgentConfig returns the stored row after upsert", () => {
    const project = store.registerProject("p1", "/p1");
    store.upsertMergeAgentConfig(project.id, { interval_seconds: 30, enabled: 1 });

    const fetched = store.getMergeAgentConfig(project.id);
    expect(fetched).not.toBeNull();
    expect(fetched!.interval_seconds).toBe(30);
    expect(fetched!.enabled).toBe(1);
  });

  it("upsertMergeAgentConfig updates an existing row", () => {
    const project = store.registerProject("p1", "/p1");
    store.upsertMergeAgentConfig(project.id, { interval_seconds: 30, enabled: 1 });
    const updated = store.upsertMergeAgentConfig(project.id, { interval_seconds: 120 });

    expect(updated.interval_seconds).toBe(120);
    expect(updated.enabled).toBe(1); // unchanged
  });

  it("upsertMergeAgentConfig — partial update preserves unspecified fields", () => {
    const project = store.registerProject("p1", "/p1");
    store.upsertMergeAgentConfig(project.id, { interval_seconds: 45, enabled: 1, pid: 12345 });

    // Only update enabled
    const updated = store.upsertMergeAgentConfig(project.id, { enabled: 0 });
    expect(updated.enabled).toBe(0);
    expect(updated.interval_seconds).toBe(45); // preserved
    expect(updated.pid).toBe(12345); // preserved
  });

  it("pid field can be set and then cleared to null", () => {
    const project = store.registerProject("p1", "/p1");
    store.upsertMergeAgentConfig(project.id, { enabled: 1, pid: 99999 });

    const withPid = store.getMergeAgentConfig(project.id);
    expect(withPid!.pid).toBe(99999);

    store.upsertMergeAgentConfig(project.id, { pid: null });
    const withoutPid = store.getMergeAgentConfig(project.id);
    expect(withoutPid!.pid).toBeNull();
  });

  it("enabled field accepts 0 (disabled)", () => {
    const project = store.registerProject("p1", "/p1");
    const config = store.upsertMergeAgentConfig(project.id, { enabled: 0, interval_seconds: 30 });
    expect(config.enabled).toBe(0);
  });

  it("multiple projects have independent configs", () => {
    const p1 = store.registerProject("p1", "/p1");
    const p2 = store.registerProject("p2", "/p2");

    store.upsertMergeAgentConfig(p1.id, { interval_seconds: 30, enabled: 1 });
    store.upsertMergeAgentConfig(p2.id, { interval_seconds: 60, enabled: 0 });

    const cfg1 = store.getMergeAgentConfig(p1.id);
    const cfg2 = store.getMergeAgentConfig(p2.id);

    expect(cfg1!.interval_seconds).toBe(30);
    expect(cfg1!.enabled).toBe(1);
    expect(cfg2!.interval_seconds).toBe(60);
    expect(cfg2!.enabled).toBe(0);
  });

  it("interval_seconds defaults to 30 when not provided on insert", () => {
    const project = store.registerProject("p1", "/p1");
    // Upsert with only enabled; interval_seconds should default to 30
    const config = store.upsertMergeAgentConfig(project.id, { enabled: 1 });
    expect(config.interval_seconds).toBe(30);
  });
});
