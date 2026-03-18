/**
 * Tests for TRD-012 (updated): Dispatcher inline prompts always use 'br close' commands
 * and 'git add .' (not 'git add -A') to limit staging scope to the current directory.
 *
 * Verifies:
 * - buildSpawnPrompt() emits "br close" for all seeds
 * - buildResumePrompt() emits "br close" for all seeds
 * - No "sd close" references in any prompt
 * - Uses "git add ." (not "git add -A") to limit staging scope to current directory in worktrees
 */

import { describe, it, expect } from "vitest";
import { Dispatcher } from "../dispatcher.js";
import type { ForemanStore } from "../../lib/store.js";
import type { ITaskClient } from "../../lib/task-client.js";

const mockStore = {} as unknown as ForemanStore;
const mockClient = {} as unknown as ITaskClient;

function makeDispatcher() {
  return new Dispatcher(mockClient, mockStore, "/tmp");
}

describe("TRD-012: Dispatcher.buildSpawnPrompt", () => {
  it("includes 'br close' command", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("bd-001", "Implement feature");

    expect(prompt).toContain(`br close bd-001 --reason "Completed"`);
  });

  it("does not include 'sd close'", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("bd-001", "Implement feature");

    expect(prompt).not.toContain("sd close");
  });

  it("references 'br (beads_rust)'", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("bd-001", "Implement feature");

    expect(prompt).toContain("br (beads_rust)");
  });

  it("includes git push to correct branch", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("bd-abc", "My task");

    expect(prompt).toContain("git push -u origin foreman/bd-abc");
  });

  it("includes sessionlog instruction", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("bd-001", "Implement feature");

    expect(prompt).toContain("SessionLogs/session-");
  });

  it("uses 'git add .' (not 'git add -A') to limit staging scope to current directory in worktrees", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("bd-001", "Implement feature");

    expect(prompt).toContain("git add .");
    expect(prompt).not.toContain("git add -A");
  });

  it("includes 'br sync --flush-only' before git add (session protocol)", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("bd-001", "Implement feature");

    expect(prompt).toContain("br sync --flush-only");

    // Verify ordering: br sync must appear before git add so beads JSONL
    // is flushed to disk before it gets staged and committed.
    const syncIdx = prompt.indexOf("br sync --flush-only");
    const addIdx = prompt.indexOf("git add .");
    expect(syncIdx).toBeGreaterThan(-1);
    expect(addIdx).toBeGreaterThan(-1);
    expect(syncIdx).toBeLessThan(addIdx);
  });

  it("flushes beads JSONL between br close and git add", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("bd-xyz", "My feature");

    const closeIdx = prompt.indexOf("br close bd-xyz");
    const syncIdx = prompt.indexOf("br sync --flush-only");
    const addIdx = prompt.indexOf("git add .");

    // Order must be: br close → br sync → git add
    expect(closeIdx).toBeLessThan(syncIdx);
    expect(syncIdx).toBeLessThan(addIdx);
  });
});

describe("TRD-012: Dispatcher.buildResumePrompt", () => {
  it("includes 'br close' command", () => {
    const d = makeDispatcher();
    const prompt = d.buildResumePrompt("bd-001", "Implement feature");

    expect(prompt).toContain(`br close bd-001 --reason "Completed"`);
  });

  it("does not include 'sd close'", () => {
    const d = makeDispatcher();
    const prompt = d.buildResumePrompt("bd-001", "Implement feature");

    expect(prompt).not.toContain("sd close");
  });

  it("mentions interrupted/rate-limited context", () => {
    const d = makeDispatcher();
    const prompt = d.buildResumePrompt("bd-001", "Implement feature");

    expect(prompt).toContain("interrupted");
  });

  it("includes sessionlog instruction", () => {
    const d = makeDispatcher();
    const prompt = d.buildResumePrompt("bd-001", "Implement feature");

    expect(prompt).toContain("SessionLogs/session-");
  });

  it("uses 'git add .' (not 'git add -A') to limit staging scope to current directory in worktrees", () => {
    const d = makeDispatcher();
    const prompt = d.buildResumePrompt("bd-001", "Implement feature");

    expect(prompt).toContain("git add .");
    expect(prompt).not.toContain("git add -A");
  });

  it("includes 'br sync --flush-only' before git add (session protocol)", () => {
    const d = makeDispatcher();
    const prompt = d.buildResumePrompt("bd-001", "Implement feature");

    expect(prompt).toContain("br sync --flush-only");

    // Verify ordering: br sync must appear before git add so beads JSONL
    // is flushed to disk before it gets staged and committed.
    const syncIdx = prompt.indexOf("br sync --flush-only");
    const addIdx = prompt.indexOf("git add .");
    expect(syncIdx).toBeGreaterThan(-1);
    expect(addIdx).toBeGreaterThan(-1);
    expect(syncIdx).toBeLessThan(addIdx);
  });

  it("flushes beads JSONL between br close and git add", () => {
    const d = makeDispatcher();
    const prompt = d.buildResumePrompt("bd-xyz", "My feature");

    const closeIdx = prompt.indexOf("br close bd-xyz");
    const syncIdx = prompt.indexOf("br sync --flush-only");
    const addIdx = prompt.indexOf("git add .");

    // Order must be: br close → br sync → git add
    expect(closeIdx).toBeLessThan(syncIdx);
    expect(syncIdx).toBeLessThan(addIdx);
  });
});
