import { describe, it, expect } from 'vitest';
import { resolveWorkflowName } from '../workflow-loader.js';

describe('resolveWorkflowName (TRD-006)', () => {
  describe('label override — highest priority', () => {
    it('returns label value when workflow: label present', () => {
      expect(resolveWorkflowName('bug', ['frontend', 'workflow:custom-wf'])).toBe('custom-wf');
      expect(resolveWorkflowName('epic', ['workflow:experimental'])).toBe('experimental');
    });

    it('returns label value even when taskType matches a bundled workflow', () => {
      // Label override takes priority over type-based resolution
      expect(resolveWorkflowName('smoke', ['workflow:override-wf'])).toBe('override-wf');
      expect(resolveWorkflowName('bug', ['workflow:override-wf'])).toBe('override-wf');
    });

    it('handles missing labels gracefully', () => {
      expect(resolveWorkflowName('unknown', [])).toBe('default');
      expect(resolveWorkflowName('unknown', undefined)).toBe('default');
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
      // Types with no corresponding workflow file fall back to default
      expect(resolveWorkflowName('unknown')).toBe('default');
      expect(resolveWorkflowName('random')).toBe('default');
    });

    it('empty taskType falls back to default', () => {
      expect(resolveWorkflowName('')).toBe('default');
      expect(resolveWorkflowName('')).toBe('default');
    });

    it('feature type maps to feature.yaml (workflows for all types)', () => {
      expect(resolveWorkflowName('feature')).toBe('feature');
    });

    it('removed workflow task types fall back to default without a configured mapping', () => {
      expect(resolveWorkflowName('chore')).toBe('default');
      expect(resolveWorkflowName('docs')).toBe('default');
      expect(resolveWorkflowName('question')).toBe('default');
    });

    it('task type maps to task.yaml (workflows for all types)', () => {
      expect(resolveWorkflowName('task')).toBe('task');
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
      expect(resolveWorkflowName('unknown', [])).toBe('default');
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

  // taskTypeWorkflowMap config-driven routing (foreman-676ac)
  describe('taskTypeWorkflowMap config-driven routing', () => {
    it('label override takes priority over config mapping', () => {
      const map = { bug: 'bug', feature: 'feature' };
      expect(resolveWorkflowName('bug', ['workflow:custom'], map)).toBe('custom');
      expect(resolveWorkflowName('feature', ['workflow:override'], map)).toBe('override');
    });

    it('ignores stale workflow task_type declarations when the workflow file is absent', () => {
      const map = { docs: 'task' };
      expect(resolveWorkflowName('docs', [], map, undefined, { docs: 'docs' })).toBe('task');
    });

    it('config mapping "default" key used when type not explicitly mapped', () => {
      // "unknown" type has no explicit mapping, falls to "default" from config
      const map = { default: 'feature' };
      expect(resolveWorkflowName('unknown', [], map)).toBe('feature');
      expect(resolveWorkflowName('random', [], map)).toBe('feature');
    });

    it('workflow task_type mapping takes priority over config default', () => {
      const map = { bug: 'smoke', default: 'default' };
      expect(resolveWorkflowName('bug', [], map, undefined, { bug: 'bug' })).toBe('bug');
      // "unknown" is not declared or explicitly mapped, so falls to "default" from config
      expect(resolveWorkflowName('unknown', [], map)).toBe('default');
    });

    it('without config mapping, behavior is unchanged (backward compatible)', () => {
      // No third argument — should behave exactly like before
      expect(resolveWorkflowName('bug')).toBe('bug');
      expect(resolveWorkflowName('feature')).toBe('feature');
      expect(resolveWorkflowName('smoke')).toBe('smoke');
      expect(resolveWorkflowName('unknown')).toBe('default');
    });

    it('empty taskTypeWorkflowMap falls back to file-existence check', () => {
      const emptyMap = {};
      // "bug" has bug.yaml in bundled workflows
      expect(resolveWorkflowName('bug', [], emptyMap)).toBe('bug');
      // "unknown" has no corresponding file, falls to "default"
      expect(resolveWorkflowName('unknown', [], emptyMap)).toBe('default');
    });

    it('maps undeclared task type to different workflow via config', () => {
      const map = { docs: 'task', spike: 'feature' };
      expect(resolveWorkflowName('docs', [], map, undefined, { docs: 'docs' })).toBe('task');
      expect(resolveWorkflowName('spike', [], map)).toBe('feature');
    });

    it('handles identity mapping (type → same name)', () => {
      const map = { bug: 'bug', task: 'task', feature: 'feature' };
      expect(resolveWorkflowName('bug', [], map)).toBe('bug');
      expect(resolveWorkflowName('task', [], map)).toBe('task');
      expect(resolveWorkflowName('feature', [], map)).toBe('feature');
    });

    it('ignores invalid mapped workflows and falls back to normal resolution', () => {
      expect(resolveWorkflowName('bug', [], { bug: 'nonexistent' })).toBe('bug');
      expect(resolveWorkflowName('unknown', [], { unknown: 'nonexistent' })).toBe('default');
      expect(resolveWorkflowName('unknown', [], { default: 'nonexistent' })).toBe('default');
    });

    it('unknown type without config default falls back to default when no workflow file exists', () => {
      expect(resolveWorkflowName('question', [])).toBe('default');
    });
  });
});
