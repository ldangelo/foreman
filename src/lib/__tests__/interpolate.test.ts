import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { interpolateTaskPlaceholders, type TaskMeta } from '../interpolate.js';

const mockWarn = vi.spyOn(console, 'warn').mockReturnValue(undefined);

const FULL_TASK: TaskMeta = {
  id: 'bd-001',
  title: 'Fix login timeout',
  description: 'Users cannot log in after 30 seconds',
  type: 'bug',
  priority: 1,
};

describe('interpolateTaskPlaceholders', () => {
  beforeEach(() => mockWarn.mockClear());
  afterEach(() => mockWarn.mockRestore());

  describe('supported placeholders', () => {
    it('interpolates {task.id}', () => {
      expect(interpolateTaskPlaceholders('Bead: {task.id}', FULL_TASK)).toBe('Bead: bd-001');
    });

    it('interpolates {task.title}', () => {
      expect(interpolateTaskPlaceholders('/fix {task.title}', FULL_TASK)).toBe('/fix Fix login timeout');
    });

    it('interpolates {task.description}', () => {
      const result = interpolateTaskPlaceholders('Issue: {task.description}', FULL_TASK);
      expect(result).toBe('Issue: Users cannot log in after 30 seconds');
    });

    it('interpolates {task.type}', () => {
      expect(interpolateTaskPlaceholders('Type: {task.type}', FULL_TASK)).toBe('Type: bug');
    });

    it('interpolates {task.priority}', () => {
      expect(interpolateTaskPlaceholders('Priority: {task.priority}', FULL_TASK)).toBe('Priority: 1');
    });

    it('handles multiple placeholders in one template', () => {
      const result = interpolateTaskPlaceholders(
        '{task.id} [{task.priority}] {task.type}: {task.title}',
        FULL_TASK,
      );
      expect(result).toBe('bd-001 [1] bug: Fix login timeout');
    });
  });

  describe('unknown placeholders', () => {
    it('leaves unknown placeholder as-is', () => {
      expect(interpolateTaskPlaceholders('Unknown: {task.unknown}', FULL_TASK)).toBe(
        'Unknown: {task.unknown}',
      );
    });

    it('logs a warning for unknown placeholder', () => {
      const warnCalls: string[] = [];
      const originalWarn = console.warn;
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (console as any).warn = (msg: string) => warnCalls.push(msg);
      try {
        interpolateTaskPlaceholders('{task.unknown}', FULL_TASK);
        expect(warnCalls.length).toBe(1);
        expect(warnCalls[0]).toContain('Unknown placeholder');
      } finally {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        (console as any).warn = originalWarn;
      }
    });

    it('leaves partially-known prefix as-is without warning', () => {
      mockWarn.mockClear();
      const result = interpolateTaskPlaceholders('{task.}', FULL_TASK);
      expect(result).toBe('{task.}');
      // Not a valid placeholder pattern, so no warning
      expect(mockWarn).not.toHaveBeenCalled();
    });
  });

  describe('escaped braces', () => {
    it('escaped placeholder emits literal braces', () => {
      expect(interpolateTaskPlaceholders('Literal: \\{task.title\\}', FULL_TASK)).toBe(
        'Literal: {task.title}',
      );
    });

    it('escaped unknown placeholder emits literal {task.unknown}', () => {
      expect(interpolateTaskPlaceholders('Escaped unknown: \\{task.unknown\\}', FULL_TASK)).toBe(
        'Escaped unknown: {task.unknown}',
      );
    });

    it('mixed escaped and unescaped placeholders', () => {
      const result = interpolateTaskPlaceholders(
        '\\{task.title\\} is \"{task.title}\"',
        FULL_TASK,
      );
      expect(result).toBe('{task.title} is "Fix login timeout"');
    });

    it('leftover backslash before non-placeholder emits backslash', () => {
      expect(interpolateTaskPlaceholders('\\{task.title', FULL_TASK)).toBe('\\{task.title');
    });
  });

  describe('empty/null fields', () => {
    const emptyTask: TaskMeta = {
      id: '',
      title: '',
      description: '',
      type: '',
      priority: 0,
    };

    it('empty fields interpolate as empty string', () => {
      expect(interpolateTaskPlaceholders('ID={task.id}', emptyTask)).toBe('ID=');
    });

    it('empty title in template produces empty substitution', () => {
      expect(interpolateTaskPlaceholders('/fix {task.title}', emptyTask)).toBe('/fix ');
    });
  });

  describe('no placeholders', () => {
    it('template with no placeholders passes through unchanged', () => {
      expect(interpolateTaskPlaceholders('Plain text with no placeholders', FULL_TASK)).toBe(
        'Plain text with no placeholders',
      );
    });

    it('empty template returns empty string', () => {
      expect(interpolateTaskPlaceholders('', FULL_TASK)).toBe('');
    });
  });

  describe('priority field type', () => {
    it('priority is converted to string in output', () => {
      expect(interpolateTaskPlaceholders('{task.priority}', FULL_TASK)).toBe('1');
    });

    it('zero priority interpolates as "0"', () => {
      const zeroPriority: TaskMeta = { ...FULL_TASK, priority: 0 };
      expect(interpolateTaskPlaceholders('{task.priority}', zeroPriority)).toBe('0');
    });
  });
});
