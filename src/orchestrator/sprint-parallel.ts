// ── Sprint Parallelization Analyzer ──────────────────────────────────────
//
// Analyzes task-level cross-sprint dependencies to identify
// which sprints can run in parallel.

import type { SlingPlan, ParallelGroup, ParallelResult, TrdSprint } from "./types.js";

// ── Sprint dependency graph ──────────────────────────────────────────────

/**
 * Build a sprint-level dependency graph from task-level cross-sprint deps.
 * Returns adjacency list: sprintIndex → Set of sprintIndices it depends on.
 */
export function buildSprintDepGraph(
  sprints: TrdSprint[],
): Map<number, Set<number>> {
  // Build task ID → sprint index lookup
  const taskToSprint = new Map<string, number>();
  for (let si = 0; si < sprints.length; si++) {
    for (const story of sprints[si].stories) {
      for (const task of story.tasks) {
        taskToSprint.set(task.trdId, si);
      }
    }
  }

  // Build sprint-level deps
  const graph = new Map<number, Set<number>>();
  for (let si = 0; si < sprints.length; si++) {
    graph.set(si, new Set());
  }

  for (let si = 0; si < sprints.length; si++) {
    for (const story of sprints[si].stories) {
      for (const task of story.tasks) {
        for (const depId of task.dependencies) {
          const depSprint = taskToSprint.get(depId);
          if (depSprint != null && depSprint !== si) {
            graph.get(si)!.add(depSprint);
          }
        }
      }
    }
  }

  return graph;
}

/**
 * Compute parallel groups via topological layering.
 * Sprints at the same topological level with no edges between them
 * form a parallel group.
 */
export function computeParallelGroups(
  graph: Map<number, Set<number>>,
  sprintCount: number,
): ParallelGroup[] {
  // Kahn's algorithm for topological layers
  const inDegree = new Map<number, number>();
  for (let i = 0; i < sprintCount; i++) {
    inDegree.set(i, 0);
  }

  for (const [, deps] of graph) {
    // This sprint depends on `deps` — so this sprint has incoming edges
    // But we need forward edges: if sprint A depends on sprint B,
    // then B → A (B must come before A)
  }

  // Build forward graph: B → A means A depends on B
  const forward = new Map<number, Set<number>>();
  for (let i = 0; i < sprintCount; i++) {
    forward.set(i, new Set());
  }
  for (const [sprint, deps] of graph) {
    for (const dep of deps) {
      forward.get(dep)!.add(sprint);
      inDegree.set(sprint, (inDegree.get(sprint) ?? 0) + 1);
    }
  }

  // BFS by layers
  const layers: number[][] = [];
  let queue = [...inDegree.entries()]
    .filter(([, deg]) => deg === 0)
    .map(([idx]) => idx);

  while (queue.length > 0) {
    layers.push([...queue]);
    const nextQueue: number[] = [];
    for (const node of queue) {
      for (const neighbor of forward.get(node) ?? []) {
        const newDeg = (inDegree.get(neighbor) ?? 1) - 1;
        inDegree.set(neighbor, newDeg);
        if (newDeg === 0) {
          nextQueue.push(neighbor);
        }
      }
    }
    queue = nextQueue;
  }

  // Convert layers to parallel groups (only layers with >1 sprint)
  const groups: ParallelGroup[] = [];
  const labels = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  let labelIdx = 0;

  for (const layer of layers) {
    if (layer.length > 1) {
      groups.push({
        label: labels[labelIdx] ?? String(labelIdx),
        sprintIndices: layer.sort((a, b) => a - b),
      });
      labelIdx++;
    }
  }

  return groups;
}

// ── TRD-stated parallel notes parser ─────────────────────────────────────

interface StatedParallelPair {
  sprintA: number;
  sprintB: number;
}

/**
 * Parse Section 4 for parallelization statements.
 * Looks for patterns like "Sprint 5 and Sprint 6 can run in parallel"
 */
export function parseTrdParallelNotes(content: string): StatedParallelPair[] {
  const pairs: StatedParallelPair[] = [];
  const lines = content.split("\n");
  let inSection4 = false;

  for (const line of lines) {
    if (/^##\s+4\.\s/i.test(line) || line.match(/^## 4\. Dependency/i)) {
      inSection4 = true;
      continue;
    }
    if (inSection4 && /^##\s+\d+\./.test(line) && !line.match(/^##\s+4\./)) {
      break;
    }
    if (!inSection4) continue;

    // Look for "Sprint X and Sprint Y can run in parallel" or "can parallelize"
    const parallelMatch = line.match(
      /Sprint\s+(\d+[a-z]?)\s+and\s+Sprint\s+(\d+[a-z]?)\s+can\s+(run\s+in\s+)?parallel/i,
    );
    if (parallelMatch) {
      pairs.push({
        sprintA: parseInt(parallelMatch[1], 10),
        sprintB: parseInt(parallelMatch[2], 10),
      });
    }
  }

  return pairs;
}

/**
 * Validate auto-computed groups against TRD-stated parallelization.
 * Returns warnings for discrepancies.
 */
export function validate(
  groups: ParallelGroup[],
  statedPairs: StatedParallelPair[],
  sprints: TrdSprint[],
): string[] {
  const warnings: string[] = [];

  // Build set of auto-computed parallel pairs
  const computedPairs = new Set<string>();
  for (const group of groups) {
    for (let i = 0; i < group.sprintIndices.length; i++) {
      for (let j = i + 1; j < group.sprintIndices.length; j++) {
        const a = sprints[group.sprintIndices[i]].number;
        const b = sprints[group.sprintIndices[j]].number;
        computedPairs.add(`${Math.min(a, b)}-${Math.max(a, b)}`);
      }
    }
  }

  // Check each stated pair
  for (const { sprintA, sprintB } of statedPairs) {
    const key = `${Math.min(sprintA, sprintB)}-${Math.max(sprintA, sprintB)}`;
    if (!computedPairs.has(key)) {
      warnings.push(
        `TRD states Sprint ${sprintA} and Sprint ${sprintB} are parallel, ` +
          `but auto-computed dependency analysis disagrees (cross-sprint dependencies exist)`,
      );
    }
  }

  // Check auto-computed pairs not stated in TRD
  const statedKeys = new Set(
    statedPairs.map(({ sprintA, sprintB }) =>
      `${Math.min(sprintA, sprintB)}-${Math.max(sprintA, sprintB)}`,
    ),
  );
  for (const key of computedPairs) {
    if (!statedKeys.has(key)) {
      const [a, b] = key.split("-");
      warnings.push(
        `Auto-computed: Sprint ${a} and Sprint ${b} can run in parallel ` +
          `(not stated in TRD Section 4)`,
      );
    }
  }

  return warnings;
}

// ── Top-level analyzer ───────────────────────────────────────────────────

/**
 * Analyze sprint parallelization for a SlingPlan.
 */
export function analyzeParallel(
  plan: SlingPlan,
  trdContent?: string,
): ParallelResult {
  const graph = buildSprintDepGraph(plan.sprints);
  const groups = computeParallelGroups(graph, plan.sprints.length);

  let warnings: string[] = [];
  if (trdContent) {
    const statedPairs = parseTrdParallelNotes(trdContent);
    warnings = validate(groups, statedPairs, plan.sprints);
  }

  return { groups, warnings };
}
