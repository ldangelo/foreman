/**
 * Tests for Doctor.checkWorkflows()
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Doctor } from "../doctor.js";
import { installBundledWorkflows } from "../../lib/workflow-loader.js";

function makeMocks(projectPath: string) {
  const store = {
    getProjectByPath: vi.fn().mockReturnValue(null),
    getRunsByStatus: vi.fn().mockReturnValue([]),
    getRunsForSeed: vi.fn().mockReturnValue([]),
    getActiveRuns: vi.fn().mockReturnValue([]),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const doctor = new Doctor(store as any, projectPath);
  return { store, doctor };
}

describe("Doctor.checkWorkflows()", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-doctor-wf-"));
    process.env["FOREMAN_HOME"] = tmpDir;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("passes when all bundled workflows are installed with correct content", () => {
    // Install the real bundled workflows (not minimal stubs) so staleness check passes
    installBundledWorkflows(tmpDir, true);

    const { doctor } = makeMocks(tmpDir);
    return doctor.checkWorkflows().then((result) => {
      expect(result.status).toBe("pass");
      expect(result.message).toMatch(/All required/);
    });
  });

  it("fails when workflow configs are missing", () => {
    const { doctor } = makeMocks(tmpDir);
    return doctor.checkWorkflows().then((result) => {
      expect(result.status).toBe("fail");
      expect(result.message).toMatch(/missing/i);
    });
  });

  it("reports dry-run status when dryRun=true", () => {
    const { doctor } = makeMocks(tmpDir);
    return doctor.checkWorkflows({ dryRun: true }).then((result) => {
      expect(result.status).toBe("fail");
      expect(result.message).toMatch(/dry-run/i);
    });
  });

  it("installs missing configs when fix=true", () => {
    const { doctor } = makeMocks(tmpDir);
    return doctor.checkWorkflows({ fix: true }).then((result) => {
      expect(result.status).toBe("fixed");
      expect(result.fixApplied).toBeDefined();
      // Verify files were actually installed
      expect(existsSync(join(tmpDir, "workflows", "default.yaml"))).toBe(true);
      expect(existsSync(join(tmpDir, "workflows", "smoke.yaml"))).toBe(true);
    });
  });

  it("passes immediately after fix", async () => {
    const { doctor } = makeMocks(tmpDir);
    await doctor.checkWorkflows({ fix: true });
    const result = await doctor.checkWorkflows();
    expect(result.status).toBe("pass");
  });

  it("dryRun=true takes precedence over fix=true", () => {
    const { doctor } = makeMocks(tmpDir);
    return doctor.checkWorkflows({ fix: true, dryRun: true }).then((result) => {
      // dryRun should report intent but not install
      expect(result.message).toMatch(/dry-run/i);
      expect(existsSync(join(tmpDir, "workflows", "default.yaml"))).toBe(false);
    });
  });

  it("detects stale workflow missing verdict/retryWith on reviewer phase", () => {
    // Install a default.yaml that exists but has a reviewer phase without verdict/retryWith
    const workflowsDir = join(tmpDir, "workflows");
    mkdirSync(workflowsDir, { recursive: true });
    // Stale format: reviewer phase lacks verdict and retryWith (old foreman init output)
    writeFileSync(
      join(workflowsDir, "default.yaml"),
      [
        "name: default",
        "phases:",
        "  - name: developer",
        "    prompt: developer.md",
        "  - name: qa",
        "    prompt: qa.md",
        "    retryOnFail: 2",    // missing verdict: true and retryWith
        "  - name: reviewer",
        "    prompt: reviewer.md",
        "    maxTurns: 20",       // missing verdict: true, retryWith, retryOnFail
        "  - name: finalize",
        "    prompt: finalize.md",
      ].join("\n"),
    );
    writeFileSync(join(workflowsDir, "smoke.yaml"), "name: smoke\nphases:\n  - name: finalize\n    builtin: true\n");
    writeFileSync(join(workflowsDir, "epic.yaml"), "name: epic\nphases:\n  - name: finalize\n    builtin: true\n");

    const { doctor } = makeMocks(tmpDir);
    return doctor.checkWorkflows().then((result) => {
      expect(result.status).toBe("fail");
      expect(result.message).toMatch(/stale/i);
    });
  });

  it("fix=true overwrites stale workflow files (force reinstall)", async () => {
    // Install a stale default.yaml missing verdict/retryWith
    const workflowsDir = join(tmpDir, "workflows");
    mkdirSync(workflowsDir, { recursive: true });
    writeFileSync(
      join(workflowsDir, "default.yaml"),
      "name: default\nphases:\n  - name: reviewer\n    prompt: reviewer.md\n",
    );
    writeFileSync(join(workflowsDir, "smoke.yaml"), "name: smoke\nphases:\n  - name: finalize\n    builtin: true\n");
    writeFileSync(join(workflowsDir, "epic.yaml"), "name: epic\nphases:\n  - name: finalize\n    builtin: true\n");

    const { doctor } = makeMocks(tmpDir);
    const fixResult = await doctor.checkWorkflows({ fix: true });
    expect(fixResult.status).toBe("fixed");

    // After fix, should pass (stale file overwritten with current bundled version)
    const checkResult = await doctor.checkWorkflows();
    expect(checkResult.status).toBe("pass");
  });
});
