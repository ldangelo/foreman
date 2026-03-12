/**
 * AgentRuntime — pluggable interface for agent execution backends.
 *
 * Abstracts over the Claude Agent SDK `query()` function so that different
 * runtime backends (Claude Code, mock, future alternatives) can be swapped
 * without changing orchestration logic.
 */

import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import type { RuntimeSelection } from "./types.js";

// ── Query options ────────────────────────────────────────────────────────

/**
 * Parameters accepted by AgentRuntime.executeQuery().
 * Mirrors the Claude Agent SDK query() parameters for compatibility.
 */
export interface AgentQueryOptions {
  prompt: string;
  options?: {
    cwd?: string;
    model?: string;
    permissionMode?: string;
    allowDangerouslySkipPermissions?: boolean;
    env?: Record<string, string | undefined>;
    resume?: string;
    persistSession?: boolean;
    maxBudgetUsd?: number;
    disallowedTools?: string[];
    [key: string]: unknown;
  };
}

// ── AgentRuntime interface ───────────────────────────────────────────────

/**
 * Pluggable runtime interface for agent execution.
 *
 * Implementations must:
 * - Provide a stable `name` identifier matching a RuntimeSelection value
 * - Yield SDKMessage-compatible messages from executeQuery()
 * - Be stateless (create new generator per executeQuery() call)
 */
export interface AgentRuntime {
  /** Runtime identifier — matches the RuntimeSelection type */
  readonly name: RuntimeSelection;

  /**
   * Execute an agent query and stream messages.
   * Returns an async iterable of SDK messages.
   */
  executeQuery(params: AgentQueryOptions): AsyncIterable<SDKMessage>;
}

// ── Factory ──────────────────────────────────────────────────────────────

/**
 * Create an AgentRuntime instance by RuntimeSelection name.
 *
 * @throws Error if the requested runtime is not available
 */
export async function createRuntime(selection: RuntimeSelection): Promise<AgentRuntime> {
  switch (selection) {
    case "claude-code": {
      const { ClaudeSDKRuntime } = await import("./runtime-claude-sdk.js");
      return new ClaudeSDKRuntime();
    }
    case "mock": {
      const { MockRuntime } = await import("./runtime-mock.js");
      return new MockRuntime();
    }
    default: {
      const _exhaustive: never = selection;
      throw new Error(`Unknown runtime: ${_exhaustive}`);
    }
  }
}

/**
 * Get the list of all supported runtime names.
 */
export function getAvailableRuntimes(): RuntimeSelection[] {
  return ["claude-code", "mock"];
}
