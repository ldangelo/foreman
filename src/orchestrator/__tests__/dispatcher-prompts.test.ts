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
 * - selectBackend() routes all bead types to 'br' by default
 * - selectBackend() returns 'br' when type is missing/unknown
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

describe("Dispatcher.selectBackend (bead-type-aware routing)", () => {
  it("returns 'br' for type=bug", () => {
    const d = makeDispatcher();
    expect(d.selectBackend({ id: "bd-001", title: "Fix bug", type: "bug" })).toBe("br");
  });

  it("returns 'br' for type=feature", () => {
    const d = makeDispatcher();
    expect(d.selectBackend({ id: "bd-002", title: "Add feature", type: "feature" })).toBe("br");
  });

  it("returns 'br' for type=task", () => {
    const d = makeDispatcher();
    expect(d.selectBackend({ id: "bd-003", title: "Do task", type: "task" })).toBe("br");
  });

  it("returns 'br' for type=epic", () => {
    const d = makeDispatcher();
    expect(d.selectBackend({ id: "bd-004", title: "Big epic", type: "epic" })).toBe("br");
  });

  it("returns 'br' for type=chore", () => {
    const d = makeDispatcher();
    expect(d.selectBackend({ id: "bd-005", title: "Chore task", type: "chore" })).toBe("br");
  });

  it("returns 'br' for type=docs", () => {
    const d = makeDispatcher();
    expect(d.selectBackend({ id: "bd-006", title: "Write docs", type: "docs" })).toBe("br");
  });

  it("returns 'br' for type=question", () => {
    const d = makeDispatcher();
    expect(d.selectBackend({ id: "bd-007", title: "Ask question", type: "question" })).toBe("br");
  });

  it("returns 'br' when type is undefined (missing)", () => {
    const d = makeDispatcher();
    expect(d.selectBackend({ id: "bd-008", title: "Unknown type" })).toBe("br");
  });

  it("returns 'br' for unknown/unrecognized type", () => {
    const d = makeDispatcher();
    expect(d.selectBackend({ id: "bd-009", title: "Something", type: "unrecognized-type" })).toBe("br");
  });
});
