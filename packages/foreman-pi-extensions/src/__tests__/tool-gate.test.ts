/**
 * Tests for foreman-tool-gate extension.
 *
 * Covers all 8 acceptance criteria from TRD-003:
 * 1. Explorer phase + allowed=[Read,Grep,Glob]: Bash call → blocked
 * 2. Explorer phase + allowed=[Read,Grep,Glob]: Read call → allowed
 * 3. Developer phase + full allowlist: Write call → allowed
 * 4. Custom FOREMAN_BASH_BLOCKLIST: Bash("git push --force origin main") → blocked
 * 5. Default blocklist: Bash("npm test") → allowed
 * 6. Any phase: Write to ".beads/issues.jsonl" → blocked
 * 7. auditCallback is called on each block with tool name, phase, blocked=true, reason
 * 8. FOREMAN_ALLOWED_TOOLS not set → all tools allowed
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import {
  createToolGateExtension,
  DEFAULT_BASH_BLOCKLIST,
  toolGate,
} from '../tool-gate.js';
import type { ForemanExtension, ToolCallEvent, ExtensionContext, ToolCallResult } from '../types.js';

/**
 * The ForemanExtension interface allows onToolCall to return
 * ToolCallResult | Promise<ToolCallResult>.  The tool-gate implementation
 * is always synchronous, so we cast away the Promise branch here so that
 * the test assertions can access .block / .reason without TypeScript errors.
 */
function callSync(
  ext: ForemanExtension,
  event: ToolCallEvent,
  ctx: ExtensionContext,
): ToolCallResult {
  return ext.onToolCall!(event, ctx) as ToolCallResult;
}

// Minimal stub for ExtensionContext — hooks only use env vars, not ctx directly
function makeCtx(phase = 'unknown'): ExtensionContext {
  return {
    phase,
    runId: 'run-test',
    seedId: 'seed-test',
    getContextUsage: () => ({ totalTokens: 0, inputTokens: 0, outputTokens: 0 }),
    log: () => undefined,
  };
}

function makeEvent(toolName: string, input: ToolCallEvent['input'] = {}): ToolCallEvent {
  return { toolName, input };
}

// Save originals so we can restore them
const ENV_KEYS = ['FOREMAN_ALLOWED_TOOLS', 'FOREMAN_PHASE', 'FOREMAN_BASH_BLOCKLIST'];
let savedEnv: Record<string, string | undefined> = {};

beforeEach(() => {
  savedEnv = {};
  for (const key of ENV_KEYS) {
    savedEnv[key] = process.env[key];
    delete process.env[key];
  }
});

afterEach(() => {
  for (const key of ENV_KEYS) {
    if (savedEnv[key] === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = savedEnv[key];
    }
  }
});

// ── Acceptance Criteria 1 ──────────────────────────────────────────────────
describe('AC1: Explorer phase — Bash blocked when not in allowlist', () => {
  it('blocks Bash call when FOREMAN_ALLOWED_TOOLS is Read,Grep,Glob', () => {
    process.env.FOREMAN_ALLOWED_TOOLS = 'Read,Grep,Glob';
    process.env.FOREMAN_PHASE = 'explorer';
    const ext = createToolGateExtension();
    const result = callSync(ext, makeEvent('Bash', { command: 'npm test' }), makeCtx('explorer'));
    expect(result).toBeDefined();
    expect(result!.block).toBe(true);
    expect(result!.reason).toMatch(/not allowed in explorer phase/i);
  });
});

// ── Acceptance Criteria 2 ──────────────────────────────────────────────────
describe('AC2: Explorer phase — Read allowed when in allowlist', () => {
  it('returns undefined (allow) for Read when FOREMAN_ALLOWED_TOOLS=Read,Grep,Glob', () => {
    process.env.FOREMAN_ALLOWED_TOOLS = 'Read,Grep,Glob';
    process.env.FOREMAN_PHASE = 'explorer';
    const ext = createToolGateExtension();
    const result = callSync(ext, makeEvent('Read', { file_path: 'src/foo.ts' }), makeCtx('explorer'));
    expect(result).toBeUndefined();
  });
});

// ── Acceptance Criteria 3 ──────────────────────────────────────────────────
describe('AC3: Developer phase — Write allowed with full allowlist', () => {
  it('returns undefined (allow) for Write when tool is in allowlist', () => {
    process.env.FOREMAN_ALLOWED_TOOLS = 'Read,Write,Edit,Bash,Grep,Glob,LS';
    process.env.FOREMAN_PHASE = 'developer';
    const ext = createToolGateExtension();
    const result = callSync(ext, makeEvent('Write', { file_path: 'src/foo.ts' }), makeCtx('developer'));
    expect(result).toBeUndefined();
  });
});

