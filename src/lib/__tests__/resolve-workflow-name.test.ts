import { describe, it, expect } from 'vitest';
import { resolveWorkflowName } from '../workflow-loader.js';

describe('resolveWorkflowName (TRD-006)', () => {
  describe('label override — highest priority', () => {
    it('returns label value when workflow: label present', () => {
      expect(resolveWorkflowName('bug', ['frontend', 'workflow:custom-wf'])).toBe('custom-wf');
      expect(resolveWorkflowName('epic', ['workflow:experimental'])).toBe('experimental');
    });

    it('returns label value even when seedType matches a bundled workflow', () => {
      // Label override takes priority over type-based resolution
      expect(resolveWorkflowName('smoke', ['workflow:override-wf'])).toBe('override-wf');
      expect(resolveWorkflowName('bug', ['workflow:override-wf'])).toBe('override-wf');
    });

    it('handles missing labels gracefully', () => {
      expect(resolveWorkflowName('chore', [])).toBe('default');
      expect(resolveWorkflowName('chore', undefined)).toBe('default');
    });
  });

  describe('type-based resolution (TRD-006)', () => {
    it('smoke type maps to smoke.yaml when it exists in bundled workflows', () => {
      // smoke.yaml exists in defaults/workflows/
      expect(resolveWorkflowName('smoke')).toBe('smoke');
    });

    it('epic type maps to epic.yaml when it exists in bundled workflows', () => {
      // epic.yaml exists in defaults/workflows/
      expect(resolveWorkflowName('epic')).toBe('epic');
    });

    it('returns default when no matching workflow file exists', () => {
      // These types have no corresponding workflow file in defaults/workflows/
      expect(resolveWorkflowName('feature')).toBe('default');
      expect(resolveWorkflowName('chore')).toBe('default');
      expect(resolveWorkflowName('docs')).toBe('default');
      expect(resolveWorkflowName('question')).toBe('default');
      expect(resolveWorkflowName('task')).toBe('default');
    });

    it('empty seedType falls back to default', () => {
      expect(resolveWorkflowName('')).toBe('default');
      expect(resolveWorkflowName('')).toBe('default');
    });
  });

  describe('priority: label > type-based > default', () => {
    it('label wins over type-based', () => {
      expect(resolveWorkflowName('bug', ['workflow:special'])).toBe('special');
    });

    it('type-based wins over default', () => {
      // smoke.yaml exists
      expect(resolveWorkflowName('smoke', [])).toBe('smoke');
    });

    it('no label, no matching file → default', () => {
      // chore.yaml does not exist
      expect(resolveWorkflowName('chore', [])).toBe('default');
    });
  });

  // TRD-008: bug.yaml now exists, so bug type → bug workflow
  describe('TRD-008: bug.yaml bundled workflow (TRD-008)', () => {
    it('bug type maps to bug.yaml when it exists in bundled workflows', () => {
      // bug.yaml exists in defaults/workflows/ (TRD-008)
      expect(resolveWorkflowName('bug')).toBe('bug');
    });

    it('bug type without label → bug workflow (TRD-008)', () => {
      expect(resolveWorkflowName('bug', [])).toBe('bug');
    });
  });
});
