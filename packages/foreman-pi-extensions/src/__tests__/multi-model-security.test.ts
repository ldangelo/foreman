/**
 * Multi-Model Security Enforcement Tests — TRD-018 / bd-23tv
 *
 * Verifies that the `toolGate`, `budget`, and `audit` extensions are
 * model-agnostic: enforcement decisions are driven entirely by env vars,
 * never by which model Pi is currently using.
 *
 * Also verifies that audit entries include a `model` field sourced from
 * the `FOREMAN_MODEL` env var.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

import { createToolGateExtension } from '../tool-gate.js';
import { createBudgetExtension } from '../budget-enforcer.js';
import { createAuditExtension } from '../audit-logger.js';
import type { ToolCallEvent, ExtensionContext, ToolCallResult, TurnEndEvent } from '../types.js';

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeTmpDir(): string {
  const dir = join(tmpdir(), `foreman-multi-model-test-${randomUUID()}`);
  mkdirSync(dir, { recursive: true });
  return dir;
}

/** Minimal stub for ExtensionContext — all extension logic reads from env vars, not ctx. */
function makeCtx(totalTokens = 0): ExtensionContext {
  return {
    phase: process.env['FOREMAN_PHASE'] ?? 'unknown',
    runId: process.env['FOREMAN_RUN_ID'] ?? 'test-run',
    seedId: process.env['FOREMAN_SEED_ID'] ?? 'test-seed',
    getContextUsage: () => ({ totalTokens, inputTokens: 0, outputTokens: 0 }),
    log: (_msg: string) => undefined,
  };
}

function makeToolEvent(toolName: string, input: ToolCallEvent['input'] = {}): ToolCallEvent {
  return { toolName, input };
}

function makeTurnEndEvent(turnNumber: number, totalTokens = 0): TurnEndEvent {
  return {
    turnNumber,
    contextUsage: { totalTokens, inputTokens: 0, outputTokens: 0 },
  };
}

/** Call onToolCall synchronously — gate is always synchronous. */
function callToolGateSync(
  ext: ReturnType<typeof createToolGateExtension>,
  event: ToolCallEvent,
  ctx: ExtensionContext,
): ToolCallResult {
  return ext.onToolCall!(event, ctx) as ToolCallResult;
}

/** Call onTurnEnd, cast return to ToolCallResult so tests can inspect block signal. */
function callTurnEndSync(
  ext: ReturnType<typeof createBudgetExtension>,
  event: TurnEndEvent,
  ctx: ExtensionContext,
): ToolCallResult {
  return ext.onTurnEnd!(event, ctx) as unknown as ToolCallResult;
}

// ── Env var management ────────────────────────────────────────────────────────

const ENV_KEYS = [
  'FOREMAN_ALLOWED_TOOLS',
  'FOREMAN_PHASE',
  'FOREMAN_MAX_TURNS',
  'FOREMAN_MAX_TOKENS',
  'FOREMAN_MODEL',
  'FOREMAN_RUN_ID',
  'FOREMAN_SEED_ID',
];

let savedEnv: Partial<Record<string, string>> = {};

