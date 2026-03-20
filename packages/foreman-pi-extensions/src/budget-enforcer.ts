/**
 * foreman-budget Pi extension.
 *
 * Enforces turn and token budget limits during a Pi agent session. When a
 * limit is reached the hook returns a ToolCallResult-shaped object that Pi
 * interprets as a session termination signal.
 *
 * Configuration (environment variables):
 *   FOREMAN_MAX_TURNS  – maximum number of turns (default: 80)
 *   FOREMAN_MAX_TOKENS – maximum total token usage (default: 500_000)
 *   FOREMAN_PHASE      – current pipeline phase name (informational)
 */

import type {
  ForemanExtension,
  TurnEndEvent,
  ExtensionContext,
  ToolCallResult,
} from './types.js';

export const DEFAULT_MAX_TURNS = 80;
export const DEFAULT_MAX_TOKENS = 500_000;

export function createBudgetExtension(
  auditCallback?: (event: object) => void,
): ForemanExtension {
  let turnCount = 0;

  return {
    name: 'foreman-budget',
    version: '1.0.0',

    // NOTE: The ForemanExtension interface declares onTurnEnd as returning
    // void | Promise<void>. We intentionally return ToolCallResult here
    // because Pi interprets a truthy return value as a session termination
    // signal. TypeScript's `void` return type still permits returning a value
    // (void means "caller should not use the return value", not "must return
    // undefined"). The cast below satisfies strict mode without altering
    // runtime semantics.
    onTurnEnd(event: TurnEndEvent, ctx: ExtensionContext): void {
      turnCount++;

      const maxTurns = parseInt(
        process.env.FOREMAN_MAX_TURNS ?? String(DEFAULT_MAX_TURNS),
        10,
      );
      const maxTokens = parseInt(
        process.env.FOREMAN_MAX_TOKENS ?? String(DEFAULT_MAX_TOKENS),
        10,
      );

      const piUsage = ctx.getContextUsage();
      const totalTokens = piUsage.totalTokens;

      // Cross-check: use the higher of our internal counter vs Pi's reported turn number.
      const effectiveTurns = Math.max(turnCount, event.turnNumber);

      auditCallback?.({
        event: 'turn_end',
        turnCount: effectiveTurns,
        totalTokens,
        maxTurns,
        maxTokens,
        phase: process.env.FOREMAN_PHASE ?? 'unknown',
      });

      if (effectiveTurns >= maxTurns) {
        const reason = `Turn limit reached: ${maxTurns}`;
        ctx.log(`[foreman-budget] ${reason}`);
        auditCallback?.({
          event: 'budget_exceeded',
          reason,
          turnCount: effectiveTurns,
          maxTurns,
        });
        // Cast is required because the interface declares `void` return but
        // Pi runtime inspects the actual returned value.
        return { block: true, reason } as unknown as void;
      }

      if (totalTokens >= maxTokens) {
        const reason = `Token limit reached: ${totalTokens} >= ${maxTokens}`;
        ctx.log(`[foreman-budget] ${reason}`);
        auditCallback?.({
          event: 'budget_exceeded',
          reason,
          totalTokens,
          maxTokens,
        });
        return { block: true, reason } as unknown as void;
      }

      return undefined;
    },
  };
}

// Default export: pre-constructed instance suitable for direct use in foreman.
export const budget = createBudgetExtension();
