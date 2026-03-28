import type { SlingPlan, ParallelGroup, ParallelResult, TrdSprint } from "./types.js";
/**
 * Build a sprint-level dependency graph from task-level cross-sprint deps.
 * Returns adjacency list: sprintIndex → Set of sprintIndices it depends on.
 */
export declare function buildSprintDepGraph(sprints: TrdSprint[]): Map<number, Set<number>>;
/**
 * Compute parallel groups via topological layering.
 * Sprints at the same topological level with no edges between them
 * form a parallel group.
 */
export declare function computeParallelGroups(graph: Map<number, Set<number>>, sprintCount: number): ParallelGroup[];
interface StatedParallelPair {
    sprintA: number;
    sprintB: number;
}
/**
 * Parse Section 4 for parallelization statements.
 * Looks for patterns like "Sprint 5 and Sprint 6 can run in parallel"
 */
export declare function parseTrdParallelNotes(content: string): StatedParallelPair[];
/**
 * Validate auto-computed groups against TRD-stated parallelization.
 * Returns warnings for discrepancies.
 */
export declare function validate(groups: ParallelGroup[], statedPairs: StatedParallelPair[], sprints: TrdSprint[]): string[];
/**
 * Analyze sprint parallelization for a SlingPlan.
 */
export declare function analyzeParallel(plan: SlingPlan, trdContent?: string): ParallelResult;
export {};
//# sourceMappingURL=sprint-parallel.d.ts.map