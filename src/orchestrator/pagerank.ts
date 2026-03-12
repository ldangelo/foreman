/**
 * PageRank-based impact scoring for ready task prioritization.
 *
 * Scores each ready seed by how much downstream work it unblocks,
 * combining direct + transitive dependent counts with a priority boost.
 * This allows the Dispatcher to dispatch highest-impact tasks first.
 */

import type { Seed, SeedGraph } from "../lib/seeds.js";

// ── Public API ───────────────────────────────────────────────────────────

/**
 * Calculate impact scores for a set of ready seeds given the full dependency graph.
 *
 * Score formula (per ready seed):
 *   score = directDependents * 1.0 + indirectDependents * 0.5 + priorityBoost(seed.priority)
 *
 * Only `"blocks"` edges are counted — `"parent"` edges are organisational only
 * and do not affect `sd ready` semantics.
 *
 * @param readySeeds  Seeds returned by `seeds.ready()`.
 * @param graph       Full project dependency graph from `seeds.getGraph()`.
 * @returns           Map from seedId → numeric impact score (higher = higher priority).
 */
export function calculateImpactScores(
  readySeeds: Seed[],
  graph: SeedGraph,
): Map<string, number> {
  const scores = new Map<string, number>();

  // Build reverse adjacency: for each seed, which seeds directly depend on it?
  // An edge { from, to } means `from` depends on `to`, so `to` is depended upon by `from`.
  // We want: dependentsOf[to] = [...froms that depend on to]
  const dependentsOf = buildDependentsMap(graph);

  for (const seed of readySeeds) {
    const direct = getDirectDependents(seed.id, dependentsOf);
    const indirect = getTransitiveDependents(seed.id, dependentsOf, new Set(direct));
    const boost = priorityBoost(seed.priority);
    const score = direct.length * 1.0 + indirect.length * 0.5 + boost;
    scores.set(seed.id, score);
  }

  return scores;
}

// ── Helpers ──────────────────────────────────────────────────────────────

/**
 * Build a reverse dependency map: seedId → Set<seedId that directly depends on it>.
 * Only `"blocks"` edges are included.
 */
export function buildDependentsMap(graph: SeedGraph): Map<string, Set<string>> {
  const map = new Map<string, Set<string>>();

  for (const edge of graph.edges) {
    if (edge.type !== "blocks") continue;  // skip "parent" (organisational only)

    // edge.to is the blocker; edge.from depends on it
    if (!map.has(edge.to)) map.set(edge.to, new Set());
    map.get(edge.to)!.add(edge.from);
  }

  return map;
}

/**
 * Return the set of seedIds that directly depend on `seedId`.
 */
export function getDirectDependents(
  seedId: string,
  dependentsOf: Map<string, Set<string>>,
): string[] {
  return Array.from(dependentsOf.get(seedId) ?? []);
}

/**
 * Return all seedIds that transitively depend on `seedId` (not including direct ones
 * already provided via `exclude`).
 *
 * Uses BFS to walk the dependency graph. Handles DAGs safely; cycles (which
 * should not exist in a valid `sd` project) are guarded against via visited set.
 *
 * **Dual role of `exclude`**: this parameter serves two purposes simultaneously:
 * 1. **BFS frontier** — the queue is seeded with `[...exclude]`, so the traversal
 *    begins from the direct dependents (one level below `seedId`) rather than
 *    from `seedId` itself. This avoids re-visiting nodes that were already counted
 *    as direct dependents.
 * 2. **Exclusion filter** — entries in `exclude` are added to `visited` up-front,
 *    so they are never added to the `indirect` result array.
 *
 * If `exclude` is empty (no direct dependents), the queue starts empty and the
 * function immediately returns `[]` — the correct result for a leaf-like seed.
 *
 * @param seedId       Root seed whose downstream reach we want.
 * @param dependentsOf Reverse dependency map (from `buildDependentsMap`).
 * @param exclude      Direct dependent IDs: used as both the BFS starting frontier
 *                     and as the exclusion filter for the returned array.
 * @returns            Array of transitive (indirect) dependent seed IDs.
 */
export function getTransitiveDependents(
  seedId: string,
  dependentsOf: Map<string, Set<string>>,
  exclude: Set<string>,
): string[] {
  const visited = new Set<string>([seedId, ...exclude]);
  const queue: string[] = [...exclude];  // start BFS from direct dependents
  const indirect: string[] = [];

  while (queue.length > 0) {
    const current = queue.shift()!;
    const nextLevel = dependentsOf.get(current) ?? new Set();
    for (const dep of nextLevel) {
      if (!visited.has(dep)) {
        visited.add(dep);
        indirect.push(dep);
        queue.push(dep);
      }
    }
  }

  return indirect;
}

/**
 * Convert a seed priority string (P0-P4) to a numeric boost value.
 *
 * - P0 = 1.0  (most urgent)
 * - P1 = 0.8
 * - P2 = 0.6
 * - P3 = 0.4
 * - P4 = 0.0  (lowest urgency)
 * - unknown   = 0.0
 *
 * Accepts `string` to match the `Seed.priority` interface type. Unrecognised
 * values (including an empty string) fall through to the default `0.0` case.
 */
export function priorityBoost(priority: string): number {
  switch (priority) {
    case "P0": return 1.0;
    case "P1": return 0.8;
    case "P2": return 0.6;
    case "P3": return 0.4;
    case "P4": return 0.0;
    default:   return 0.0;
  }
}
