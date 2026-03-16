/**
 * Tests for TRD-012: Dispatcher inline prompts use backend-aware close commands.
 *
 * Verifies:
 * - buildSpawnPrompt() emits "br close" when backend=br
 * - buildSpawnPrompt() emits "sd close" when backend=sd
 * - buildResumePrompt() emits "br close" when backend=br
 * - buildResumePrompt() emits "sd close" when backend=sd
 * - No "sd close" in prompts when backend=br
 * - No "br close" in prompts when backend=sd
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
  it("includes 'br close' when backend=br", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("bd-001", "Implement feature", "br");

    expect(prompt).toContain(`br close bd-001 --reason "Completed"`);
  });

  it("includes 'sd close' when backend=sd", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("seed-001", "Implement feature", "sd");

    expect(prompt).toContain(`sd close seed-001 --reason "Completed"`);
  });

  it("does not include 'sd close' when backend=br", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("bd-001", "Implement feature", "br");

    expect(prompt).not.toContain("sd close");
  });

  it("does not include 'br close' when backend=sd", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("seed-001", "Implement feature", "sd");

    expect(prompt).not.toContain("br close");
  });

  it("references 'br (beads_rust)' when backend=br", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("bd-001", "Implement feature", "br");

    expect(prompt).toContain("br (beads_rust)");
  });

  it("references 'sd (seeds)' when backend=sd", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("seed-001", "Implement feature", "sd");

    expect(prompt).toContain("sd (seeds)");
  });

  it("includes git push to correct branch", () => {
    const d = makeDispatcher();
    const prompt = d.buildSpawnPrompt("bd-abc", "My task", "br");

    expect(prompt).toContain("git push -u origin foreman/bd-abc");
  });
});

describe("TRD-012: Dispatcher.buildResumePrompt", () => {
  it("includes 'br close' when backend=br", () => {
    const d = makeDispatcher();
    const prompt = d.buildResumePrompt("bd-001", "Implement feature", "br");

    expect(prompt).toContain(`br close bd-001 --reason "Completed"`);
  });

  it("includes 'sd close' when backend=sd", () => {
    const d = makeDispatcher();
    const prompt = d.buildResumePrompt("seed-001", "Implement feature", "sd");

    expect(prompt).toContain(`sd close seed-001 --reason "Completed"`);
  });

  it("does not include 'sd close' when backend=br", () => {
    const d = makeDispatcher();
    const prompt = d.buildResumePrompt("bd-001", "Implement feature", "br");

    expect(prompt).not.toContain("sd close");
  });

  it("does not include 'br close' when backend=sd", () => {
    const d = makeDispatcher();
    const prompt = d.buildResumePrompt("seed-001", "Implement feature", "sd");

    expect(prompt).not.toContain("br close");
  });

  it("mentions interrupted/rate-limited context", () => {
    const d = makeDispatcher();
    const prompt = d.buildResumePrompt("bd-001", "Implement feature", "br");

    expect(prompt).toContain("interrupted");
  });
});
