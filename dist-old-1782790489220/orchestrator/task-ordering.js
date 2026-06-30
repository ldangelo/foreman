/**
 * task-ordering.ts — Determine execution order for child tasks in an epic.
 *
 * Primary: use bv --robot-next to get graph-aware ordering.
 * Fallback: topological sort of child bead dependencies with priority tiebreaker.
 */
import { BvClient } from "../lib/bv.js";
export class CircularDependencyError extends Error {
    cycle;
    constructor(cycle) {
        super(`Circular dependency detected: ${cycle.join(" → ")}`);
        this.cycle = cycle;
        this.name = "CircularDependencyError";
    }
}
// ── Public API ──────────────────────────────────────────────────────────────
/**
 * Get ordered list of child tasks for an epic bead.
 *
 * Tries bv --robot-next first for graph-aware ordering.
 * Falls back to topological sort of br dependencies with priority as tiebreaker.
 *
 * @param epicId      - The parent epic bead ID.
 * @param brClient    - BeadsRustClient for querying bead details.
 * @param projectPath - Project root for bv invocation.
 * @param useBv       - Whether to attempt bv ordering (default: true).
 * @returns Ordered list of child tasks.
 */
export async function getTaskOrder(epicId, brClient, projectPath, useBv = true) {
    // Get all children of the epic
    const epicDetail = await brClient.show(epicId);
    const childIds = epicDetail.children ?? [];
    if (childIds.length === 0) {
        return [];
    }
    // Load details for all children
    const childDetails = new Map();
    for (const childId of childIds) {
        try {
            const detail = await brClient.show(childId);
            // Only include task-type children (skip feature/story containers)
            if (detail.type === "task" || detail.type === "bug" || detail.type === "chore") {
                childDetails.set(childId, detail);
            }
        }
        catch {
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
// ── BV ordering ─────────────────────────────────────────────────────────────
async function getBvOrder(childDetails, projectPath) {
    const bv = new BvClient(projectPath);
    const childIds = new Set(childDetails.keys());
    // Use bv --robot-next iteratively to build order.
    // Since bv considers the full graph including blockers, we query it
    // and filter results to only include our epic's children.
    const triage = await bv.robotTriage();
    if (triage === null)
        return null;
    const ordered = [];
    const seen = new Set();
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
function topologicalSort(childDetails) {
    const childIds = new Set(childDetails.keys());
    // Build adjacency and in-degree within the child set
    const inDegree = new Map();
    const dependents = new Map(); // dep → [tasks that depend on it]
    for (const id of childIds) {
        inDegree.set(id, 0);
        dependents.set(id, []);
    }
    for (const [id, detail] of childDetails) {
        for (const dep of detail.dependencies) {
            // dep is a BrDepRef object — extract its id
            const depId = typeof dep === "string" ? dep : dep.id;
            // Only count deps within our child set
            if (childIds.has(depId)) {
                inDegree.set(id, (inDegree.get(id) ?? 0) + 1);
                dependents.get(depId)?.push(id);
            }
        }
    }
    // Kahn's algorithm with priority-based tie-breaking
    const queue = [];
    for (const [id, deg] of inDegree) {
        if (deg === 0)
            queue.push(id);
    }
    // Sort queue by priority (lower number = higher priority)
    const getPriority = (id) => {
        const detail = childDetails.get(id);
        if (!detail)
            return 99;
        const p = parseInt(detail.priority.replace(/^P/i, ""), 10);
        return isNaN(p) ? 99 : p;
    };
    queue.sort((a, b) => getPriority(a) - getPriority(b));
    const result = [];
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
//# sourceMappingURL=task-ordering.js.map