/**
 * Tests for reviewer prompt VCS context templating (TRD-027).
 *
 * Verifies that:
 *   AC-T-027-1: {{vcsBackendName}} and {{vcsBranchPrefix}} are rendered in reviewer.md
 *   AC-T-027-2: Variables are substituted correctly for git and jujutsu
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { buildPhasePrompt } from "../roles.js";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const DEFAULT_REVIEWER_MD = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "reviewer.md");

// ── AC-T-027-1: Template variables present in reviewer.md raw template ────────

describe("reviewer.md template: VCS context placeholder variables (AC-T-027-1)", () => {
  it("raw template contains {{vcsBackendName}} placeholder", () => {
    const content = readFileSync(DEFAULT_REVIEWER_MD, "utf-8");
    expect(content).toContain("{{vcsBackendName}}");
  });

  it("raw template contains {{vcsBranchPrefix}} placeholder", () => {
    const content = readFileSync(DEFAULT_REVIEWER_MD, "utf-8");
    expect(content).toContain("{{vcsBranchPrefix}}");
  });

  it("raw template has a VCS Context section", () => {
    const content = readFileSync(DEFAULT_REVIEWER_MD, "utf-8");
    expect(content).toContain("## VCS Context");
  });
});

// ── AC-T-027-2: Variables substituted correctly for git and jujutsu ──────────

describe("buildPhasePrompt reviewer: vcsBackendName substitution (AC-T-027-2)", () => {
  it("renders 'git' as vcsBackendName in reviewer prompt", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-rev-test",
      seedTitle: "Review auth fix",
      seedDescription: "Fix authentication token refresh",
      vcsBackendName: "git",
      vcsBranchPrefix: "foreman/",
    });
    expect(prompt).toContain("git");
    expect(prompt).not.toContain("{{vcsBackendName}}");
  });

  it("renders 'jujutsu' as vcsBackendName in reviewer prompt", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-rev-test",
      seedTitle: "Review auth fix",
      seedDescription: "Fix authentication token refresh",
      vcsBackendName: "jujutsu",
      vcsBranchPrefix: "foreman/",
    });
    expect(prompt).toContain("jujutsu");
    expect(prompt).not.toContain("{{vcsBackendName}}");
  });

  it("renders vcsBranchPrefix in reviewer prompt", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-rev-test",
      seedTitle: "Review auth fix",
      seedDescription: "desc",
      vcsBackendName: "git",
      vcsBranchPrefix: "foreman/",
    });
    expect(prompt).toContain("foreman/");
    expect(prompt).not.toContain("{{vcsBranchPrefix}}");
  });

  it("does not leave any unresolved vcs* placeholders in reviewer prompt", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-rev-test",
      seedTitle: "Review auth fix",
      seedDescription: "desc",
      runId: "run-456",
      vcsBackendName: "git",
      vcsBranchPrefix: "foreman/",
    });
    expect(prompt).not.toContain("{{vcsBackendName}}");
    expect(prompt).not.toContain("{{vcsBranchPrefix}}");
  });

  it("defaults vcsBackendName to 'git' when not provided", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-rev-test",
      seedTitle: "Review auth fix",
      seedDescription: "desc",
    });
    // Should have the VCS context section but with default git values
    expect(prompt).not.toContain("{{vcsBackendName}}");
    // Default is "git"
    expect(prompt).toContain("git");
  });

  it("defaults vcsBranchPrefix to 'foreman/' when not provided", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-rev-test",
      seedTitle: "Review auth fix",
      seedDescription: "desc",
    });
    expect(prompt).not.toContain("{{vcsBranchPrefix}}");
    expect(prompt).toContain("foreman/");
  });

  it("reviewer prompt still includes seed context alongside VCS context", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-rev-test",
      seedTitle: "Review auth fix",
      seedDescription: "Fix authentication token refresh",
      vcsBackendName: "git",
      vcsBranchPrefix: "foreman/",
    });
    expect(prompt).toContain("bd-rev-test");
    expect(prompt).toContain("Review auth fix");
    expect(prompt).toContain("REVIEW.md");
    expect(prompt).toContain("DO NOT modify");
  });

  it("reviewer prompt includes both git backend and branch prefix information", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-rev-test",
      seedTitle: "Review auth fix",
      seedDescription: "desc",
      vcsBackendName: "git",
      vcsBranchPrefix: "foreman/",
    });
    // Both pieces of VCS context should appear in the rendered prompt
    const vcsIdx = prompt.indexOf("## VCS Context");
    expect(vcsIdx).toBeGreaterThan(-1);
    const vcsSection = prompt.slice(vcsIdx, vcsIdx + 300);
    expect(vcsSection).toContain("git");
    expect(vcsSection).toContain("foreman/");
  });

  it("reviewer prompt renders jujutsu backend name correctly", () => {
    const prompt = buildPhasePrompt("reviewer", {
      seedId: "bd-rev-test",
      seedTitle: "Review jj task",
      seedDescription: "desc",
      vcsBackendName: "jujutsu",
      vcsBranchPrefix: "foreman/",
    });
    const vcsIdx = prompt.indexOf("## VCS Context");
    expect(vcsIdx).toBeGreaterThan(-1);
    const vcsSection = prompt.slice(vcsIdx, vcsIdx + 300);
    expect(vcsSection).toContain("jujutsu");
    expect(vcsSection).toContain("foreman/");
  });
});
