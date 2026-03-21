/**
 * Workflow configuration and resolution utilities.
 *
 * Provides label-based workflow override: if a bead has a `workflow:<name>`
 * label, that overrides the bead's type field for workflow/prompt selection.
 */

/**
 * Resolve the effective workflow type for a seed.
 *
 * Resolution order:
 *   1. First `workflow:<name>` label on the bead
 *   2. Bead type field (e.g. "feature", "bug", "task")
 *
 * @param seedType - The bead's type field (e.g. "feature")
 * @param labels   - Optional list of labels on the bead
 * @returns The resolved workflow name to use for prompt/config selection
 */
export function resolveWorkflowType(seedType: string, labels?: string[]): string {
  if (labels) {
    for (const label of labels) {
      if (label.startsWith("workflow:")) {
        return label.slice("workflow:".length);
      }
    }
  }
  return seedType;
}
