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
