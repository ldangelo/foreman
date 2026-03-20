/**
 * ExtensionHarness — reusable test utility for foreman-pi-extensions.
 *
 * Simulates Pi extension events without requiring the Pi binary, allowing
 * integration tests to exercise toolGate, budget, and audit extensions in
 * a controlled, isolated environment.
 */

import type {
  ForemanExtension,
  ExtensionContext,
  ToolCallEvent,
  ToolCallResult,
  TurnEndEvent,
  ContextUsage,
} from '../types.js';

// ── Public types ──────────────────────────────────────────────────────────────

export interface HarnessOptions {
  /** Current pipeline phase (sets FOREMAN_PHASE env var) */
  phase?: string;
  /** Comma-joined allowlist (sets FOREMAN_ALLOWED_TOOLS env var) */
  allowedTools?: string[];
  /** Turn budget (sets FOREMAN_MAX_TURNS env var) */
  maxTurns?: number;
  /** Token budget (sets FOREMAN_MAX_TOKENS env var) */
  maxTokens?: number;
  /** Run identifier (sets FOREMAN_RUN_ID env var) */
  runId?: string;
  /** Seed identifier (sets FOREMAN_SEED_ID env var) */
  seedId?: string;
}

export interface HarnessResult {
  /** What the first blocking extension returned, or undefined if none blocked */
  result: ToolCallResult;
  /** Wall-clock duration in milliseconds */
  durationMs: number;
}

// ── Env var management ────────────────────────────────────────────────────────

const HARNESS_ENV_MAP: ReadonlyArray<[keyof HarnessOptions, string]> = [
  ['phase', 'FOREMAN_PHASE'],
  ['allowedTools', 'FOREMAN_ALLOWED_TOOLS'],
  ['maxTurns', 'FOREMAN_MAX_TURNS'],
  ['maxTokens', 'FOREMAN_MAX_TOKENS'],
  ['runId', 'FOREMAN_RUN_ID'],
  ['seedId', 'FOREMAN_SEED_ID'],
];

// ── ExtensionHarness ──────────────────────────────────────────────────────────

export class ExtensionHarness {
  private readonly extensions: ForemanExtension[];
  private readonly options: HarnessOptions;
  /** Env vars saved before setEnv() calls; restored by cleanup() */
  private readonly savedEnv: Map<string, string | undefined> = new Map();

  constructor(extensions: ForemanExtension[], options: HarnessOptions = {}) {
    this.extensions = extensions;
    this.options = options;
    // Apply options as env vars immediately so the harness is ready on first use.
    this._applyOptions();
  }

  // ── Context factory ─────────────────────────────────────────────────────────

  /**
   * Returns a minimal mock ExtensionContext. Callers may override individual
   * fields by passing a partial object.
   */
  createContext(overrides?: Partial<ExtensionContext> & { contextUsage?: ContextUsage }): ExtensionContext {
    const usage: ContextUsage = overrides?.contextUsage ?? {
      turnCount: 0,
      inputTokens: 0,
      outputTokens: 0,
      totalTokens: 0,
    } as unknown as ContextUsage;

    return {
      phase: process.env['FOREMAN_PHASE'] ?? 'unknown',
      runId: process.env['FOREMAN_RUN_ID'] ?? 'harness-run',
      seedId: process.env['FOREMAN_SEED_ID'] ?? 'harness-seed',
      getContextUsage: () => usage,
      log: (_msg: string) => undefined,
      ...overrides,
    };
  }

  // ── Event dispatch ───────────────────────────────────────────────────────────

  /**
   * Dispatches a tool_call event to every extension in registration order.
   * Returns the result from the first extension that sets `block: true`, or
   * `undefined` wrapped in a HarnessResult if no extension blocked.
   *
   * Missing required fields on the partial event are filled with safe defaults.
   */
  async dispatchToolCall(event: Partial<ToolCallEvent>): Promise<HarnessResult> {
    const fullEvent: ToolCallEvent = {
      toolName: event.toolName ?? 'Unknown',
      input: event.input ?? {},
      phase: event.phase ?? process.env['FOREMAN_PHASE'],
    };

    const ctx = this.createContext();
    const start = performance.now();
    let blockResult: ToolCallResult = undefined;

    for (const ext of this.extensions) {
      if (!ext.onToolCall) continue;
      const result = await ext.onToolCall(fullEvent, ctx);
      if (result && result.block) {
        blockResult = result;
        break;
      }
    }

    const durationMs = performance.now() - start;
    return { result: blockResult, durationMs };
  }

  /**
   * Dispatches a turn_end event to every extension in registration order.
   * Missing required fields are filled with safe defaults.
   */
  async dispatchTurnEnd(event: Partial<TurnEndEvent>): Promise<void> {
    const fullEvent: TurnEndEvent = {
      turnNumber: event.turnNumber ?? 1,
      contextUsage: event.contextUsage ?? {
        totalTokens: 0,
        inputTokens: 0,
        outputTokens: 0,
      },
    };

    const ctx = this.createContext();

    for (const ext of this.extensions) {
      if (!ext.onTurnEnd) continue;
      await ext.onTurnEnd(fullEvent, ctx);
    }
  }

  // ── Env var helpers ──────────────────────────────────────────────────────────

  /**
   * Sets process.env variables, saving originals for later restoration.
   * Calling setEnv() multiple times accumulates saved originals — the first
   * save for each key wins so cleanup() always restores the pre-harness value.
   */
  setEnv(vars: Record<string, string>): void {
    for (const [key, value] of Object.entries(vars)) {
      if (!this.savedEnv.has(key)) {
        this.savedEnv.set(key, process.env[key]);
      }
      process.env[key] = value;
    }
  }

  /**
   * Restores all env vars that were set via setEnv() or the constructor options.
   * Call this in afterEach/afterAll to prevent test pollution.
   */
  cleanup(): void {
    for (const [key, originalValue] of this.savedEnv.entries()) {
      if (originalValue === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = originalValue;
      }
    }
    this.savedEnv.clear();
  }

  // ── Private helpers ──────────────────────────────────────────────────────────

  private _applyOptions(): void {
    for (const [optKey, envKey] of HARNESS_ENV_MAP) {
      const value = this.options[optKey];
      if (value === undefined) continue;

      let strValue: string;
      if (Array.isArray(value)) {
        strValue = value.join(',');
      } else {
        strValue = String(value);
      }

      // Save original only once
      if (!this.savedEnv.has(envKey)) {
        this.savedEnv.set(envKey, process.env[envKey]);
      }
      process.env[envKey] = strValue;
    }
  }
}
