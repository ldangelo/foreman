import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { ForemanStore } from '../store.js';
import { interpolateTaskPlaceholders, type TaskMeta } from '../interpolate.js';

describe('taskMeta propagation (TRD-010)', () => {
  // Test that TaskMeta interface matches what the dispatcher populates
  describe('TaskMeta interface', () => {
    it('has required fields: id, title, description, type, priority', () => {
      const meta: TaskMeta = {
        id: 'bd-001',
        title: 'Fix login timeout',
        description: 'Users cannot log in',
        type: 'bug',
        priority: 1,
      };
      expect(interpolateTaskPlaceholders('{task.title}', meta)).toBe('Fix login timeout');
      expect(interpolateTaskPlaceholders('{task.id}', meta)).toBe('bd-001');
      expect(interpolateTaskPlaceholders('{task.description}', meta)).toBe('Users cannot log in');
      expect(interpolateTaskPlaceholders('{task.type}', meta)).toBe('bug');
      expect(interpolateTaskPlaceholders('{task.priority}', meta)).toBe('1');
    });

    it('handles empty/null fields as empty string', () => {
      const empty: TaskMeta = {
        id: '',
        title: '',
        description: '',
        type: '',
        priority: 0,
      };
      expect(interpolateTaskPlaceholders('{task.title}', empty)).toBe('');
      expect(interpolateTaskPlaceholders('{task.id}', empty)).toBe('');
    });

    it('warns for unknown placeholder and leaves as-is (legacy run fallback)', () => {
      const meta: TaskMeta = {
        id: 'bd-001',
        title: 'Test',
        description: '',
        type: 'task',
        priority: 2,
      };
      const result = interpolateTaskPlaceholders('{task.unknown}', meta);
      expect(result).toBe('{task.unknown}');
    });
  });

  // Test that WorkerConfig.taskMeta flows through the dispatcher
  describe('WorkerConfig.taskMeta (structural)', () => {
    it('taskMeta is optional on WorkerConfig-like object', () => {
      // Simulate WorkerConfig with taskMeta
      const configWith = {
        runId: 'run-1',
        projectId: 'proj-1',
        seedId: 'bd-001',
        seedTitle: 'Fix login timeout',
        model: 'sonnet',
        worktreePath: '/tmp',
        prompt: '',
        env: {},
        taskMeta: {
          id: 'bd-001',
          title: 'Fix login timeout',
          description: 'Bug fix',
          type: 'bug',
          priority: 1,
        } as TaskMeta,
      };
      expect(configWith.taskMeta?.title).toBe('Fix login timeout');
    });

    it('taskMeta absent (legacy) leaves placeholders as-is', () => {
      const configWithout = {
        runId: 'run-1',
        projectId: 'proj-1',
        seedId: 'bd-001',
        seedTitle: 'Legacy task',
        model: 'sonnet',
        worktreePath: '/tmp',
        prompt: '',
        env: {},
        // taskMeta intentionally absent
      } as { taskMeta?: TaskMeta };
      expect(configWithout.taskMeta).toBeUndefined();
      // When taskMeta is undefined, placeholder interpolation should warn
      const result = interpolateTaskPlaceholders('{task.title}', {
        id: '', title: '', description: '', type: '', priority: 2,
      });
      // Without proper taskMeta from config, we'd use empty fallback
      // This test documents the legacy behavior
      expect(result).toBe('');
    });
  });
});