beforeEach(() => {
  savedEnv = {};
  for (const key of ENV_KEYS) {
    savedEnv[key] = process.env[key];
    delete process.env[key];
  }
  // Shared defaults for all tests
  process.env['FOREMAN_PHASE'] = 'developer';
  process.env['FOREMAN_RUN_ID'] = 'run-multi-model';
  process.env['FOREMAN_SEED_ID'] = 'seed-multi-model';
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

// ── Test 1: toolGate blocks disallowed tool with Haiku model ─────────────────

describe('toolGate model-agnostic blocking — Haiku model', () => {
  it('blocks a disallowed tool when FOREMAN_MODEL is claude-haiku-4-5-20251001', () => {
    process.env['FOREMAN_ALLOWED_TOOLS'] = 'Read,Grep,Glob';
    process.env['FOREMAN_PHASE'] = 'explorer';
    process.env['FOREMAN_MODEL'] = 'claude-haiku-4-5-20251001';

    const ext = createToolGateExtension();
    const result = callToolGateSync(
      ext,
      makeToolEvent('Bash', { command: 'npm test' }),
      makeCtx(),
    );

    expect(result).toBeDefined();
    expect(result!.block).toBe(true);
    expect(result!.reason).toMatch(/not allowed in explorer phase/i);
  });
});

// ── Test 2: toolGate blocks disallowed tool with Sonnet model ────────────────

describe('toolGate model-agnostic blocking — Sonnet model', () => {
  it('blocks a disallowed tool when FOREMAN_MODEL is claude-sonnet-4-6', () => {
    process.env['FOREMAN_ALLOWED_TOOLS'] = 'Read,Grep,Glob';
    process.env['FOREMAN_PHASE'] = 'explorer';
    process.env['FOREMAN_MODEL'] = 'claude-sonnet-4-6';

    const ext = createToolGateExtension();
    const result = callToolGateSync(
      ext,
      makeToolEvent('Bash', { command: 'npm test' }),
      makeCtx(),
    );

    expect(result).toBeDefined();
    expect(result!.block).toBe(true);
    expect(result!.reason).toMatch(/not allowed in explorer phase/i);
  });

  it('produces identical blocking behaviour for Haiku and Sonnet models', () => {
    process.env['FOREMAN_ALLOWED_TOOLS'] = 'Read,Grep,Glob';
    process.env['FOREMAN_PHASE'] = 'explorer';

    // Haiku
    process.env['FOREMAN_MODEL'] = 'claude-haiku-4-5-20251001';
    const extHaiku = createToolGateExtension();
    const resultHaiku = callToolGateSync(
      extHaiku,
      makeToolEvent('Write', { file_path: 'src/foo.ts' }),
      makeCtx(),
    );

    // Sonnet
    process.env['FOREMAN_MODEL'] = 'claude-sonnet-4-6';
    const extSonnet = createToolGateExtension();
    const resultSonnet = callToolGateSync(
      extSonnet,
      makeToolEvent('Write', { file_path: 'src/foo.ts' }),
      makeCtx(),
    );

    // Both must block
    expect(resultHaiku).toBeDefined();
    expect(resultSonnet).toBeDefined();
    expect(resultHaiku!.block).toBe(true);
    expect(resultSonnet!.block).toBe(true);

    // Reasons must be identical (model does not influence the message)
    expect(resultHaiku!.reason).toBe(resultSonnet!.reason);
  });
});

// ── Test 3: budget enforcer fires at turn limit regardless of model ───────────

describe('budget enforcer model-agnostic turn limit', () => {
  it('fires at the turn limit when FOREMAN_MODEL=claude-haiku-4-5-20251001', () => {
    process.env['FOREMAN_MAX_TURNS'] = '3';
    process.env['FOREMAN_MODEL'] = 'claude-haiku-4-5-20251001';
    const ext = createBudgetExtension();
    const ctx = makeCtx(0);

    callTurnEndSync(ext, makeTurnEndEvent(1), ctx);
    callTurnEndSync(ext, makeTurnEndEvent(2), ctx);
    const result = callTurnEndSync(ext, makeTurnEndEvent(3), ctx);

    expect(result).toBeDefined();
    expect(result!.block).toBe(true);
    expect(result!.reason).toContain('Turn limit reached: 3');
  });

  it('fires at the turn limit when FOREMAN_MODEL=claude-sonnet-4-6', () => {
    process.env['FOREMAN_MAX_TURNS'] = '3';
    process.env['FOREMAN_MODEL'] = 'claude-sonnet-4-6';
    const ext = createBudgetExtension();
    const ctx = makeCtx(0);

    callTurnEndSync(ext, makeTurnEndEvent(1), ctx);
    callTurnEndSync(ext, makeTurnEndEvent(2), ctx);
    const result = callTurnEndSync(ext, makeTurnEndEvent(3), ctx);

    expect(result).toBeDefined();
    expect(result!.block).toBe(true);
    expect(result!.reason).toContain('Turn limit reached: 3');
  });

  it('produces identical turn-limit result regardless of FOREMAN_MODEL value', () => {
    process.env['FOREMAN_MAX_TURNS'] = '2';

    // Run budget extension with Haiku
    process.env['FOREMAN_MODEL'] = 'claude-haiku-4-5-20251001';
    const extHaiku = createBudgetExtension();
    callTurnEndSync(extHaiku, makeTurnEndEvent(1), makeCtx(0));
    const resultHaiku = callTurnEndSync(extHaiku, makeTurnEndEvent(2), makeCtx(0));

    // Run budget extension with Sonnet
    process.env['FOREMAN_MODEL'] = 'claude-sonnet-4-6';
    const extSonnet = createBudgetExtension();
    callTurnEndSync(extSonnet, makeTurnEndEvent(1), makeCtx(0));
    const resultSonnet = callTurnEndSync(extSonnet, makeTurnEndEvent(2), makeCtx(0));

    // Both must block with identical reason
    expect(resultHaiku).toBeDefined();
    expect(resultSonnet).toBeDefined();
    expect(resultHaiku!.block).toBe(true);
    expect(resultSonnet!.block).toBe(true);
    expect(resultHaiku!.reason).toBe(resultSonnet!.reason);
  });
});

// ── Test 4: Audit entry includes `model` field from FOREMAN_MODEL ─────────────

describe('audit entry includes model field', () => {
  it('includes model field in tool_call audit entry when FOREMAN_MODEL is set', () => {
    const dir = makeTmpDir();
    process.env['FOREMAN_MODEL'] = 'claude-sonnet-4-6';

    const ext = createAuditExtension(dir);
    ext.onToolCall?.({ toolName: 'Read', input: { file_path: 'src/foo.ts' } }, makeCtx());

    // Read the JSONL file to check the written entry
    const runId = process.env['FOREMAN_RUN_ID'] ?? 'unknown';
    const filePath = join(dir, `${runId}.jsonl`);
    const text = readFileSync(filePath, 'utf-8');
    const entry = JSON.parse(text.trim()) as Record<string, unknown>;

    expect(entry['model']).toBe('claude-sonnet-4-6');
    expect(entry['eventType']).toBe('tool_call');
  });

  it('defaults model to "unknown" when FOREMAN_MODEL is not set', () => {
    const dir = makeTmpDir();
    // FOREMAN_MODEL is intentionally not set (cleared by beforeEach)

    const ext = createAuditExtension(dir);
    ext.onTurnEnd?.(
      { turnNumber: 1, contextUsage: { totalTokens: 100, inputTokens: 80, outputTokens: 20 } },
      makeCtx(),
    );

    const runId = process.env['FOREMAN_RUN_ID'] ?? 'unknown';
    const filePath = join(dir, `${runId}.jsonl`);
    const text = readFileSync(filePath, 'utf-8');
    const entry = JSON.parse(text.trim()) as Record<string, unknown>;

    expect(entry['model']).toBe('unknown');
  });

  it('includes model in all event types (agent_end)', () => {
    const dir = makeTmpDir();
    process.env['FOREMAN_MODEL'] = 'claude-haiku-4-5-20251001';

    const ext = createAuditExtension(dir);
    ext.onAgentEnd?.(
      { reason: 'completed', finalContextUsage: { totalTokens: 5000, inputTokens: 4000, outputTokens: 1000 } },
      makeCtx(),
    );

    const runId = process.env['FOREMAN_RUN_ID'] ?? 'unknown';
    const filePath = join(dir, `${runId}.jsonl`);
    const text = readFileSync(filePath, 'utf-8');
    const entry = JSON.parse(text.trim()) as Record<string, unknown>;

    expect(entry['model']).toBe('claude-haiku-4-5-20251001');
    expect(entry['eventType']).toBe('agent_end');
  });
});

// ── Test 5: Model recorded correctly when FOREMAN_MODEL=claude-haiku-4-5-20251001

describe('model field recorded correctly for Haiku', () => {
  it('records claude-haiku-4-5-20251001 in audit entry when FOREMAN_MODEL is set to that value', () => {
    const dir = makeTmpDir();
    process.env['FOREMAN_MODEL'] = 'claude-haiku-4-5-20251001';

    const ext = createAuditExtension(dir);
    ext.onToolExecutionStart?.(
      { toolName: 'Bash', toolCallId: 'call-haiku-001' },
      makeCtx(),
    );

    const runId = process.env['FOREMAN_RUN_ID'] ?? 'unknown';
    const filePath = join(dir, `${runId}.jsonl`);
    const text = readFileSync(filePath, 'utf-8');
    const entry = JSON.parse(text.trim()) as Record<string, unknown>;

    expect(entry['model']).toBe('claude-haiku-4-5-20251001');
    expect(entry['eventType']).toBe('tool_execution_start');
    expect(entry['toolName']).toBe('Bash');
  });

  it('model field appears in all five event types', () => {
    const dir = makeTmpDir();
    process.env['FOREMAN_MODEL'] = 'claude-haiku-4-5-20251001';
    const expectedModel = 'claude-haiku-4-5-20251001';
    const ext = createAuditExtension(dir);

    ext.onToolCall?.({ toolName: 'Read', input: {} }, makeCtx());
    ext.onTurnEnd?.(
      { turnNumber: 1, contextUsage: { totalTokens: 200, inputTokens: 160, outputTokens: 40 } },
      makeCtx(),
    );
    ext.onAgentEnd?.({ reason: 'cancelled' }, makeCtx());
    ext.onToolExecutionStart?.({ toolName: 'Glob', toolCallId: 'c1' }, makeCtx());
    ext.onToolExecutionEnd?.({ toolName: 'Glob', toolCallId: 'c1', durationMs: 10, success: true }, makeCtx());

    const runId = process.env['FOREMAN_RUN_ID'] ?? 'unknown';
    const filePath = join(dir, `${runId}.jsonl`);
    const text = readFileSync(filePath, 'utf-8');
    const lines = text.split('\n').filter(l => l.trim().length > 0);
    expect(lines).toHaveLength(5);

    for (const line of lines) {
      const entry = JSON.parse(line) as Record<string, unknown>;
      expect(entry['model']).toBe(expectedModel);
    }
  });
});
