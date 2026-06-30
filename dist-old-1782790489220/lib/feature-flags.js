/**
 * Feature flag utilities — single source of truth for env-driven feature toggles.
 *
 * TRD-024: FOREMAN_TASK_BACKEND feature flag removed. The native Postgres
 * task store is the only supported backend (beads is import-only).
 */
/**
 * Returns the active task backend.
 * TRD-024: Native Postgres task store is the only supported backend.
 */
export function getTaskBackend() {
    return 'native'; // TRD-024: native Postgres store is the only supported backend
}
//# sourceMappingURL=feature-flags.js.map