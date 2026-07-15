import { describe, it, expect } from 'vitest';
import { loadWorkflowConfig, resolveWorkflowName } from '../workflow-loader.js';
import { join, dirname } from 'node:path';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

// TRD-009: End-to-end integration test for bug.yaml workflow
// 1. workflow-scoped fix prompt (fix-issue.md)
// 2. QA validation phase with developer remediation on failure
// 3. explicit create-pr/pr-wait/merge phases
// Also verifies type-based dispatch selects bug.yaml for task type "bug" (TRD-006)

const BUNDLED_WORKFLOWS_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'defaults', 'workflows');

function loadBundledBugWorkflow() {
  const originalHome = process.env.HOME;
  const originalForemanHome = process.env.FOREMAN_HOME;
  const tempHome = mkdtempSync(join(tmpdir(), 'foreman-bug-workflow-test-'));
  process.env.HOME = tempHome;
  process.env.FOREMAN_HOME = tempHome;
  try {
    return loadWorkflowConfig('bug', BUNDLED_WORKFLOWS_DIR);
  } finally {
    if (originalHome === undefined) {
      delete process.env.HOME;
    } else {
      process.env.HOME = originalHome;
    }
    if (originalForemanHome === undefined) {
      delete process.env.FOREMAN_HOME;
    } else {
      process.env.FOREMAN_HOME = originalForemanHome;
    }
    rmSync(tempHome, { recursive: true, force: true });
  }
}

describe('TRD-009 bug.yaml workflow integration', () => {
  const bugWorkflow = loadBundledBugWorkflow();

  describe('workflow metadata', () => {
    it('has name "bug"', () => {
      expect(bugWorkflow.name).toBe('bug');
    });

    it('has explicit PR and merge phases', () => {
      expect(bugWorkflow.phases.map((p) => p.name)).toEqual(expect.arrayContaining(['create-pr', 'pr-wait', 'merge']));
    });
  });

  describe('workflow-scoped fix prompt (fix phase)', () => {
    const fixPhase = bugWorkflow.phases.find((p) => p.name === 'fix');

    it('fix phase exists', () => {
      expect(fixPhase).toBeDefined();
    });

    it('fix phase has prompt: field', () => {
      expect(fixPhase?.prompt).toBe('fix-issue.md');
      expect(fixPhase?.command).toBeUndefined();
    });

    it('fix phase has all standard phase config (model, maxTurns, artifact, mail)', () => {
      expect(fixPhase?.models).toBeDefined();
      expect(fixPhase?.maxTurns).toBe(500);
      expect(fixPhase?.artifact).toBe('{task.projectReportsDir}/DEVELOPER_REPORT.md');
      expect(fixPhase?.mail).toBeDefined();
    });

    it('fix phase uses MiniMax model by default', () => {
      expect(fixPhase?.models?.default).toBe('MiniMax');
    });
  });

  describe('QA validation phase', () => {
    const qaPhase = bugWorkflow.phases.find((p) => p.name === 'qa');

    it('qa phase exists', () => {
      expect(qaPhase).toBeDefined();
    });

    it('qa phase uses qa prompt', () => {
      expect(qaPhase?.prompt).toBe('qa.md');
    });

    it('qa phase has artifact: QA_REPORT.md', () => {
      expect(qaPhase?.artifact).toBe('{task.projectReportsDir}/QA_REPORT.md');
    });

    it('qa phase has verdict: true', () => {
      expect(qaPhase?.verdict).toBe(true);
    });

    it('qa phase retries through generic developer remediation', () => {
      expect(qaPhase?.retryWith).toBe('developer');
    });

    it('qa phase has retryOnFail: 2', () => {
      expect(qaPhase?.retryOnFail).toBe(2);
    });
  });

  describe('TRD-006: type-based dispatch — bug type selects bug.yaml', () => {
    it('resolveWorkflowName("bug") returns "bug"', () => {
      expect(resolveWorkflowName('bug')).toBe('bug');
    });

    it('loadWorkflowConfig("bug") returns bug workflow', () => {
      const originalForemanHome = process.env.FOREMAN_HOME;
      const tempHome = mkdtempSync(join(tmpdir(), 'foreman-bug-workflow-load-'));
      process.env.FOREMAN_HOME = tempHome;
      try {
        const wf = loadWorkflowConfig('bug', BUNDLED_WORKFLOWS_DIR);
        expect(wf.name).toBe('bug');
      } finally {
        if (originalForemanHome === undefined) {
          delete process.env.FOREMAN_HOME;
        } else {
          process.env.FOREMAN_HOME = originalForemanHome;
        }
        rmSync(tempHome, { recursive: true, force: true });
      }
    });

    it('bug type with no label → bug workflow', () => {
      expect(resolveWorkflowName('bug', [])).toBe('bug');
    });

    it('workflow: label still overrides bug type', () => {
      expect(resolveWorkflowName('bug', ['workflow:custom'])).toBe('custom');
    });
  });

  describe('phase ordering and finalize', () => {
    it("phases are in order: explorer → fix → developer → qa → documentation → cicd-developer (retryOnly) → finalize", () => {
      const names = bugWorkflow.phases.map((p) => p.name);
      // New order: developer (normal), qa before documentation, retry-only devs after documentation
      expect(names).toEqual([
        "explorer",
        "fix",
        "developer",
        "qa",
        "cicd-developer",
        "cr-developer",
        "merge-resolver",
        "documentation",
        "finalize",
        "create-pr",
        "pr-wait",
        "merge",
      ]);
      // developer is a normal phase (REC-2)
      expect(bugWorkflow.phases.find((p) => p.name === "developer")?.retryOnly).toBeUndefined();
      // qa runs before documentation (REC-3)
      expect(names.indexOf("qa")).toBeLessThan(names.indexOf("documentation"));
      // cicd-developer, cr-developer, merge-resolver remain retry-only
      expect(bugWorkflow.phases.find((p) => p.name === "cicd-developer")?.retryOnly).toBe(true);
      expect(bugWorkflow.phases.find((p) => p.name === "cr-developer")?.retryOnly).toBe(true);
      expect(bugWorkflow.phases.find((p) => p.name === "merge-resolver")?.retryOnly).toBe(true);
      expect(bugWorkflow.phases.find((p) => p.name === "cli-review")).toBeUndefined();
      expect(bugWorkflow.phases.find((p) => p.name === "pr-review")).toBeUndefined();
    });

    it('finalize phase uses the deterministic builtin finalizer', () => {
      const finalize = bugWorkflow.phases.find((p) => p.name === 'finalize');
      expect(finalize?.builtin).toBe(true);
      expect(finalize?.prompt).toBeUndefined();
    });

    it('finalize phase has verdict: true and retries through developer remediation', () => {
      const finalize = bugWorkflow.phases.find((p) => p.name === 'finalize');
      expect(finalize?.verdict).toBe(true);
      expect(finalize?.retryWith).toBe('developer');
    });
  });

  describe('setup and config', () => {
    it('has setup steps', () => {
      expect(bugWorkflow.setup).toBeDefined();
      expect(bugWorkflow.setup).toHaveLength(1);
      expect(bugWorkflow.setup![0].command).toContain('npm install');
    });

    it('has setupCache for node_modules', () => {
      expect(bugWorkflow.setupCache).toBeDefined();
      expect(bugWorkflow.setupCache?.path).toBe('node_modules');
    });
  });
});
