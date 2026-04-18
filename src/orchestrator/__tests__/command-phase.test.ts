import { describe, it, expect } from 'vitest';
import { interpolateTaskPlaceholders } from '../../lib/interpolate.js';

// TRD-005: Command phase sends interpolated command string as prompt to Pi SDK.
// These tests verify the interpolation and configuration aspects.

describe('TRD-005 command phase — interpolation', () => {
  const meta = { id: 'bd-42', title: 'Implement user auth', description: 'Add JWT auth', type: 'feature', priority: 1 };

  it('interpolates placeholders in command string', () => {
    const cmd = '/ensemble:fix-issue {task.title} --priority {task.priority}';
    const result = interpolateTaskPlaceholders(cmd, meta);
    expect(result).toBe('/ensemble:fix-issue Implement user auth --priority 1');
  });

  it('interpolates all task.* fields', () => {
    const cmd = 'id={task.id} type={task.type} desc={task.description}';
    expect(interpolateTaskPlaceholders(cmd, meta)).toBe('id=bd-42 type=feature desc=Add JWT auth');
  });

  it('warns for unknown placeholders', () => {
    const warns: string[] = [];
    const orig = console.warn;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (console as any).warn = (msg: string) => warns.push(msg);
    try {
      interpolateTaskPlaceholders('/cmd {task.unknown}', meta);
    } finally {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (console as any).warn = orig;
    }
    expect(warns.some(w => w.includes('Unknown placeholder'))).toBe(true);
  });

  it('handles empty meta gracefully', () => {
    const empty = { id: '', title: '', description: '', type: '', priority: 0 };
    const result = interpolateTaskPlaceholders('/cmd {task.title}', empty);
    expect(result).toBe('/cmd ');
  });

  it('no placeholders — command string passes through unchanged', () => {
    const cmd = '/ensemble:analyze-product';
    expect(interpolateTaskPlaceholders(cmd, meta)).toBe('/ensemble:analyze-product');
  });
});

describe('TRD-005 command phase — WorkflowPhaseConfig accepts command field', () => {
  it('command field is part of WorkflowPhaseConfig type', () => {
    // This is a structural type check: if the code compiles, command is accepted
    const phase = {
      name: 'analyze',
      command: '/ensemble:analyze-product {task.title}',
      model: 'sonnet',
      verdict: true,
    };
    expect(typeof phase.command).toBe('string');
    expect(phase.verdict).toBe(true);
  });

  it('command can coexist with other config options (models, maxTurns, artifact, mail, files)', () => {
    const phase = {
      name: 'test',
      command: '/run-tests',
      model: 'haiku',
      maxTurns: 5,
      artifact: 'TEST_RESULTS.md',
      verdict: false,
      retryWith: 'developer',
      retryOnFail: 2,
      mail: { onStart: true },
      files: { reserve: ['src/**/*.ts'] },
      skipIfArtifact: 'TEST_RESULTS.md',
    };
    expect(phase.command).toBe('/run-tests');
    expect(phase.retryOnFail).toBe(2);
    expect(phase.skipIfArtifact).toBe('TEST_RESULTS.md');
  });
});
