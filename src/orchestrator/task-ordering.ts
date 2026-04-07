/**
 * task-ordering.ts — Determine execution order for child tasks in an epic.
 *
 * Primary: use bv --robot-next to get graph-aware ordering.
 * Fallback: topological sort of child bead dependencies with priority tiebreaker.
 */

import { BvClient } from "../lib/bv.js";
import type { BeadsRustClient, BrIssueDetail } from "../lib/beads-rust.js";

// ── Types ──────────────────────────────────────────────────────────────────

export interface GroupedTask {
  seedId: string;
  seedTitle: string;
  seedDescription?: string;
}

export type OrderedTask = GroupedTask;

export interface GroupedParentTaskOrderOptions {
  actionableChildTypes?: readonly string[];
  useBv?: boolean;
}

const DEFAULT_ACTIONABLE_CHILD_TYPES = ["task", "bug", "chore"] as const;

export class CircularDependencyError extends Error {
  constructor(public readonly cycle: string[]) {
    super(`Circular dependency detected: ${cycle.join(" → ")}`);
    this.name = "CircularDependencyError";
  }
}

// ── Public API ──────────────────────────────────────────────────────────────

/**
 * Get ordered list of actionable child tasks for a grouped parent container.
 *
 * Tries bv --robot-next first for graph-aware ordering.
 * Falls back to topological sort of br dependencies with priority as tiebreaker.
 *
 * @param parentId    - The parent bead ID.
 * @param brClient    - BeadsRustClient for querying bead details.
 * @param projectPath - Project root for bv invocation.
 * @param options     - Ordering options, including child type filtering.
 * @returns Ordered list of child tasks.
 */
export async function getGroupedParentTaskOrder(
  parentId: string,
  brClient: BeadsRustClient,
  projectPath: string,
  options: GroupedParentTaskOrderOptions = {},
): Promise<GroupedTask[]> {
  const actionableChildTypes = new Set(options.actionableChildTypes ?? DEFAULT_ACTIONABLE_CHILD_TYPES);
  const useBv = options.useBv ?? true;

  // Get all children of the grouped parent
  const parentDetail = await brClient.show(parentId) as BrIssueDetail;
  const childIds = parentDetail.children ?? [];

  if (childIds.length === 0) {
    return [];
  }

  // Load details for all children
  const childDetails = new Map<string, BrIssueDetail>();
  for (const childId of childIds) {
    try {
      const detail = await brClient.show(childId) as BrIssueDetail;
      if (actionableChildTypes.has(detail.type)) {
        childDetails.set(childId, detail);
      }
    } catch {
      // Skip children we can't load
    }
  }

  if (childDetails.size === 0) {
    return [];
  }

  // Try bv ordering first
  if (useBv) {
    const bvOrder = await getBvOrder(childDetails, projectPath);
    if (bvOrder !== null) {
      return bvOrder;
    }
  }

  // Fallback: topological sort
  return topologicalSort(childDetails);
}

/**
 * Backward-compatible wrapper for epic child ordering.
 *
 * Existing epic execution paths call this helper directly. Story/grouped-parent
 * dispatch can use getGroupedParentTaskOrder() with the same ordering behavior.
 */
export async function getTaskOrder(
  epicId: string,
  brClient: BeadsRustClient,
  projectPath: string,
  useBv: boolean = true,
): Promise<GroupedTask[]> {
  return getGroupedParentTaskOrder(epicId, brClient, projectPath, { useBv });
}

// ── BV ordering ─────────────────────────────────────────────────────────────

async function getBvOrder(
  childDetails: Map<string, BrIssueDetail>,
  projectPath: string,
): Promise<OrderedTask[] | null> {
  const bv = new BvClient(projectPath);
  const childIds = new Set(childDetails.keys());

  // Use bv --robot-next iteratively to build order.
  // Since bv considers the full graph including blockers, we query it
  // and filter results to only include our epic's children.
  const triage = await bv.robotTriage();
  if (triage === null) return null;

  const ordered: OrderedTask[] = [];
  const seen = new Set<string>();

  // Use triage recommendations, filtered to our children
  for (const rec of triage.recommendations) {
    if (childIds.has(rec.id) && !seen.has(rec.id)) {
      const detail = childDetails.get(rec.id);
      if (detail) {
        ordered.push({
          seedId: detail.id,
          seedTitle: detail.title,
          seedDescription: detail.description ?? undefined,
        });
        seen.add(rec.id);
      }
    }
  }

  // Add any children not in triage results (bv may not rank all)
  for (const [id, detail] of childDetails) {
    if (!seen.has(id)) {
      ordered.push({
        seedId: detail.id,
        seedTitle: detail.title,
        seedDescription: detail.description ?? undefined,
      });
    }
  }

  return ordered.length > 0 ? ordered : null;
}

// ── Topological sort ────────────────────────────────────────────────────────

/**
 * Topological sort of child tasks based on their dependency edges.
 * Uses Kahn's algorithm. Priority (lower = higher priority) breaks ties.
 *
 * @throws CircularDependencyError if a cycle is detected.
 */
function topologicalSort(childDetails: Map<string, BrIssueDetail>): OrderedTask[] {
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
      // dep is a BrDepRef object — extract its id
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
    const id = queue.shift()!;
    const detail = childDetails.get(id)!;
    result.push({
      seedId: detail.id,
      seedTitle: detail.title,
      seedDescription: detail.description ?? undefined,
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
    const remaining = [...childIds].filter(id => !result.some(r => r.seedId === id));
    throw new CircularDependencyError(remaining);
  }

  return result;
}
