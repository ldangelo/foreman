/**
 * task-ordering.ts — Determine execution order for child tasks in an epic.
 *
 * Uses topological sort of child task dependencies with priority tiebreaker.
 */

// ── Types ──────────────────────────────────────────────────────────────────

interface TaskOrderingDependencyRef {
  id: string;
}

export interface TaskOrderingIssueDetail {
  id: string;
  title: string;
  type: string;
  priority: string;
  description?: string | null;
  children?: string[];
  dependencies: Array<string | TaskOrderingDependencyRef>;
}

export interface TaskOrderingClient {
  show(id: string): Promise<TaskOrderingIssueDetail>;
}

export interface OrderedTask {
  taskId: string;
  taskTitle: string;
  taskDescription?: string;
}

export class CircularDependencyError extends Error {
  constructor(public readonly cycle: string[]) {
    super(`Circular dependency detected: ${cycle.join(" → ")}`);
    this.name = "CircularDependencyError";
  }
}

// ── Public API ──────────────────────────────────────────────────────────────

/**
 * Get ordered list of child tasks for an epic task.
 *
 * @param epicId - The parent epic task ID.
 * @param taskClient - Client for querying task details.
 * @returns Ordered list of child tasks.
 */
export async function getTaskOrder(
  epicId: string,
  taskClient: TaskOrderingClient,
  _projectPath?: string,
  _useExternalOrdering?: boolean,
): Promise<OrderedTask[]> {
  // Get all children of the epic
  const epicDetail = await taskClient.show(epicId);
  const childIds = epicDetail.children ?? [];

  if (childIds.length === 0) {
    return [];
  }

  // Load details for all children
  const childDetails = new Map<string, TaskOrderingIssueDetail>();
  for (const childId of childIds) {
    try {
      const detail = await taskClient.show(childId);
      // Only include task-type children (skip feature/story containers)
      if (detail.type === "task" || detail.type === "bug" || detail.type === "chore") {
        childDetails.set(childId, detail);
      }
    } catch {
      // Skip children we can't load
    }
  }

  if (childDetails.size === 0) {
    return [];
  }

  return topologicalSort(childDetails);
}

// ── Topological sort ────────────────────────────────────────────────────────

/**
 * Topological sort of child tasks based on their dependency edges.
 * Uses Kahn's algorithm. Priority (lower = higher priority) breaks ties.
 *
 * @throws CircularDependencyError if a cycle is detected.
 */
function topologicalSort(childDetails: Map<string, TaskOrderingIssueDetail>): OrderedTask[] {
  const childIds = new Set(childDetails.keys());

  // Build adjacency and in-degree within the child set
  const inDegree = new Map<string, number>();
  const dependents = new Map<string, string[]>(); // dep → [tasks that depend on it]

  for (const id of childIds) {
    inDegree.set(id, 0);
    dependents.set(id, []);
  }

  for (const [id, detail] of childDetails) {
    for (const dep of detail.dependencies) {
      const depId = typeof dep === "string" ? dep : (dep as { id: string }).id;
      // Only count deps within our child set
      if (childIds.has(depId)) {
        inDegree.set(id, (inDegree.get(id) ?? 0) + 1);
        dependents.get(depId)?.push(id);
      }
    }
  }

  // Kahn's algorithm with priority-based tie-breaking
  const queue: string[] = [];
  for (const [id, deg] of inDegree) {
    if (deg === 0) queue.push(id);
  }

  // Sort queue by priority (lower number = higher priority)
  const getPriority = (id: string): number => {
    const detail = childDetails.get(id);
    if (!detail) return 99;
    const p = parseInt(detail.priority.replace(/^P/i, ""), 10);
    return isNaN(p) ? 99 : p;
  };

  queue.sort((a, b) => getPriority(a) - getPriority(b));

  const result: OrderedTask[] = [];
  while (queue.length > 0) {
    const id = queue.shift();
    if (!id) {
      break;
    }
    const detail = childDetails.get(id);
    if (!detail) {
      continue;
    }
    result.push({
      taskId: detail.id,
      taskTitle: detail.title,
      taskDescription: detail.description ?? undefined,
    });

    for (const dependent of dependents.get(id) ?? []) {
      const newDeg = (inDegree.get(dependent) ?? 1) - 1;
      inDegree.set(dependent, newDeg);
      if (newDeg === 0) {
        // Insert sorted by priority
        const pri = getPriority(dependent);
        let insertIdx = queue.length;
        for (let j = 0; j < queue.length; j++) {
          if (getPriority(queue[j]) > pri) {
            insertIdx = j;
            break;
          }
        }
        queue.splice(insertIdx, 0, dependent);
      }
    }
  }

  if (result.length < childDetails.size) {
    // Cycle detected — find the cycle for error reporting
    const remaining = [...childIds].filter(id => !result.some(r => r.taskId === id));
    throw new CircularDependencyError(remaining);
  }

  return result;
}
