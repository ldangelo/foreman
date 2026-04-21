import { describe, it, expect } from 'vitest';
import { validateWorkflowConfig } from '../workflow-loader.js';
import { WorkflowConfigError } from '../workflow-loader.js';

describe('validateWorkflowConfig — bash/command/merge fields', () => {
  describe('phase type: exactly one of bash, command, prompt', () => {
    it('accepts a phase with bash: only', () => {
      const config = validateWorkflowConfig(
        { name: 'test', phases: [{ name: 'test-phase', bash: 'npm run test' }] },
        'test',
      );
      expect(config.phases[0]!.bash).toBe('npm run test');
    });

    it('accepts a phase with command: only', () => {
      const config = validateWorkflowConfig(
        { name: 'test', phases: [{ name: 'test-phase', command: '/ensemble:fix {task.title}' }] },
        'test',
      );
      expect(config.phases[0]!.command).toBe('/ensemble:fix {task.title}');
    });

    it('accepts a phase with prompt: only (existing behavior)', () => {
      const config = validateWorkflowConfig(
        { name: 'test', phases: [{ name: 'test-phase', prompt: 'explorer.md' }] },
        'test',
      );
      expect(config.phases[0]!.prompt).toBe('explorer.md');
    });

    it('throws when a phase has both bash: and prompt:', () => {
      expect(() =>
        validateWorkflowConfig(
          {
            name: 'test',
            phases: [{ name: 'test-phase', bash: 'npm test', prompt: 'test.md' }],
          },
          'test',
        ),
      ).toThrow(WorkflowConfigError);
    });

    it('throws when a phase has both bash: and command:', () => {
      expect(() =>
        validateWorkflowConfig(
          {
            name: 'test',
            phases: [{ name: 'test-phase', bash: 'npm test', command: '/do something' }],
          },
          'test',
        ),
      ).toThrow(WorkflowConfigError);
    });

    it('throws when a phase has both command: and prompt:', () => {
      expect(() =>
        validateWorkflowConfig(
          {
            name: 'test',
            phases: [{ name: 'test-phase', command: '/do something', prompt: 'test.md' }],
          },
          'test',
        ),
      ).toThrow(WorkflowConfigError);
    });

    it('throws when a phase has none of bash:, command:, or prompt:', () => {
      expect(() =>
        validateWorkflowConfig(
          {
            name: 'test',
            phases: [{ name: 'test-phase', maxTurns: 30 }],
          },
          'test',
        ),
      ).toThrow(WorkflowConfigError);
    });

    it('error message mentions both conflicting fields for bash+prompt', () => {
      try {
        validateWorkflowConfig(
          {
            name: 'test',
            phases: [{ name: 'test-phase', bash: 'npm test', prompt: 'test.md' }],
          },
          'test',
        );
        expect.fail('Should have thrown');
      } catch (e) {
        expect((e as Error).message).toContain('bash');
        expect((e as Error).message).toContain('prompt');
      }
    });

    it('error message mentions missing fields when none of bash/command/prompt provided', () => {
      try {
        validateWorkflowConfig(
          { name: 'test', phases: [{ name: 'test-phase' }] },
          'test',
        );
        expect.fail('Should have thrown');
      } catch (e) {
        expect((e as Error).message).toContain('prompt');
        expect((e as Error).message).toContain('bash');
        expect((e as Error).message).toContain('command');
      }
    });
  });

  describe('merge strategy field', () => {
    it('accepts merge: auto', () => {
      const config = validateWorkflowConfig(
        { name: 'test', phases: [{ name: 'p', prompt: 'x.md' }], merge: 'auto' },
        'test',
      );
      expect(config.merge).toBe('auto');
    });

    it('accepts merge: pr', () => {
      const config = validateWorkflowConfig(
        { name: 'test', phases: [{ name: 'p', prompt: 'x.md' }], merge: 'pr' },
        'test',
      );
      expect(config.merge).toBe('pr');
    });

    it('accepts merge: none', () => {
      const config = validateWorkflowConfig(
        { name: 'test', phases: [{ name: 'p', prompt: 'x.md' }], merge: 'none' },
        'test',
      );
      expect(config.merge).toBe('none');
    });

    it('defaults to undefined when absent', () => {
      const config = validateWorkflowConfig(
        { name: 'test', phases: [{ name: 'p', prompt: 'x.md' }] },
        'test',
      );
      expect(config.merge).toBeUndefined();
    });

    it('throws when merge: has an invalid value', () => {
      expect(() =>
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        validateWorkflowConfig({ name: 'test', phases: [{ name: 'p', prompt: 'x.md' }], merge: 'invalid' } as any, 'test'),
      ).toThrow(WorkflowConfigError);
    });

    it('error message for invalid merge value lists valid values', () => {
      try {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        validateWorkflowConfig({ name: 'test', phases: [{ name: 'p', prompt: 'x.md' }], merge: 'invalid' } as any, 'test');
        expect.fail('Should have thrown');
      } catch (e) {
        expect((e as Error).message).toContain('auto');
        expect((e as Error).message).toContain('pr');
        expect((e as Error).message).toContain('none');
      }
    });
  });
});
