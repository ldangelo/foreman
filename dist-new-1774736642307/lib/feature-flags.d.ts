/**
 * Feature flag utilities — single source of truth for env-driven feature toggles.
 *
 * TRD-024: FOREMAN_TASK_BACKEND feature flag removed. br is the only backend.
 */
export type TaskBackend = 'sd' | 'br';
/**
 * Returns the active task backend.
 * TRD-024: sd backend removed; br is the only backend.
 */
export declare function getTaskBackend(): TaskBackend;
//# sourceMappingURL=feature-flags.d.ts.map