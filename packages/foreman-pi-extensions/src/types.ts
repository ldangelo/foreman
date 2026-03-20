/**
 * Type definitions for the Foreman Pi extension API.
 *
 * These types define the hook contracts between the Foreman pipeline
 * and user-supplied extensions. No runtime code lives here.
 */

// Event fired when Pi invokes a tool. The hook can block the call.
export interface ToolCallEvent {
  toolName: string;
  input: {
    command?: string;      // For Bash tool
    file_path?: string;    // For Read/Write/Edit
    pattern?: string;      // For Glob/Grep
    [key: string]: unknown; // All other tool inputs
  };
  phase?: string;          // Set from FOREMAN_PHASE env var by the extension framework
}

// Returned by tool_call hook: block=true prevents the tool from running
export type ToolCallResult = { block: true; reason: string } | undefined;

// Context usage snapshot, provided by Pi via ctx.getContextUsage()
export interface ContextUsage {
  totalTokens: number;
  inputTokens: number;
  outputTokens: number;
}

// Event fired at the end of each turn
export interface TurnEndEvent {
  turnNumber: number;
  contextUsage: ContextUsage;
}

// Event fired when the Pi agent session ends
export interface AgentEndEvent {
  reason: 'completed' | 'error' | 'budget_exceeded' | 'cancelled';
  error?: string;
  finalContextUsage?: ContextUsage;
}

// Event fired when a tool execution starts
export interface ToolExecutionStartEvent {
  toolName: string;
  toolCallId: string;
}

// Event fired when a tool execution completes
export interface ToolExecutionEndEvent {
  toolName: string;
  toolCallId: string;
  durationMs: number;
  success: boolean;
}

// Extension context passed to every hook
export interface ExtensionContext {
  phase: string;                           // Current pipeline phase
  runId: string;                           // Foreman run ID
  seedId: string;                          // Foreman seed ID
  getContextUsage(): ContextUsage;         // Get current token usage
  log(message: string): void;             // Log to audit trail
}

// Extension hook registry type
export interface ForemanExtension {
  name: string;
  version: string;

  // Called when a tool is about to be invoked. Return ToolCallResult to block.
  onToolCall?(event: ToolCallEvent, ctx: ExtensionContext): ToolCallResult | Promise<ToolCallResult>;

  // Called at the end of each turn
  onTurnEnd?(event: TurnEndEvent, ctx: ExtensionContext): void | Promise<void>;

  // Called when the agent session ends
  onAgentEnd?(event: AgentEndEvent, ctx: ExtensionContext): void | Promise<void>;

  // Called when a tool execution starts
  onToolExecutionStart?(event: ToolExecutionStartEvent, ctx: ExtensionContext): void | Promise<void>;

  // Called when a tool execution completes
  onToolExecutionEnd?(event: ToolExecutionEndEvent, ctx: ExtensionContext): void | Promise<void>;
}

// Factory function type for creating extensions
export type ExtensionFactory = (config?: Record<string, unknown>) => ForemanExtension;
