/**
 * Type definitions for the Foreman Pi extension API.
 *
 * These types define the hook contracts between the Foreman pipeline
 * and user-supplied extensions. No runtime code lives here.
 */

export interface ToolCallEvent {
  toolName: string;
  input: {
    command?: string;
    file_path?: string;
    pattern?: string;
    [key: string]: unknown;
  };
  phase?: string;
}

export type ToolCallResult =
  | {
      block: true;
      reason: string;
    }
  | undefined;

export interface ContextUsage {
  totalTokens: number;
  inputTokens: number;
  outputTokens: number;
}

export interface TurnEndEvent {
  turnNumber: number;
  contextUsage: ContextUsage;
}

export interface AgentEndEvent {
  reason: 'completed' | 'error' | 'budget_exceeded' | 'cancelled';
  error?: string;
  finalContextUsage?: ContextUsage;
}

export interface ToolExecutionStartEvent {
  toolName: string;
  toolCallId: string;
}

export interface ToolExecutionEndEvent {
  toolName: string;
  toolCallId: string;
  durationMs: number;
  success: boolean;
}

export interface ExtensionContext {
  phase: string;
  runId: string;
  seedId: string;
  getContextUsage(): ContextUsage;
  log(message: string): void;
}

export interface ForemanExtension {
  name: string;
  version: string;
  onToolCall?(event: ToolCallEvent, ctx: ExtensionContext): ToolCallResult | Promise<ToolCallResult>;
  onTurnEnd?(event: TurnEndEvent, ctx: ExtensionContext): ToolCallResult | void | Promise<ToolCallResult | void>;
  onAgentEnd?(event: AgentEndEvent, ctx: ExtensionContext): void | Promise<void>;
  onToolExecutionStart?(event: ToolExecutionStartEvent, ctx: ExtensionContext): void | Promise<void>;
  onToolExecutionEnd?(event: ToolExecutionEndEvent, ctx: ExtensionContext): void | Promise<void>;
}

export type ExtensionFactory = (config?: Record<string, unknown>) => ForemanExtension;
