/**
 * Feature flag utilities — single source of truth for env-driven feature toggles.
 *
 * FOREMAN_TASK_BACKEND controls which task-tracking backend is active:
 *   'br'  — Beads Rust (br) [default from Sprint 4, TRD-023]
 *   'sd'  — Seeds (sd) CLI  [opt-in for legacy compatibility]
 */

export type TaskBackend = 'sd' | 'br';

/**
 * Returns the active task backend.
 * Reads FOREMAN_TASK_BACKEND from the environment.
 * Falls back to 'br' — the default from Sprint 4 (TRD-023).
 * Set FOREMAN_TASK_BACKEND=sd to opt back into the legacy seeds backend.
 */
export function getTaskBackend(): TaskBackend {
  const val = process.env.FOREMAN_TASK_BACKEND;
  if (val === 'sd') return 'sd';
  return 'br'; // default — covers undefined, '', 'br', and any unknown value
}
