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

    onTurnEnd(event: TurnEndEvent, ctx: ExtensionContext): ToolCallResult | void {
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
        return { block: true, reason };
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
        return { block: true, reason };
      }

      return undefined;
    },
  };
}

// Default export: pre-constructed instance suitable for direct use in foreman.
export const budget = createBudgetExtension();
