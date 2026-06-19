import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { acceptBudgetLimitedCompletion, createPhaseToolPolicy, validatePhaseArtifact } from "../phase-overwatch.js";

function tempWorktree(): string {
  return mkdtempSync(join(tmpdir(), "foreman-overwatch-"));
}

describe("phase overwatch artifact validation", () => {
  it("accepts a concise explorer handoff with edit and test targets", () => {
    const worktreePath = tempWorktree();
    writeFileSync(join(worktreePath, "EXPLORER_REPORT.md"), `# Summary\nNeed wire activity feed.\n\n# Likely edit targets\n- packages/foreman_server/lib/foreman_server/inbox.ex\n- packages/foreman_server/lib/foreman_server/http/router.ex\n\n# Test targets\n- packages/foreman_server/test/http_router_test.exs\n\n# Risks\n- event ordering compatibility\n`);

    const validation = validatePhaseArtifact({
      phaseName: "explorer",
      worktreePath,
      artifact: "EXPLORER_REPORT.md",
    });

    expect(validation.valid).toBe(true);
  });

  it("rejects explorer reports that do not identify edit targets", () => {
    const worktreePath = tempWorktree();
    writeFileSync(join(worktreePath, "EXPLORER_REPORT.md"), `# Summary\nMapped architecture.\n\n# Likely edit targets\n\n# Test targets\n- test/http_router_test.exs\n\n# Risks\n- unknown\n`);

    const validation = validatePhaseArtifact({
      phaseName: "explorer",
      worktreePath,
      artifact: "EXPLORER_REPORT.md",
    });

    expect(validation.valid).toBe(false);
    expect(validation.findings.join("\n")).toContain("Expected at least 1 edit target");
  });

  it("accepts developer handoff reports with changed files and QA notes", () => {
    const worktreePath = tempWorktree();
    writeFileSync(join(worktreePath, "DEVELOPER_REPORT.md"), `# Approach\nSmall diff.\n\n# Files Changed\n- src/a.ts — updated behavior\n\n# QA Handoff\n- Run npx vitest run src/a.test.ts\n\n# Decisions & Trade-offs\n- Kept existing API.\n\n# Known Limitations\n- None.\n`);

    const validation = validatePhaseArtifact({
      phaseName: "developer",
      worktreePath,
      artifact: "DEVELOPER_REPORT.md",
      contract: {
        completion: { requireFilesChanged: true, requireValidationNotes: true },
      },
    });

    expect(validation.valid).toBe(true);
  });

  it("blocks developer test commands and forces a handoff artifact", () => {
    const worktreePath = tempWorktree();
    const policy = createPhaseToolPolicy({
      phaseName: "developer",
      worktreePath,
      artifact: "DEVELOPER_REPORT.md",
      overwatch: { enabled: true, mode: "enforce" },
    });

    const reason = policy?.beforeTool("bash", { command: "npx vitest run src/lib/a.test.ts" });

    expect(reason).toContain("Developer must not run tests");
  });

  it("blocks broad developer discovery commands", () => {
    const worktreePath = tempWorktree();
    const policy = createPhaseToolPolicy({
      phaseName: "developer",
      worktreePath,
      artifact: "DEVELOPER_REPORT.md",
      overwatch: { enabled: true, mode: "enforce" },
    });

    expect(policy?.beforeTool("bash", { command: "find . -name '*.ts'" })).toContain("broad repo discovery");
    expect(policy?.beforeTool("bash", { command: "rg activity" })).toContain("broad repo discovery");
  });

  it("allows focused developer searches with explicit paths", () => {
    const worktreePath = tempWorktree();
    const policy = createPhaseToolPolicy({
      phaseName: "developer",
      worktreePath,
      artifact: "DEVELOPER_REPORT.md",
      overwatch: { enabled: true, mode: "enforce" },
    });

    expect(policy?.beforeTool("bash", { command: "rg activity src/orchestrator/phase-overwatch.ts" })).toBeUndefined();
  });

  it("blocks QA broad discovery tools", () => {
    const worktreePath = tempWorktree();
    const policy = createPhaseToolPolicy({
      phaseName: "qa",
      worktreePath,
      artifact: "QA_REPORT.md",
      overwatch: { enabled: true, mode: "enforce" },
    });

    expect(policy?.beforeTool("glob", { pattern: "**/*.ts" })).toContain("broad discovery tools");
  });

  it("allows QA conflict marker grep scoped to src", () => {
    const worktreePath = tempWorktree();
    const policy = createPhaseToolPolicy({
      phaseName: "qa",
      worktreePath,
      artifact: "QA_REPORT.md",
      overwatch: { enabled: true, mode: "enforce" },
    });

    const command = `grep -rn --include="*.ts" --include="*.tsx" --include="*.js" '<<<<<<<\\|>>>>>>>\\||||||||' src/ 2>/dev/null || true`;
    expect(policy?.beforeTool("bash", { command })).toBeUndefined();
  });

  it("forces phase artifact before maxTurns is exhausted", () => {
    const worktreePath = tempWorktree();
    const policy = createPhaseToolPolicy({
      phaseName: "reviewer",
      worktreePath,
      artifact: "REVIEW.md",
      maxTurns: 10,
      overwatch: { enabled: true, mode: "enforce" },
    });

    policy?.afterTurn?.(6);
    const reason = policy?.beforeTool("read", { path: "src/a.ts" });

    expect(reason).toContain("Write REVIEW.md");
  });

  it("still permits writing the configured artifact after maxToolCalls trips", () => {
    const worktreePath = tempWorktree();
    const policy = createPhaseToolPolicy({
      phaseName: "developer",
      worktreePath,
      artifact: "DEVELOPER_REPORT.md",
      overwatch: { enabled: true, mode: "enforce", maxToolCalls: 1 },
    });

    expect(policy?.beforeTool("read", { path: "src/a.ts" })).toBeUndefined();

    const blocked = policy?.beforeTool("read", { path: "src/b.ts" });
    const artifactWrite = policy?.beforeTool("write", { path: join(worktreePath, "DEVELOPER_REPORT.md"), content: "# Approach\n" });

    expect(blocked).toContain("exceeded maxToolCalls");
    expect(artifactWrite).toBeUndefined();
  });

  it("allows documentation to write its configured report outside docs", () => {
    const worktreePath = tempWorktree();
    const artifact = join(worktreePath, ".foreman/reports/run/DOCUMENTATION_REPORT.md");
    const policy = createPhaseToolPolicy({
      phaseName: "documentation",
      worktreePath,
      artifact,
      overwatch: { enabled: true, mode: "enforce" },
    });

    expect(policy?.beforeTool("write", { path: artifact, content: "# Documentation Report\n" })).toBeUndefined();
    expect(policy?.beforeTool("write", { path: join(worktreePath, "src/a.ts"), content: "x" })).toContain("documentation files or its configured report artifact");
  });

  it("blocks non-artifact writes after forced handoff", () => {
    const worktreePath = tempWorktree();
    const policy = createPhaseToolPolicy({
      phaseName: "developer",
      worktreePath,
      artifact: "DEVELOPER_REPORT.md",
      overwatch: { enabled: true, mode: "enforce", forceArtifactAfterToolCalls: 1, maxToolCalls: 5 },
    });

    expect(policy?.beforeTool("read", { path: "src/a.ts" })).toBeUndefined();

    const reason = policy?.beforeTool("write", { path: join(worktreePath, "src/b.ts"), content: "x" });

    expect(reason).toContain("Write DEVELOPER_REPORT.md");
  });

  it("allows budget-limited completion only when the artifact is valid", () => {
    const worktreePath = tempWorktree();
    writeFileSync(join(worktreePath, "EXPLORER_REPORT.md"), `# Summary\nEnough context.\n\n# Likely edit targets\n- src/a.ts\n\n# Test targets\n- src/a.test.ts\n\n# Risks\n- none\n`);

    const decision = acceptBudgetLimitedCompletion({
      phaseName: "explorer",
      worktreePath,
      artifact: "EXPLORER_REPORT.md",
      overwatch: { enabled: true, continueIfArtifactValidOnBudgetStop: true },
    }, "Phase exceeded maxTurns (20)");

    expect(decision.accept).toBe(true);
    expect(decision.reason).toContain("valid artifact");
  });
});
