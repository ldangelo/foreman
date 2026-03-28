/**
 * Feature flag utilities — single source of truth for env-driven feature toggles.
 *
 * TRD-024: FOREMAN_TASK_BACKEND feature flag removed. br is the only backend.
 */
/**
 * Returns the active task backend.
 * TRD-024: sd backend removed; br is the only backend.
 */
export function getTaskBackend() {
    return 'br'; // TRD-024: sd backend removed; br is the only backend
}
//# sourceMappingURL=feature-flags.js.map