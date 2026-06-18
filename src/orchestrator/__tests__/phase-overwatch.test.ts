import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { acceptBudgetLimitedCompletion, validatePhaseArtifact } from "../phase-overwatch.js";

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
