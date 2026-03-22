/**
 * Tests for TRD-012: Dispatcher inline prompts.
 *
 * Verifies:
 * - buildSpawnPrompt() does NOT emit "br close" (bead closed by refinery after merge)
 * - buildResumePrompt() does NOT emit "br close"
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
  it("does NOT include 'br close' — bead is closed by refinery after merge", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("bd-001", "Implement feature");

    expect(prompt).not.toContain("br close");
  });

  it("tells agent NOT to close the bead manually", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("bd-001", "Implement feature");

    expect(prompt).toContain("Do NOT close the bead manually");
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

    const syncIdx = prompt.indexOf("br sync --flush-only");
    const addIdx = prompt.indexOf("git add .");
    expect(syncIdx).toBeGreaterThan(-1);
    expect(addIdx).toBeGreaterThan(-1);
    expect(syncIdx).toBeLessThan(addIdx);
  });
});

describe("TRD-012: Dispatcher.buildResumePrompt", () => {
  it("does NOT include 'br close' — bead is closed by refinery after merge", () => {
    const d = makeDispatcher();
    const prompt = d.buildResumePrompt("bd-001", "Implement feature");

    expect(prompt).not.toContain("br close");
  });

  it("tells agent NOT to close the bead manually", () => {
    const d = makeDispatcher();
    const prompt = d.buildResumePrompt("bd-001", "Implement feature");

    expect(prompt).toContain("Do NOT close the bead manually");
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

    const syncIdx = prompt.indexOf("br sync --flush-only");
    const addIdx = prompt.indexOf("git add .");
    expect(syncIdx).toBeGreaterThan(-1);
    expect(addIdx).toBeGreaterThan(-1);
    expect(syncIdx).toBeLessThan(addIdx);
  });
});
