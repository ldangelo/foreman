import { describe, it, expect } from 'vitest';
import { loadWorkflowConfig, resolveWorkflowName } from '../workflow-loader.js';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// TRD-009: End-to-end integration test for bug.yaml workflow
// Verifies that bug.yaml demonstrates all three new features:
// 1. command: phase (TRD-005)
// 2. bash: phase (TRD-004)
// 3. merge: auto (TRD-002, TRD-007)
// Also verifies type-based dispatch selects bug.yaml for bead type "bug" (TRD-006)

const BUNDLED_WORKFLOWS_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'defaults', 'workflows');

describe('TRD-009 bug.yaml workflow integration', () => {
  const bugWorkflow = loadWorkflowConfig('bug', BUNDLED_WORKFLOWS_DIR);

  describe('workflow metadata', () => {
    it('has name "bug"', () => {
      expect(bugWorkflow.name).toBe('bug');
    });

    it('has merge: auto', () => {
      expect(bugWorkflow.merge).toBe('auto');
    });
  });

  describe('TRD-005: command: phase (fix phase)', () => {
    const fixPhase = bugWorkflow.phases.find((p) => p.name === 'fix');

    it('fix phase exists', () => {
      expect(fixPhase).toBeDefined();
    });

    it('fix phase has command: field', () => {
      expect(fixPhase?.command).toBeDefined();
    });

    it('fix phase command contains task.* placeholder', () => {
      expect(fixPhase?.command).toContain('{task.title}');
      expect(fixPhase?.command).toContain('{task.description}');
    });

    it('fix phase has all standard phase config (model, maxTurns, artifact, mail)', () => {
      expect(fixPhase?.models).toBeDefined();
      expect(fixPhase?.maxTurns).toBe(80);
      expect(fixPhase?.artifact).toBe('DEVELOPER_REPORT.md');
      expect(fixPhase?.mail).toBeDefined();
    });

    it('fix phase uses MiniMax model by default', () => {
      expect(fixPhase?.models?.default).toBe('MiniMax');
    });
  });

  describe('TRD-004: bash: phase (test phase)', () => {
    const testPhase = bugWorkflow.phases.find((p) => p.name === 'test');

    it('test phase exists', () => {
      expect(testPhase).toBeDefined();
    });

    it('test phase has bash: field', () => {
      expect(testPhase?.bash).toBeDefined();
    });

    it('test phase bash command is npm run test', () => {
      expect(testPhase?.bash).toBe('npm run test');
    });

    it('test phase has artifact: TEST_RESULTS.md', () => {
      expect(testPhase?.artifact).toBe('TEST_RESULTS.md');
    });

    it('test phase has verdict: true', () => {
      expect(testPhase?.verdict).toBe(true);
    });

    it('test phase has retryWith: fix (cross-phase retry)', () => {
      expect(testPhase?.retryWith).toBe('fix');
    });

    it('test phase has retryOnFail: 2', () => {
      expect(testPhase?.retryOnFail).toBe(2);
    });
  });

  describe('TRD-006: type-based dispatch — bug type selects bug.yaml', () => {
    it('resolveWorkflowName("bug") returns "bug"', () => {
      expect(resolveWorkflowName('bug')).toBe('bug');
    });

    it('loadWorkflowConfig("bug") returns bug workflow', () => {
      const wf = loadWorkflowConfig('bug', BUNDLED_WORKFLOWS_DIR);
      expect(wf.name).toBe('bug');
    });

    it('bug type with no label → bug workflow', () => {
      expect(resolveWorkflowName('bug', [])).toBe('bug');
    });

    it('workflow: label still overrides bug type', () => {
      expect(resolveWorkflowName('bug', ['workflow:custom'])).toBe('custom');
    });
  });

  describe('phase ordering and finalize', () => {
    it('phases are in order: fix → test → finalize', () => {
      const names = bugWorkflow.phases.map((p) => p.name);
      expect(names).toEqual(['fix', 'test', 'finalize']);
    });

    it('finalize phase uses prompt: finalize.md', () => {
      const finalize = bugWorkflow.phases.find((p) => p.name === 'finalize');
      expect(finalize?.prompt).toBe('finalize.md');
    });

    it('finalize phase has verdict: true and retryWith: fix', () => {
      const finalize = bugWorkflow.phases.find((p) => p.name === 'finalize');
      expect(finalize?.verdict).toBe(true);
      expect(finalize?.retryWith).toBe('fix');
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
