/**
 * Feature flag utilities — single source of truth for env-driven feature toggles.
 *
 * FOREMAN_TASK_BACKEND controls which task-tracking backend is active:
 *   'sd'  — Seeds (sd) CLI  [default through Sprint 3]
 *   'br'  — Beads Rust (br) [default from Sprint 4, see TRD-023]
 */

export type TaskBackend = 'sd' | 'br';

/**
 * Returns the active task backend.
 * Reads FOREMAN_TASK_BACKEND from the environment.
 * Falls back to 'sd' for any unrecognised or absent value.
 */
export function getTaskBackend(): TaskBackend {
  const val = process.env.FOREMAN_TASK_BACKEND;
  if (val === 'br') return 'br';
  return 'sd'; // default — covers undefined, '', 'sd', and any unknown value
}
