# Explorer Report: PageRank-based task prioritization for sd ready

## Summary

Implement PageRank-based prioritization for the `sd ready` task queue in the Dispatcher. Currently, ready tasks are dispatched in the order returned by `sd ready` (typically insertion order or priority field). PageRank will re-order ready tasks to prioritize those that unblock the most downstream work, improving overall project parallelization and reducing blocking dependencies.

## Relevant Files

### 1. **src/orchestrator/dispatcher.ts** (lines 40-194)
- **Purpose**: Orchestrates task dispatch, creates worktrees, spawns agent workers
- **Current State**:
  - Line 59: `let readySeeds = await this.seeds.ready();` fetches ready tasks
  - Lines 81-98: Iterates through readySeeds in order, dispatching up to `maxAgents` tasks
  - Line 101: Seeds converted to SeedInfo via `seedToInfo(seed)`
- **Relevance**: **PRIMARY LOCATION** — must insert PageRank scoring and sorting logic here
- **Implementation Point**: After `seeds.ready()` call, before iteration loop

### 2. **src/lib/seeds.ts** (lines 17-41, 174-228)
- **Purpose**: Wrapper around `sd` CLI for task management
- **Current State**:
  - Line 38-41: `SeedGraph` interface with `nodes: Seed[]` and `edges: { from, to, type }[]`
  - Line 223-228: `getGraph()` method returns full dependency graph
  - Line 174-177: `ready()` method returns unblocked tasks (array of Seed)
- **Relevance**: **SECONDARY** — provides graph data structure and `getGraph()` API needed by PageRank calculator
- **Note**: Graph edges represent dependencies: `edge.from` depends on `edge.to` (child → parent in dependency sense)

