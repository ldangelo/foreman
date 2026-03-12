/**
 * MockRuntime — AgentRuntime implementation for testing.
 *
 * Yields a preset list of SDKMessage values without making any real API calls.
 * Use MockRuntime.setMessages() to configure what messages will be yielded.
 */

import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import type { AgentRuntime, AgentQueryOptions } from "./runtime.js";
import type { RuntimeSelection } from "./types.js";

export class MockRuntime implements AgentRuntime {
  readonly name: RuntimeSelection = "mock";

  private _messages: SDKMessage[] = [];
  private _capturedParams: AgentQueryOptions[] = [];

  /**
   * Configure the messages this runtime will yield for the next executeQuery() call.
   */
  setMessages(messages: SDKMessage[]): void {
    this._messages = messages;
  }

  /**
   * Returns the parameters that were passed to executeQuery() calls.
   * Useful for asserting what prompts/options were used.
   */
  getCapturedParams(): AgentQueryOptions[] {
    return this._capturedParams;
  }

  /**
   * Reset captured params and preset messages.
   */
  reset(): void {
    this._messages = [];
    this._capturedParams = [];
  }

  async *executeQuery(params: AgentQueryOptions): AsyncGenerator<SDKMessage> {
    this._capturedParams.push(params);
    for (const msg of this._messages) {
      yield msg;
    }
  }
}
