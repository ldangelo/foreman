/**
 * @foreman/pi-extensions
 *
 * Extension package for Pi agent pipeline hooks.
 * Exports all three built-in extensions plus the shared type surface.
 */

// Shared types
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

// Tool-gate extension
export { createToolGateExtension, toolGate, DEFAULT_BASH_BLOCKLIST } from './tool-gate.js';

// Budget enforcer extension
export { createBudgetExtension, budget, DEFAULT_MAX_TURNS, DEFAULT_MAX_TOKENS } from './budget-enforcer.js';

// Audit logger extension
export { createAuditExtension, audit } from './audit-logger.js';
export type { AuditEntry } from './audit-logger.js';

// Extension registry: canonical load order for the Foreman pipeline
import { toolGate } from './tool-gate.js';
import { budget } from './budget-enforcer.js';
import { audit } from './audit-logger.js';

export const ALL_EXTENSIONS = [toolGate, budget, audit] as const;

// Package version
export const PI_EXTENSIONS_VERSION = '1.0.0';