// ── Acceptance Criteria 4 ──────────────────────────────────────────────────
describe('AC4: Custom FOREMAN_BASH_BLOCKLIST blocks matching commands', () => {
  it('blocks Bash command that matches a custom blocklist pattern', () => {
    process.env.FOREMAN_BASH_BLOCKLIST = 'rm -rf /,git push --force';
    process.env.FOREMAN_PHASE = 'developer';
    // No FOREMAN_ALLOWED_TOOLS → all tools allowed at tool-name level
    const ext = createToolGateExtension();
    const result = callSync(
      ext,
      makeEvent('Bash', { command: 'git push --force origin main' }),
      makeCtx('developer'),
    );
    expect(result).toBeDefined();
    expect(result!.block).toBe(true);
    expect(result!.reason).toMatch(/git push --force/);
  });
});

// ── Acceptance Criteria 5 ──────────────────────────────────────────────────
describe('AC5: Default blocklist — safe commands are allowed', () => {
  it('allows Bash("npm test") — not on default blocklist', () => {
    process.env.FOREMAN_PHASE = 'developer';
    // No FOREMAN_ALLOWED_TOOLS, no custom blocklist
    const ext = createToolGateExtension();
    const result = callSync(ext, makeEvent('Bash', { command: 'npm test' }), makeCtx('developer'));
    expect(result).toBeUndefined();
  });

  it('exposes DEFAULT_BASH_BLOCKLIST with known dangerous patterns', () => {
    expect(DEFAULT_BASH_BLOCKLIST).toContain('rm -rf /');
    expect(DEFAULT_BASH_BLOCKLIST).toContain('git push --force');
    expect(DEFAULT_BASH_BLOCKLIST).toContain('git push -f');
  });
});

