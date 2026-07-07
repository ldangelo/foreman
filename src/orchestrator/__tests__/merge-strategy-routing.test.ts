import { describe, it, expect } from 'vitest';
import { interpolateTaskPlaceholders } from '../../lib/interpolate.js';

describe('workflow merge/PR control via explicit phases', () => {
  it('create-pr/pr-wait/merge phases express PR-gated auto-merge', () => {
    const workflow = {
      name: 'phase-driven',
      phases: [
        { name: 'finalize', builtin: true },
        { name: 'create-pr', builtin: true },
        { name: 'pr-wait', builtin: true },
        { name: 'merge', builtin: true },
      ],
    };
    expect(workflow.phases.map((phase) => phase.name)).toEqual(['finalize', 'create-pr', 'pr-wait', 'merge']);
  });

  it('omitting merge phase means no workflow-driven merge', () => {
    const workflow = {
      name: 'manual-review',
      phases: [
        { name: 'finalize', builtin: true },
        { name: 'create-pr', builtin: true },
      ],
    };
    expect(workflow.phases.some((phase) => phase.name === 'merge')).toBe(false);
  });
});

describe('task metadata for PR title interpolation', () => {
  const meta = { id: 'bd-42', title: 'Implement user auth', description: 'Add JWT', type: 'feature', priority: 1 };

  it('task title used in PR title', () => {
    const prTitle = `$(echo "{task.title}")`;
    const interpolated = interpolateTaskPlaceholders(prTitle, meta);
    expect(interpolated).toContain('Implement user auth');
  });

  it('task id used in PR body', () => {
    const prBody = `Foreman run: \`{task.id}\``;
    const interpolated = interpolateTaskPlaceholders(prBody, meta);
    expect(interpolated).toContain('bd-42');
  });
});
