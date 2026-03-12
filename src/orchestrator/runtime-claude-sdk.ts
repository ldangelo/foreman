/**
 * ClaudeSDKRuntime — AgentRuntime implementation backed by @anthropic-ai/claude-agent-sdk.
 *
 * Wraps the SDK's `query()` function to conform to the AgentRuntime interface.
 * This is the default runtime used in production.
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import type { AgentRuntime, AgentQueryOptions } from "./runtime.js";
import type { RuntimeSelection } from "./types.js";

export class ClaudeSDKRuntime implements AgentRuntime {
  readonly name: RuntimeSelection = "claude-code";

  async *executeQuery(params: AgentQueryOptions): AsyncGenerator<SDKMessage> {
    // Cast to SDK's expected parameter type — the shapes are compatible
    yield* query(params as Parameters<typeof query>[0]);
  }
}