// ── Acceptance Criteria 6 ──────────────────────────────────────────────────
describe('AC6: .beads/ directory is always protected', () => {
  it('blocks Write to .beads/issues.jsonl regardless of allowlist', () => {
    process.env.FOREMAN_ALLOWED_TOOLS = 'Read,Write,Edit,Bash,Grep,Glob,LS';
    process.env.FOREMAN_PHASE = 'developer';
    const ext = createToolGateExtension();
    const result = callSync(ext, makeEvent('Write', { file_path: '.beads/issues.jsonl' }), makeCtx('developer'));
    expect(result).toBeDefined();
    expect(result!.block).toBe(true);
    expect(result!.reason).toMatch(/\.beads\//i);
  });

  it('blocks Edit to .beads/beads.jsonl', () => {
    process.env.FOREMAN_ALLOWED_TOOLS = 'Read,Write,Edit,Bash,Grep,Glob,LS';
    process.env.FOREMAN_PHASE = 'developer';
    const ext = createToolGateExtension();
    const result = callSync(ext, makeEvent('Edit', { file_path: '.beads/beads.jsonl' }), makeCtx('developer'));
    expect(result).toBeDefined();
    expect(result!.block).toBe(true);
  });

  it('blocks when FOREMAN_ALLOWED_TOOLS is not set (no allowlist enforcement)', () => {
    // Even without allowlist, .beads/ is protected
    process.env.FOREMAN_PHASE = 'developer';
    const ext = createToolGateExtension();
    const result = callSync(
      ext,
      makeEvent('Write', { file_path: '/some/path/.beads/issues.jsonl' }),
      makeCtx('developer'),
    );
    expect(result).toBeDefined();
    expect(result!.block).toBe(true);
  });
});

// ── Acceptance Criteria 7 ──────────────────────────────────────────────────
describe('AC7: auditCallback is invoked on every block decision', () => {
  it('calls callback with toolName, phase, blocked=true, reason when blocked by allowlist', () => {
    process.env.FOREMAN_ALLOWED_TOOLS = 'Read,Grep,Glob';
    process.env.FOREMAN_PHASE = 'explorer';
    const audit = vi.fn();
    const ext = createToolGateExtension(audit);
    callSync(ext, makeEvent('Bash', { command: 'ls' }), makeCtx('explorer'));
    expect(audit).toHaveBeenCalledOnce();
    const [decision] = audit.mock.calls[0] as [Record<string, unknown>];
    expect(decision.toolName).toBe('Bash');
    expect(decision.phase).toBe('explorer');
    expect(decision.blocked).toBe(true);
    expect(typeof decision.reason).toBe('string');
  });

  it('calls callback when blocked by bash blocklist', () => {
    process.env.FOREMAN_PHASE = 'developer';
    const audit = vi.fn();
    const ext = createToolGateExtension(audit);
    callSync(ext, makeEvent('Bash', { command: 'rm -rf /' }), makeCtx('developer'));
    expect(audit).toHaveBeenCalledOnce();
    const [decision] = audit.mock.calls[0] as [Record<string, unknown>];
    expect(decision.blocked).toBe(true);
    expect(decision.toolName).toBe('Bash');
  });

  it('calls callback when blocked by .beads/ path protection', () => {
    process.env.FOREMAN_PHASE = 'developer';
    const audit = vi.fn();
    const ext = createToolGateExtension(audit);
    callSync(ext, makeEvent('Write', { file_path: '.beads/issues.jsonl' }), makeCtx('developer'));
    expect(audit).toHaveBeenCalledOnce();
    const [decision] = audit.mock.calls[0] as [Record<string, unknown>];
    expect(decision.blocked).toBe(true);
  });

  it('does NOT call callback when tool is allowed', () => {
    process.env.FOREMAN_ALLOWED_TOOLS = 'Read,Grep,Glob';
    process.env.FOREMAN_PHASE = 'explorer';
    const audit = vi.fn();
    const ext = createToolGateExtension(audit);
    callSync(ext, makeEvent('Read', { file_path: 'src/foo.ts' }), makeCtx('explorer'));
    expect(audit).not.toHaveBeenCalled();
  });
});

// ── Acceptance Criteria 8 ──────────────────────────────────────────────────
describe('AC8: FOREMAN_ALLOWED_TOOLS not set → all tools allowed', () => {
  it('allows any tool name when FOREMAN_ALLOWED_TOOLS is empty/unset', () => {
    process.env.FOREMAN_PHASE = 'developer';
    // No FOREMAN_ALLOWED_TOOLS set
    const ext = createToolGateExtension();
    expect(callSync(ext, makeEvent('Write', { file_path: 'src/foo.ts' }), makeCtx())).toBeUndefined();
    expect(callSync(ext, makeEvent('Bash', { command: 'npm run build' }), makeCtx())).toBeUndefined();
    expect(callSync(ext, makeEvent('SomeUnknownTool', {}), makeCtx())).toBeUndefined();
  });

  it('also allows when FOREMAN_ALLOWED_TOOLS is set to empty string', () => {
    process.env.FOREMAN_ALLOWED_TOOLS = '';
    process.env.FOREMAN_PHASE = 'developer';
    const ext = createToolGateExtension();
    const result = callSync(ext, makeEvent('Write', { file_path: 'src/foo.ts' }), makeCtx());
    expect(result).toBeUndefined();
  });
});

// ── Default export smoke test ──────────────────────────────────────────────
describe('toolGate default export', () => {
  it('is a pre-constructed ForemanExtension with correct metadata', () => {
    expect(toolGate.name).toBe('foreman-tool-gate');
    expect(toolGate.version).toBe('1.0.0');
    expect(typeof toolGate.onToolCall).toBe('function');
  });
});

// ── Edge cases ─────────────────────────────────────────────────────────────
describe('Edge cases', () => {
  it('handles Bash event with no command property gracefully', () => {
    process.env.FOREMAN_PHASE = 'developer';
    const ext = createToolGateExtension();
    // No command field in input — should not throw
    expect(() => callSync(ext, makeEvent('Bash', {}), makeCtx())).not.toThrow();
  });

  it('handles Windows-style .beads\\ path separator', () => {
    process.env.FOREMAN_PHASE = 'developer';
    const ext = createToolGateExtension();
    const result = callSync(ext, makeEvent('Write', { file_path: '.beads\\issues.jsonl' }), makeCtx('developer'));
    expect(result).toBeDefined();
    expect(result!.block).toBe(true);
  });

  it('does not block paths that merely contain "beads" without the directory marker', () => {
    process.env.FOREMAN_PHASE = 'developer';
    const ext = createToolGateExtension();
    const result = callSync(ext, makeEvent('Write', { file_path: 'src/beads-helper.ts' }), makeCtx('developer'));
    // "beads-helper.ts" does not contain ".beads/" so should be allowed
    expect(result).toBeUndefined();
  });
});
