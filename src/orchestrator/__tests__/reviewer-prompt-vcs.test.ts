/**
 * Tests for reviewer prompt VCS context variable templating (TRD-027).
 *
 * Verifies that:
 *   AC-T-027-1: Given git backend, when reviewer prompt is rendered, it contains 'git' as the VCS name.
 *   AC-T-027-2: Given jj backend, when reviewer prompt is rendered, it contains 'jujutsu' as the VCS name.
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { buildPhasePrompt } from "../roles.js";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const DEFAULT_REVIEWER_MD = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "reviewer.md");

// ── Raw Template Placeholder Verification ────────────────────────────────────

describe("reviewer.md template: VCS placeholder variables", () => {
  it("raw template contains {{vcsBackendName}} placeholder", () => {
    const content = readFileSync(DEFAULT_REVIEWER_MD, "utf-8");
    expect(content).toContain("{{vcsBackendName}}");
  });

  it("raw template contains {{vcsBranchPrefix}} placeholder", () => {
    const content = readFileSync(DEFAULT_REVIEWER_MD, "utf-8");
    expect(content).toContain("{{vcsBranchPrefix}}");
  });
});

// ── AC-T-027-1: GitBackend rendering ─────────────────────────────────────────

describe("buildPhasePrompt reviewer: GitBackend VCS rendering (AC-T-027-1)", () => {
  it("renders 'git' as vcsBackendName in reviewer prompt", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "Fix auth token refresh",
      runId: "run-123",
      vcsBackendName: "git",
      vcsBranchPrefix: "foreman/",
    });
    expect(prompt).toContain("git");
    expect(prompt).not.toContain("{{vcsBackendName}}");
  });

  it("renders 'foreman/' as vcsBranchPrefix in reviewer prompt for git backend", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "Fix auth token refresh",
      runId: "run-123",
      vcsBackendName: "git",
      vcsBranchPrefix: "foreman/",
    });
    expect(prompt).toContain("foreman/");
    expect(prompt).not.toContain("{{vcsBranchPrefix}}");
  });

  it("does not leave unresolved vcs* placeholders for git backend", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      runId: "run-123",
      vcsBackendName: "git",
      vcsBranchPrefix: "foreman/",
    });
    expect(prompt).not.toContain("{{vcsBackendName}}");
    expect(prompt).not.toContain("{{vcsBranchPrefix}}");
  });
});

// ── AC-T-027-2: JujutsuBackend rendering ─────────────────────────────────────

describe("buildPhasePrompt reviewer: JujutsuBackend VCS rendering (AC-T-027-2)", () => {
  it("renders 'jujutsu' as vcsBackendName in reviewer prompt", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "Fix auth token refresh",
      runId: "run-123",
      vcsBackendName: "jujutsu",
      vcsBranchPrefix: "foreman/",
    });
    expect(prompt).toContain("jujutsu");
    expect(prompt).not.toContain("{{vcsBackendName}}");
  });

  it("renders 'foreman/' as vcsBranchPrefix in reviewer prompt for jujutsu backend", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "Fix auth token refresh",
      runId: "run-123",
      vcsBackendName: "jujutsu",
      vcsBranchPrefix: "foreman/",
    });
    expect(prompt).toContain("foreman/");
    expect(prompt).not.toContain("{{vcsBranchPrefix}}");
  });

  it("does not leave unresolved vcs* placeholders for jujutsu backend", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      runId: "run-123",
      vcsBackendName: "jujutsu",
      vcsBranchPrefix: "foreman/",
    });
    expect(prompt).not.toContain("{{vcsBackendName}}");
    expect(prompt).not.toContain("{{vcsBranchPrefix}}");
  });

  it("prompt does not contain 'git' as backend name when jujutsu is specified", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      runId: "run-123",
      vcsBackendName: "jujutsu",
      vcsBranchPrefix: "foreman/",
    });
    // The VCS context line should say 'jujutsu' not 'git'
    expect(prompt).toMatch(/Backend:\s+\*\*jujutsu\*\*/);
  });
});

// ── Default Values ────────────────────────────────────────────────────────────

describe("buildPhasePrompt reviewer: default values when VCS vars omitted", () => {
  it("defaults to 'git' as vcsBackendName when not provided", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-def",
      seedTitle: "Default test",
      seedDescription: "desc",
    });
    expect(prompt).toContain("git");
    expect(prompt).not.toContain("{{vcsBackendName}}");
  });

  it("defaults to 'foreman/' as vcsBranchPrefix when not provided", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-def",
      seedTitle: "Default test",
      seedDescription: "desc",
    });
    expect(prompt).toContain("foreman/");
    expect(prompt).not.toContain("{{vcsBranchPrefix}}");
  });

  it("does not leave unresolved placeholders with default values", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-def",
      seedTitle: "Default test",
      seedDescription: "desc",
      runId: "run-def",
    });
    expect(prompt).not.toContain("{{vcsBackendName}}");
    expect(prompt).not.toContain("{{vcsBranchPrefix}}");
  });
});
