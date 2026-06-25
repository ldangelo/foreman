import { describe, expect, it } from "vitest";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { writePhaseTaskInput } from "../pipeline-executor.js";

describe("writePhaseTaskInput", () => {
  it("writes normalized retry feedback for any target phase", () => {
    const dir = mkdtempSync(join(tmpdir(), "foreman-phase-task-"));
    try {
      const path = writePhaseTaskInput({
        reportDir: dir,
        targetPhase: "developer",
        sourcePhase: "qlty",
        sourceArtifact: "QLTY_REPORT.md",
        error: "qlty check failed",
        feedback: "## Verdict: FAIL\n- lint issue",
        retryAttempt: 1,
        maxRetries: 2,
      });

      expect(path).toBe(join(dir, "DEVELOPER_TASK.md"));
      expect(readFileSync(path, "utf-8")).toContain("# Phase Task: developer");
      expect(readFileSync(path, "utf-8")).toContain("## Source Phase\nqlty");
      expect(readFileSync(path, "utf-8")).toContain("## Source Artifact\nQLTY_REPORT.md");
      expect(readFileSync(path, "utf-8")).toContain("## Retry Attempt\n1/2");
      expect(readFileSync(path, "utf-8")).toContain("lint issue");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("uses the target phase name for non-developer inputs", () => {
    const dir = mkdtempSync(join(tmpdir(), "foreman-phase-task-"));
    try {
      const path = writePhaseTaskInput({
        reportDir: dir,
        targetPhase: "qa",
        sourcePhase: "developer",
        feedback: "Developer handoff",
        mode: "forwarded-feedback",
      });

      expect(path).toBe(join(dir, "QA_TASK.md"));
      expect(readFileSync(path, "utf-8")).toContain("## Mode\nforwarded-feedback");
      expect(readFileSync(path, "utf-8")).toContain("## Source Phase\ndeveloper");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
