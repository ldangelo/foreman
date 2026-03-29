/**
 * pipeline-events.ts — Typed event bus for pipeline lifecycle events.
 *
 * Wraps Node EventEmitter with a discriminated union of typed PipelineEvent
 * variants. All handler errors are caught by safeEmit and re-emitted as
 * 'pipeline:error' events, ensuring the executor never crashes due to a
 * misbehaving handler.
 */

import { EventEmitter } from "node:events";

// ── Event Types ───────────────────────────────────────────────────────────────

/** All possible pipeline lifecycle events. */
export type PipelineEvent =
  | { type: "phase:start";       runId: string; phase: string; worktreePath: string }
  | { type: "phase:complete";    runId: string; phase: string; worktreePath: string; cost: number }
  | { type: "phase:fail";        runId: string; phase: string; error: string; retryable: boolean }
  | { type: "rebase:start";      runId: string; phase: string; target: string }
  | { type: "rebase:clean";      runId: string; phase: string; upstreamCommits: number; changedFiles: string[] }
  | { type: "rebase:conflict";   runId: string; phase: string; conflictingFiles: string[] }
  | { type: "rebase:resolved";   runId: string; resumePhase: string }
  | { type: "pipeline:complete"; runId: string; status: string }
  | { type: "pipeline:fail";     runId: string; error: string }
  | { type: "pipeline:error";    runId: string; originalEvent: string; error: string };

/** Extract the event object type for a given event type string. */
export type PipelineEventOf<T extends PipelineEvent["type"]> = Extract<PipelineEvent, { type: T }>;

// ── Handler type ──────────────────────────────────────────────────────────────

export type PipelineEventHandler<T extends PipelineEvent["type"]> =
  (event: PipelineEventOf<T>) => void | Promise<void>;

// ── PipelineEventBus ──────────────────────────────────────────────────────────

/**
 * Typed event bus for pipeline lifecycle events.
 *
 * Wraps Node EventEmitter with:
 * - `emit<T extends PipelineEvent>(event: T): void` — typed emit
 * - `on<T extends PipelineEvent['type']>(type, handler): void` — typed listener
 * - `off<T extends PipelineEvent['type']>(type, handler): void` — typed removal
 * - `safeEmit<T extends PipelineEvent>(event: T): void` — catches handler errors,
 *    re-emits as 'pipeline:error' without propagating to the caller
 */
export class PipelineEventBus {
  private readonly emitter = new EventEmitter();

  constructor() {
    // Prevent Node's default unhandled-error behaviour on 'pipeline:error' —
    // the bus itself handles errors internally via safeEmit.
    this.emitter.on("error", () => {});
  }

  /**
   * Register a typed event handler.
   *
   * The handler is called synchronously when the event is emitted via
   * `emit()`. For async handlers, use `safeEmit()` to ensure errors are
   * captured rather than causing unhandled promise rejections.
   */
  on<T extends PipelineEvent["type"]>(
    type: T,
    handler: PipelineEventHandler<T>,
  ): void {
    this.emitter.on(type, handler as (event: unknown) => void);
  }

  /**
   * Register a one-shot event handler that fires at most once.
   */
  once<T extends PipelineEvent["type"]>(
    type: T,
    handler: PipelineEventHandler<T>,
  ): void {
    this.emitter.once(type, handler as (event: unknown) => void);
  }

  /**
   * Remove a previously registered event handler.
   */
  off<T extends PipelineEvent["type"]>(
    type: T,
    handler: PipelineEventHandler<T>,
  ): void {
    this.emitter.off(type, handler as (event: unknown) => void);
  }

  /**
   * Emit a typed pipeline event. Handlers are called synchronously.
   * Any thrown errors propagate to the caller — use `safeEmit` if you
   * want errors routed to `pipeline:error` instead.
   */
  emit<T extends PipelineEvent>(event: T): void {
    this.emitter.emit(event.type, event);
  }

  /**
   * Emit a pipeline event with error isolation.
   *
   * Calls all registered handlers (including async ones). If any handler
   * throws synchronously or returns a rejected Promise, the error is caught
   * and re-emitted as a `pipeline:error` event. The original emit call never
   * throws.
   *
   * This is the preferred emit method for the pipeline executor — it ensures
   * a misbehaving handler never crashes the pipeline.
   */
  safeEmit<T extends PipelineEvent>(event: T): void {
    const listeners = this.emitter.rawListeners(event.type);

    for (const listener of listeners) {
      try {
        // rawListeners may return a wrapper for once() calls; invoke it directly
        const maybeWrapped = listener as unknown as { listener?: (...args: unknown[]) => unknown };
        const fn = typeof maybeWrapped.listener === "function"
          ? maybeWrapped.listener
          : (listener as (...args: unknown[]) => unknown);

        const result = (fn as (event: T) => unknown)(event);

        // Catch async handler rejections
        if (result instanceof Promise) {
          result.catch((err: unknown) => {
            const errorEvent: PipelineEventOf<"pipeline:error"> = {
              type: "pipeline:error",
              runId: (event as PipelineEventOf<"phase:complete">).runId ?? "unknown",
              originalEvent: event.type,
              error: err instanceof Error ? err.message : String(err),
            };
            this.emitter.emit("pipeline:error", errorEvent);
          });
        }
      } catch (err: unknown) {
        const errorEvent: PipelineEventOf<"pipeline:error"> = {
          type: "pipeline:error",
          runId: (event as PipelineEventOf<"phase:complete">).runId ?? "unknown",
          originalEvent: event.type,
          error: err instanceof Error ? err.message : String(err),
        };
        this.emitter.emit("pipeline:error", errorEvent);
      }
    }
  }

  /**
   * Remove all listeners for all events. Useful for cleanup in tests.
   */
  removeAllListeners(): void {
    this.emitter.removeAllListeners();
  }

  // ── Phase Gate ────────────────────────────────────────────────────────────

  private _phaseGate: Promise<boolean> | null = null;
  private _resolvePhaseGate: ((suspended: boolean) => void) | null = null;

  /**
   * Open the phase gate synchronously.
   *
   * Must be called synchronously (before the first `await`) by a phase:complete
   * handler that needs to pause the pipeline executor before it advances to the
   * next phase. The executor calls `waitForPhaseGate()` after every `safeEmit`
   * of `phase:complete` to check whether it should suspend.
   *
   * Typically called by RebaseHook before starting a mid-pipeline rebase.
   */
  holdPhaseGate(): void {
    this._phaseGate = new Promise<boolean>((resolve) => {
      this._resolvePhaseGate = resolve;
    });
  }

  /**
   * Release the phase gate with a "continue" verdict.
   * Called by the hook after completing cleanly (no suspension needed).
   */
  releasePhaseGate(): void {
    this._resolvePhaseGate?.(false);
    this._phaseGate = null;
    this._resolvePhaseGate = null;
  }

  /**
   * Release the phase gate with a "suspend" verdict.
   * Called by the hook when the pipeline should stop (e.g., rebase conflict).
   */
  suspendPhaseGate(): void {
    this._resolvePhaseGate?.(true);
    this._phaseGate = null;
    this._resolvePhaseGate = null;
  }

  /**
   * Await the phase gate.
   *
   * Returns `true` if the pipeline should suspend after the current phase,
   * `false` if it should continue normally. Returns `false` immediately when
   * no gate was opened (the common case for phases with no mid-pipeline hooks).
   */
  async waitForPhaseGate(): Promise<boolean> {
    if (!this._phaseGate) return false;
    return this._phaseGate;
  }
}
