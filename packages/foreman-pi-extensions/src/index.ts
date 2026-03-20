/**
 * @foreman/pi-extensions
 *
 * Extension package for Pi agent mail and RPC migration handlers.
 */

export const PI_EXTENSIONS_VERSION = "0.1.0";

export type {
  ToolCallEvent,
  ToolCallResult,
  ContextUsage,
  TurnEndEvent,
  AgentEndEvent,
  ToolExecutionStartEvent,
  ToolExecutionEndEvent,
  ExtensionContext,
  ForemanExtension,
  ExtensionFactory,
} from './types.js';
