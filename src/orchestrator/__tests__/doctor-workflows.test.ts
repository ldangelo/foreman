/**
 * Tests for Doctor.checkWorkflows()
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Doctor } from "../doctor.js";

// Mock git module (required by Doctor constructor chain)
vi.mock("../../lib/git.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../lib/git.js")>();
  return {
    ...actual,
    listWorktrees: vi.fn().mockResolvedValue([]),
    removeWorktree: vi.fn(),
    branchExistsOnOrigin: vi.fn().mockResolvedValue(false),
    detectDefaultBranch: vi.fn(),
  };
});

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
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("passes when all bundled workflows are installed", () => {
    // Install both default.yaml and smoke.yaml
    const workflowsDir = join(tmpDir, ".foreman", "workflows");
    mkdirSync(workflowsDir, { recursive: true });
    writeFileSync(join(workflowsDir, "default.yaml"), "name: default\nphases:\n  - name: finalize\n    builtin: true\n");
    writeFileSync(join(workflowsDir, "smoke.yaml"), "name: smoke\nphases:\n  - name: finalize\n    builtin: true\n");

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
      expect(result.message).toMatch(/missing workflow/i);
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
      expect(existsSync(join(tmpDir, ".foreman", "workflows", "default.yaml"))).toBe(true);
      expect(existsSync(join(tmpDir, ".foreman", "workflows", "smoke.yaml"))).toBe(true);
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
      expect(existsSync(join(tmpDir, ".foreman", "workflows", "default.yaml"))).toBe(false);
    });
  });
});