### 3. **src/orchestrator/refinery.ts** (lines 67-100)
- **Purpose**: Merges completed task branches in dependency order
- **Current State**:
  - Lines 71: Calls `seeds.getGraph()` to get full graph
  - Lines 72-99: Implements topological sort (Kahn's algorithm) for merge ordering
  - Lines 74-76: Builds dependency map from edges: `depMap[from] = Set of to values`
- **Relevance**: **REFERENCE IMPLEMENTATION** — demonstrates how to:
  - Fetch graph from seeds client
  - Build adjacency structures from edges
  - Use graph algorithm (topological sort) for ordering
- **Pattern to Follow**: Create similar graph-processing logic for PageRank

### 4. **src/orchestrator/types.ts** (lines 45-51)
- **Purpose**: Shared TypeScript interfaces
- **Current State**: `SeedInfo` interface with `id, title, description?, priority?, type?`
- **Relevance**: May need to add `pageRankScore?: number` field to carry scoring info through dispatch pipeline (optional enhancement)

### 5. **src/orchestrator/__tests__/dispatcher.test.ts** (lines 1-65)
- **Purpose**: Unit tests for Dispatcher
- **Current State**: Tests only `selectModel()` method, not dispatch logic
- **Relevance**: Will need new tests for PageRank scoring and sorting

## Architecture & Patterns

### Dependency Graph Structure
```typescript
interface SeedGraph {
  nodes: Seed[];
  edges: { from: string; to: string; type: string }[];
}
```

**Edge Semantics**:
- `edge.from` is the seed that **has the dependency** (child/dependent)
- `edge.to` is the seed being **depended upon** (parent/blocker)
- Example: If Task A depends on Task B, edge is `{ from: "A", to: "B" }`

**Edge Types**: `"blocks"` (blocking dependency) and `"parent"` (organizational only — doesn't affect `sd ready`)

### Current Task Selection Pattern
```typescript
// dispatcher.ts line 59
let readySeeds = await this.seeds.ready();  // Returns Seed[]

// No scoring — iterate in order
for (const seed of readySeeds) {
  if (dispatched.length >= available) break;
  // Dispatch seed...
}
```

### Graph Algorithm Precedent
The refinery.ts already implements Kahn's algorithm for topological sorting:
- Builds adjacency structures from graph edges
- Maintains in-degree tracking
- Returns nodes in dependency order

### PageRank Algorithm for Task Prioritization

**Goal**: Score each ready task by how many downstream tasks it unblocks.

**Algorithm Overview**:
1. Get dependency graph via `seeds.getGraph()`
2. For each ready seed, calculate a score based on:
   - **Number of direct dependents**: Seeds that directly depend on this task (outgoing edges)
   - **Downstream reach**: How many seeds transitively depend on this task (recursive)
   - **Priority weight**: Combine with seed's existing priority field (P0-P4)

**Standard PageRank Formula** (simplified for DAG):
```
score(node) = (1 - d) + d * Σ(score(incoming) / outDegree(incoming))
```

**Simplified for Task DAG** (recommended for clarity):
```
impactScore(taskId) =
  directDependents.length * 1.0 +  // Tasks that immediately depend on this
  indirectDependents.length * 0.5 +  // Tasks that transitively depend on this
  priorityBoost(seed.priority)      // P0=1.0, P1=0.8, P2=0.6, P3=0.4, P4=0.0
```

**Ready Task Ordering**:
- Calculate impact score for each ready seed
- Sort ready tasks by score (descending)
- Dispatch highest-scoring tasks first

### Design Decisions

1. **Calculation Scope**:
   - Only consider seeds in the **full project graph** (not subset)
   - Include ready + unready seeds (to know what's downstream even if blocked)

2. **Caching**:
   - Optional: Cache scores between dispatch iterations if graph is stable
   - For now, simple recalculation is acceptable (graph typically < 1000 nodes)

3. **Tie-breaking**:
   - If scores equal, fall back to existing priority field
   - If still equal, use insertion order (stable sort)

4. **Edge Type Filtering**:
   - Count only `"blocks"` type edges (skip `"parent"` organizational links)
   - This respects `sd ready` semantics (parent deps don't affect readiness)

## Dependencies

### What Dispatcher.dispatch() depends on
1. **seeds.ready()** — returns ready Seed[] (unchanged)
2. **seeds.getGraph()** — NEW: needed to calculate impact scores (currently unused in dispatcher)
3. **SeedGraph interface** — defines node/edge structure (from seeds.ts)

### What depends on Dispatcher.dispatch()
1. **run.ts command** — calls dispatcher.dispatch() in main loop
2. **resumeRuns()** — independent method, unaffected by prioritization

### Graph Availability
- `seeds.getGraph()` returns the **entire project dependency graph**
- Can be called anytime, but typically called once per dispatch batch
- No external dependencies (just executes `sd graph` CLI command)

## Existing Tests

### Test Files Affected
1. **src/orchestrator/__tests__/dispatcher.test.ts**
   - Currently tests only `selectModel()` method (lines 17-64)
   - **No tests** for `dispatch()` method itself
   - **Impact**: New tests needed for PageRank scoring logic

2. **No existing tests** for graph algorithms in dispatcher
   - Refinery has tests for topological sort (refinery.ts uses getGraph)
   - Dispatcher has never used graph data

### Test Coverage Gaps
- No tests verify ready task ordering
- No tests mock or verify `seeds.getGraph()` usage
- No tests cover PageRank score calculation

### Testing Opportunities
1. Unit test: `calculateImpactScore()` function with mock graphs
2. Integration test: Full dispatch with graph, verify ordering
3. Edge cases: Circular deps (shouldn't exist in DAG), no deps, single node

## Recommended Approach

### Phase 1: Create PageRank Scoring Module
1. Create new file: **src/orchestrator/pagerank.ts**
   ```typescript
   export interface ImpactScore {
     seedId: string;
     score: number;
   }

   export function calculateImpactScores(
     readySeeds: Seed[],
     graph: SeedGraph
   ): Map<string, number> {
     // Implement scoring logic
   }
   ```

2. **Scoring Logic**:
   - Build reverse dependency map: `parentOf[seedId] = [seedIds that depend on it]`
   - For each ready seed:
     - Count direct dependents (outgoing edges from perspective of blockers)
     - Count indirect dependents (transitive closure)
     - Apply priority boost if seed has P0-P3 priority
   - Return Map<seedId, score>

3. **Helper Functions**:
   - `getDirectDependents(seedId, graph): string[]` — seeds that directly depend on this
   - `getTransitiveDependents(seedId, graph): string[]` — all downstream seeds
   - `priorityBoost(priority: string): number` — convert P0-P4 to multiplier

### Phase 2: Integrate PageRank into Dispatcher
1. Modify **src/orchestrator/dispatcher.ts** `dispatch()` method:
   ```typescript
   // Line 59: After seeds.ready()
   let readySeeds = await this.seeds.ready();

   // NEW: Get graph and calculate scores
   let impactScores: Map<string, number> = new Map();
   try {
     const graph = await this.seeds.getGraph();
     impactScores = calculateImpactScores(readySeeds, graph);
   } catch (err) {
     // Graceful fallback: no graph = no scoring, use original order
     console.warn(`Could not fetch graph for PageRank: ${err}`);
   }

   // NEW: Sort readySeeds by impact score (descending)
   readySeeds.sort((a, b) => {
     const scoreA = impactScores.get(a.id) ?? 0;
     const scoreB = impactScores.get(b.id) ?? 0;
     if (scoreA !== scoreB) return scoreB - scoreA;  // Higher score first
     // Tie-breaker: by priority
     const priorityOrder = { P0: 0, P1: 1, P2: 2, P3: 3, P4: 4 };
     return (priorityOrder[a.priority as keyof typeof priorityOrder] ?? 5) -
            (priorityOrder[b.priority as keyof typeof priorityOrder] ?? 5);
   });
   ```

2. **Error Handling**:
   - If `seeds.getGraph()` fails (e.g., seeds not initialized), gracefully fall back to original order
   - Log warning but don't crash — dispatcher should still work without graph
   - This matches refinery's pattern (line 70-77 in refinery.ts tries/catches getGraph)

### Phase 3: Test the Implementation
1. **Unit tests** in `src/orchestrator/__tests__/pagerank.test.ts`:
   ```typescript
   describe("calculateImpactScores", () => {
     it("scores seeds by direct dependent count", () => {
       // Mock graph: A ← B ← C (C depends on B, B depends on A)
       // A should score highest (B and C depend on it)
     });

     it("includes indirect dependents in score", () => {
       // Mock graph: A ← B ← C
       // Verify score(A) includes both B (direct) and C (indirect)
     });

     it("applies priority boost", () => {
       // Two seeds with same dependent count
       // P0 seed should score higher than P4 seed
     });

     it("handles seeds with no dependents", () => {
       // Score should be 0 + priority boost
     });

     it("filters only blocking edges", () => {
       // Mix of "blocks" and "parent" edge types
       // Should count only "blocks" edges
     });
   });
   ```

2. **Integration test** in `src/orchestrator/__tests__/dispatcher.test.ts`:
   ```typescript
   describe("Dispatcher.dispatch with PageRank", () => {
     it("dispatches higher-impact seeds first", async () => {
       // Mock seeds.ready() to return 3 seeds
       // Mock seeds.getGraph() to define impact scores
       // Verify dispatch order matches PageRank sorting
     });

     it("falls back to original order if graph unavailable", async () => {
       // Mock seeds.getGraph() to throw error
       // Verify dispatch still works (uses ready order)
       // Verify warning logged
     });
   });
   ```

### Phase 4: Edge Cases & Refinements

1. **Circular Dependencies** (shouldn't exist in valid Foreman usage):
   - PageRank assumes DAG (directed acyclic graph)
   - If graph has cycles: transitive closure might infinite loop
   - **Solution**: Detect cycles first, warn, fall back to original order
   - Can use Tarjan's algorithm for strongly connected component detection

2. **Empty Graph** (first run, no seed structure yet):
   - `seeds.getGraph()` might return `{ nodes: [], edges: [] }`
   - Impact scores will be empty
   - Fallback: use `seed.priority` field directly
   - **Solution**: If impactScores empty after graph, just sort by existing priority

3. **Tie-breaking Stability**:
   - After impact score sort, use stable sort for tie-breakers
   - Maintain insertion order for seeds with identical score + priority
   - JavaScript's `.sort()` is stable in modern JS — safe to use

4. **Graph Stale State**:
   - If tasks are added/removed between `ready()` and `getGraph()`, scores might be off
   - This is a race condition (unlikely but possible in concurrent scenarios)
   - **Solution**: Accept minor staleness — graph should be stable for typical dispatch cycle

## Potential Pitfalls & Edge Cases

1. **Performance at Scale**
   - Graph operations (transitive closure) are O(V + E) with DFS/BFS
   - For 1000 nodes: negligible overhead
   - For 10,000+ nodes: may need caching or incremental calculation
   - **Mitigation**: Start simple, add caching if needed based on profiling

2. **Dependency Graph Accuracy**
   - If seed dependency links are incomplete/incorrect, scores will be wrong
   - Example: If developer forgets to declare deps, some tasks won't be prioritized
   - **Mitigation**: Document importance of accurate dependency declarations
   - **No code fix needed** — this is a process/user issue

3. **Mixed Edge Types**
   - Graph contains both `"blocks"` and `"parent"` edges
   - `"parent"` is organizational only (sprint→story container), doesn't affect `sd ready`
   - **Risk**: Counting parent edges inflates scores incorrectly
   - **Solution**: Filter edges by type, only count `"blocks"` in impact calculation

4. **Priority vs. Impact Trade-off**
   - P0 seed with no dependents vs. P4 seed with many dependents
   - Current formula: `directDependents + 0.5 * indirectDependents + priorityBoost`
   - May need tuning — priorityBoost too strong / weak?
   - **Solution**: Make boost configurable, monitor in production, adjust if needed

5. **Seed Lifecycle Changes**
   - If a seed is closed between `ready()` and `getGraph()`, it might still appear in graph
   - This could cause `impactScores.get(seed.id)` to return undefined
   - **Solution**: Use default value `?? 0` when looking up scores (already in Phase 2 code)

6. **No Graph Available Initially**
   - When project first initialized, `.seeds/issues.jsonl` might be empty
   - `seeds.getGraph()` might fail or return empty graph
   - **Solution**: Graceful fallback to original order (catch in try/catch block)

## Next Steps for Developer

1. **Create pagerank.ts** with core scoring functions
   - Implement impact score calculation
   - Add helper functions for dependent counting
   - Include comprehensive JSDoc comments

2. **Add unit tests** for scoring logic before integrating
   - Test various graph topologies
   - Test edge filtering and priority boosting
   - Test edge cases (empty graph, circular deps, etc.)

3. **Integrate into dispatcher.ts**
   - Call `calculateImpactScores()` after `seeds.ready()`
   - Sort ready seeds by score
   - Add error handling and logging

4. **Add integration tests** for full dispatch flow

5. **Monitor in production**
   - Observe if PageRank improves parallelization
   - Check if task completion time decreases
   - Adjust priority boost weights if needed

6. **Document in README**
   - Explain PageRank scoring to users
   - Recommend dependency declaration best practices
   - Show how priority field interacts with PageRank
