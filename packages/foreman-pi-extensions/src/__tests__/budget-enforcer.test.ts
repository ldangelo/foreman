/**
 * Tests for the foreman-budget Pi extension.
 *
 * TDD: these tests were written before the implementation.
 * Each test uses a fresh extension instance to avoid shared turnCount state.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { createBudgetExtension, DEFAULT_MAX_TURNS, DEFAULT_MAX_TOKENS } from '../budget-enforcer.js';
import type { ForemanExtension, TurnEndEvent, ExtensionContext, ToolCallResult } from '../types.js';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeMockCtx(totalTokens = 0): ExtensionContext {
  return {
    phase: 'explorer',
    runId: 'test-run',
    seedId: 'test-seed',
    getContextUsage: () => ({ totalTokens, inputTokens: 0, outputTokens: 0 }),
    log: vi.fn(),
  };
}

function makeTurnEndEvent(turnNumber: number, totalTokens = 0): TurnEndEvent {
  return {
    turnNumber,
    contextUsage: { totalTokens, inputTokens: 0, outputTokens: 0 },
  };
}

// onTurnEnd is declared as returning void in ForemanExtension but the
// implementation returns ToolCallResult when a budget is exceeded so Pi can
// terminate the session. We cast through unknown to make TypeScript happy.
function callTurnEnd(
  ext: ForemanExtension,
  event: TurnEndEvent,
  ctx: ExtensionContext,
): ToolCallResult {
  return ext.onTurnEnd!(event, ctx) as ToolCallResult;
}

// ---------------------------------------------------------------------------
// Env var management
// ---------------------------------------------------------------------------

const ENV_KEYS = ['FOREMAN_MAX_TURNS', 'FOREMAN_MAX_TOKENS', 'FOREMAN_PHASE'];
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

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

describe('foreman-budget extension', () => {
  describe('turn limit enforcement', () => {
    it('blocks when turn equals FOREMAN_MAX_TURNS', () => {
      process.env.FOREMAN_MAX_TURNS = '30';
      const ext = createBudgetExtension();
      const ctx = makeMockCtx(0);
      // Simulate 29 prior turns
      for (let i = 1; i < 30; i++) {
        callTurnEnd(ext, makeTurnEndEvent(i), ctx);
      }
      const result = callTurnEnd(ext, makeTurnEndEvent(30), ctx);
      expect(result).toEqual({ block: true, reason: 'Turn limit reached: 30' });
    });

    it('allows when turn is below FOREMAN_MAX_TURNS', () => {
      process.env.FOREMAN_MAX_TURNS = '30';
      const ext = createBudgetExtension();
      const ctx = makeMockCtx(0);
      // Simulate 28 prior turns
      for (let i = 1; i < 29; i++) {
        callTurnEnd(ext, makeTurnEndEvent(i), ctx);
      }
      const result = callTurnEnd(ext, makeTurnEndEvent(29), ctx);
      expect(result).toBeUndefined();
    });

    it('blocks on turn 80 with default max turns (no env var)', () => {
      const ext = createBudgetExtension();
      const ctx = makeMockCtx(0);
      for (let i = 1; i < DEFAULT_MAX_TURNS; i++) {
        callTurnEnd(ext, makeTurnEndEvent(i), ctx);
      }
      const result = callTurnEnd(ext, makeTurnEndEvent(DEFAULT_MAX_TURNS), ctx);
      expect(result).toEqual({ block: true, reason: `Turn limit reached: ${DEFAULT_MAX_TURNS}` });
    });

    it('allows on turn 79 with default max turns (no env var)', () => {
      const ext = createBudgetExtension();
      const ctx = makeMockCtx(0);
      for (let i = 1; i < DEFAULT_MAX_TURNS - 1; i++) {
        callTurnEnd(ext, makeTurnEndEvent(i), ctx);
      }
      const result = callTurnEnd(ext, makeTurnEndEvent(DEFAULT_MAX_TURNS - 1), ctx);
      expect(result).toBeUndefined();
    });
  });

  describe('token limit enforcement', () => {
    it('blocks when totalTokens exceeds FOREMAN_MAX_TOKENS', () => {
      process.env.FOREMAN_MAX_TOKENS = '100000';
      const ext = createBudgetExtension();
      const ctx = makeMockCtx(100001);
      const result = callTurnEnd(ext, makeTurnEndEvent(1), ctx);
      expect(result).toBeDefined();
      expect(result!.block).toBe(true);
      expect(result!.reason).toContain('Token limit reached');
    });

    it('allows when totalTokens is below FOREMAN_MAX_TOKENS', () => {
      process.env.FOREMAN_MAX_TOKENS = '100000';
      const ext = createBudgetExtension();
      const ctx = makeMockCtx(99999);
      const result = callTurnEnd(ext, makeTurnEndEvent(1), ctx);
      expect(result).toBeUndefined();
    });

    it('blocks on 500001 tokens with default max tokens (no env var)', () => {
      const ext = createBudgetExtension();
      const ctx = makeMockCtx(DEFAULT_MAX_TOKENS + 1);
      const result = callTurnEnd(ext, makeTurnEndEvent(1), ctx);
      expect(result).toBeDefined();
      expect(result!.block).toBe(true);
    });

    it('allows on 499999 tokens with default max tokens (no env var)', () => {
      const ext = createBudgetExtension();
      const ctx = makeMockCtx(DEFAULT_MAX_TOKENS - 1);
      const result = callTurnEnd(ext, makeTurnEndEvent(1), ctx);
      expect(result).toBeUndefined();
    });

    it('blocks when totalTokens equals FOREMAN_MAX_TOKENS exactly', () => {
      process.env.FOREMAN_MAX_TOKENS = '100000';
      const ext = createBudgetExtension();
      const ctx = makeMockCtx(100000);
      const result = callTurnEnd(ext, makeTurnEndEvent(1), ctx);
      expect(result).toBeDefined();
      expect(result!.block).toBe(true);
    });
  });

  describe('audit callback', () => {
    it('calls auditCallback on every turn_end with correct stats', () => {
      process.env.FOREMAN_MAX_TURNS = '10';
      process.env.FOREMAN_MAX_TOKENS = '50000';
      process.env.FOREMAN_PHASE = 'developer';
      const auditFn = vi.fn();
      const ext = createBudgetExtension(auditFn);
      const ctx = makeMockCtx(1000);
      callTurnEnd(ext, makeTurnEndEvent(1), ctx);
      expect(auditFn).toHaveBeenCalledOnce();
      expect(auditFn).toHaveBeenCalledWith(
        expect.objectContaining({
          event: 'turn_end',
          turnCount: 1,
          totalTokens: 1000,
          maxTurns: 10,
          maxTokens: 50000,
          phase: 'developer',
        }),
      );
    });

    it('calls auditCallback with budget_exceeded when turn limit is hit', () => {
      process.env.FOREMAN_MAX_TURNS = '5';
      const auditFn = vi.fn();
      const ext = createBudgetExtension(auditFn);
      const ctx = makeMockCtx(0);
      for (let i = 1; i <= 5; i++) {
        callTurnEnd(ext, makeTurnEndEvent(i), ctx);
      }
      const budgetExceededCalls = auditFn.mock.calls.filter(
        (call: unknown[]) => (call[0] as Record<string, unknown>)['event'] === 'budget_exceeded',
      );
      expect(budgetExceededCalls).toHaveLength(1);
      expect(budgetExceededCalls[0]![0]).toMatchObject({
        event: 'budget_exceeded',
        reason: 'Turn limit reached: 5',
        turnCount: 5,
        maxTurns: 5,
      });
    });

    it('calls auditCallback with budget_exceeded when token limit is hit', () => {
      process.env.FOREMAN_MAX_TOKENS = '1000';
      const auditFn = vi.fn();
      const ext = createBudgetExtension(auditFn);
      const ctx = makeMockCtx(1001);
      callTurnEnd(ext, makeTurnEndEvent(1), ctx);
      const budgetExceededCalls = auditFn.mock.calls.filter(
        (call: unknown[]) => (call[0] as Record<string, unknown>)['event'] === 'budget_exceeded',
      );
      expect(budgetExceededCalls).toHaveLength(1);
      expect(budgetExceededCalls[0]![0]).toMatchObject({
        event: 'budget_exceeded',
        totalTokens: 1001,
        maxTokens: 1000,
      });
    });

    it('does not call auditCallback when not provided', () => {
      const ext = createBudgetExtension();
      const ctx = makeMockCtx(0);
      // Should not throw
      expect(() => callTurnEnd(ext, makeTurnEndEvent(1), ctx)).not.toThrow();
    });
  });

  describe('cross-check: event.turnNumber vs internal counter', () => {
    it('uses event.turnNumber when it is higher than the internal counter', () => {
      process.env.FOREMAN_MAX_TURNS = '50';
      const auditFn = vi.fn();
      const ext = createBudgetExtension(auditFn);
      const ctx = makeMockCtx(0);
      // First call: internal counter is 1, but Pi reports turn 5
      callTurnEnd(ext, makeTurnEndEvent(5), ctx);
      expect(auditFn).toHaveBeenCalledWith(
        expect.objectContaining({
          event: 'turn_end',
          turnCount: 5,
        }),
      );
    });

    it('blocks immediately when event.turnNumber equals maxTurns (even on first internal call)', () => {
      process.env.FOREMAN_MAX_TURNS = '5';
      const ext = createBudgetExtension();
      const ctx = makeMockCtx(0);
      // Internal counter would be 1, but Pi says turn 5
      const result = callTurnEnd(ext, makeTurnEndEvent(5), ctx);
      expect(result).toEqual({ block: true, reason: 'Turn limit reached: 5' });
    });

    it('uses internal counter when it is higher than event.turnNumber', () => {
      process.env.FOREMAN_MAX_TURNS = '50';
      const auditFn = vi.fn();
      const ext = createBudgetExtension(auditFn);
      const ctx = makeMockCtx(0);
      // Simulate 5 internal turns, all with Pi reporting turn 1
      for (let i = 0; i < 5; i++) {
        callTurnEnd(ext, makeTurnEndEvent(1), ctx);
      }
      const lastCall = auditFn.mock.calls[auditFn.mock.calls.length - 1]![0] as Record<string, unknown>;
      expect(lastCall['turnCount']).toBe(5);
    });
  });

  describe('extension metadata', () => {
    it('has the correct name', () => {
      const ext = createBudgetExtension();
      expect(ext.name).toBe('foreman-budget');
    });

    it('has version 1.0.0', () => {
      const ext = createBudgetExtension();
      expect(ext.version).toBe('1.0.0');
    });
  });

  describe('default export', () => {
    it('exports a pre-built budget instance', async () => {
      const mod = await import('../budget-enforcer.js');
      expect(mod.budget).toBeDefined();
      expect(mod.budget.name).toBe('foreman-budget');
    });
  });

  describe('ctx.log is called on budget_exceeded', () => {
    it('logs a message when turn limit is hit', () => {
      process.env.FOREMAN_MAX_TURNS = '3';
      const ext = createBudgetExtension();
      const ctx = makeMockCtx(0);
      for (let i = 1; i <= 3; i++) {
        callTurnEnd(ext, makeTurnEndEvent(i), ctx);
      }
      expect(ctx.log).toHaveBeenCalledWith(expect.stringContaining('Turn limit reached: 3'));
    });

    it('logs a message when token limit is hit', () => {
      process.env.FOREMAN_MAX_TOKENS = '500';
      const ext = createBudgetExtension();
      const ctx = makeMockCtx(501);
      callTurnEnd(ext, makeTurnEndEvent(1), ctx);
      expect(ctx.log).toHaveBeenCalledWith(expect.stringContaining('Token limit reached'));
    });
  });
});
