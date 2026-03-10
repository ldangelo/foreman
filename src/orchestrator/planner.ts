import type { BeadsClient, Bead } from "../lib/beads.js";
import type { DecompositionPlan } from "./types.js";

export interface ExecutionResult {
  epicBeadId: string;
  taskBeadIds: string[];
}

/**
 * Map word priorities to beads P0-P4 format.
 * Beads CLI expects: P0 (highest) through P4 (lowest).
 */
function toBeadsPriority(priority: string): string {
  switch (priority.toLowerCase()) {
    case "critical": return "P0";
    case "high": return "P1";
    case "medium": return "P2";
    case "low": return "P3";
    default: return "P2";
  }
}

/**
 * Execute a decomposition plan by creating beads in the project.
 *
 * Creates an epic bead, then child task beads with parent references
 * and inter-task dependencies.
 */
export async function executePlan(
  plan: DecompositionPlan,
  beads: BeadsClient,
): Promise<ExecutionResult> {
  // 1. Create the epic bead
  const epicBead: Bead = await beads.create(plan.epic.title, {
    type: "epic",
    priority: "P1",
    description: plan.epic.description,
  });

  // 2. Create task beads as children of the epic
  // Map task title → bead ID for dependency resolution
  const titleToId = new Map<string, string>();
  const taskBeadIds: string[] = [];

  for (const task of plan.tasks) {
    const taskBead: Bead = await beads.create(task.title, {
      type: "task",
      priority: toBeadsPriority(task.priority),
      parent: epicBead.id,
      description: task.description,
      labels: [`complexity:${task.estimatedComplexity}`],
    });

    titleToId.set(task.title, taskBead.id);
    taskBeadIds.push(taskBead.id);
  }

  // 3. Wire up dependencies
  for (const task of plan.tasks) {
    const taskId = titleToId.get(task.title);
    if (!taskId) continue;

    for (const depTitle of task.dependencies) {
      const depId = titleToId.get(depTitle);
      if (depId) {
        await beads.addDependency(taskId, depId);
      }
    }
  }

  return { epicBeadId: epicBead.id, taskBeadIds };
}
