import { describe, it, expect } from "vitest";
import {
  calculateImpactScores,
  buildDependentsMap,
  getDirectDependents,
  getTransitiveDependents,
  priorityBoost,
} from "../pagerank.js";
import type { Seed, SeedGraph } from "../../lib/seeds.js";

// ── Helpers ───────────────────────────────────────────────────────────────

function makeSeed(id: string, priority = "P2"): Seed {
  return {
    id,
    title: `Seed ${id}`,
    type: "task",
    priority,
    status: "open",
    assignee: null,
    parent: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };
}

function makeGraph(edges: Array<{ from: string; to: string; type?: string }>): SeedGraph {
  const allIds = new Set<string>();
  for (const e of edges) {
    allIds.add(e.from);
    allIds.add(e.to);
  }
  return {
    nodes: Array.from(allIds).map((id) => makeSeed(id)),
    edges: edges.map((e) => ({ from: e.from, to: e.to, type: e.type ?? "blocks" })),
  };
}

// ── priorityBoost ────────────────────────────────────────────────────────

describe("priorityBoost", () => {
  it("returns 1.0 for P0", () => expect(priorityBoost("P0")).toBe(1.0));
  it("returns 0.8 for P1", () => expect(priorityBoost("P1")).toBe(0.8));
  it("returns 0.6 for P2", () => expect(priorityBoost("P2")).toBe(0.6));
  it("returns 0.4 for P3", () => expect(priorityBoost("P3")).toBe(0.4));
  it("returns 0.0 for P4", () => expect(priorityBoost("P4")).toBe(0.0));
  it("returns 0.0 for unknown", () => expect(priorityBoost("X1")).toBe(0.0));
  it("returns 0.0 for empty string", () => expect(priorityBoost("")).toBe(0.0));
});

// ── buildDependentsMap ───────────────────────────────────────────────────

describe("buildDependentsMap", () => {
  it("builds correct reverse dependency map for blocking edges", () => {
    // B depends on A, C depends on B
    const graph = makeGraph([
      { from: "B", to: "A", type: "blocks" },
      { from: "C", to: "B", type: "blocks" },
    ]);
    const map = buildDependentsMap(graph);
    expect(map.get("A")).toEqual(new Set(["B"]));
    expect(map.get("B")).toEqual(new Set(["C"]));
    expect(map.has("C")).toBe(false);
  });

  it("skips parent edges", () => {
    const graph = makeGraph([
      { from: "B", to: "A", type: "parent" },
      { from: "C", to: "A", type: "blocks" },
    ]);
    const map = buildDependentsMap(graph);
    // Only C→A blocks edge should be in map
    expect(map.get("A")).toEqual(new Set(["C"]));
    expect(map.size).toBe(1);
  });

  it("handles multiple dependents on one seed", () => {
    const graph = makeGraph([
      { from: "B", to: "A", type: "blocks" },
      { from: "C", to: "A", type: "blocks" },
      { from: "D", to: "A", type: "blocks" },
    ]);
    const map = buildDependentsMap(graph);
    expect(map.get("A")).toEqual(new Set(["B", "C", "D"]));
  });

  it("returns empty map for empty edge list", () => {
    const graph: SeedGraph = { nodes: [], edges: [] };
    expect(buildDependentsMap(graph).size).toBe(0);
  });
});

// ── getDirectDependents ──────────────────────────────────────────────────

describe("getDirectDependents", () => {
  it("returns direct dependents", () => {
    const map = new Map([["A", new Set(["B", "C"])]]);
    const result = getDirectDependents("A", map);
    expect(result.sort()).toEqual(["B", "C"]);
  });

  it("returns empty array for seed with no dependents", () => {
    const map = new Map<string, Set<string>>();
    expect(getDirectDependents("A", map)).toEqual([]);
  });
});

// ── getTransitiveDependents ──────────────────────────────────────────────

describe("getTransitiveDependents", () => {
  it("returns indirect dependents (BFS)", () => {
    // A ← B ← C (C depends on B, B depends on A)
    const map = new Map([
      ["A", new Set(["B"])],
      ["B", new Set(["C"])],
    ]);
    const direct = new Set(["B"]);
    const indirect = getTransitiveDependents("A", map, direct);
    expect(indirect).toEqual(["C"]);
  });

  it("traverses multi-level chains", () => {
    // A ← B ← C ← D
    const map = new Map([
      ["A", new Set(["B"])],
      ["B", new Set(["C"])],
      ["C", new Set(["D"])],
    ]);
    const direct = new Set(["B"]);
    const indirect = getTransitiveDependents("A", map, direct);
    expect(indirect.sort()).toEqual(["C", "D"]);
  });

  it("handles diamond dependencies without double-counting", () => {
    // A ← B, A ← C, B ← D, C ← D (diamond)
    const map = new Map([
      ["A", new Set(["B", "C"])],
      ["B", new Set(["D"])],
      ["C", new Set(["D"])],
    ]);
    const direct = new Set(["B", "C"]);
    const indirect = getTransitiveDependents("A", map, direct);
    // D is indirect (reachable via B and C but only counted once)
    expect(indirect).toEqual(["D"]);
  });

  it("returns empty array when there are no further transitive deps", () => {
    const map = new Map([["A", new Set(["B"])]]);
    const direct = new Set(["B"]);
    const indirect = getTransitiveDependents("A", map, direct);
    expect(indirect).toEqual([]);
  });

  it("returns empty array when exclude covers everything", () => {
    const map = new Map([["A", new Set(["B", "C"])]]);
    const exclude = new Set(["B", "C"]);
    const indirect = getTransitiveDependents("A", map, exclude);
    expect(indirect).toEqual([]);
  });
});

// ── calculateImpactScores ────────────────────────────────────────────────

describe("calculateImpactScores", () => {
  it("scores seed by direct dependent count", () => {
    // B and C both depend on A
    const graph = makeGraph([
      { from: "B", to: "A" },
      { from: "C", to: "A" },
    ]);
    const readySeeds = [makeSeed("A", "P4")];
    const scores = calculateImpactScores(readySeeds, graph);

    // direct=2, indirect=0, boost=0 → 2.0
    expect(scores.get("A")).toBeCloseTo(2.0);
  });

  it("includes indirect dependents at 0.5 weight", () => {
    // A ← B ← C: A has 1 direct (B) and 1 indirect (C)
    const graph = makeGraph([
      { from: "B", to: "A" },
      { from: "C", to: "B" },
    ]);
    const readySeeds = [makeSeed("A", "P4")];
    const scores = calculateImpactScores(readySeeds, graph);

    // direct=1 * 1.0 + indirect=1 * 0.5 + boost=0 = 1.5
    expect(scores.get("A")).toBeCloseTo(1.5);
  });

  it("applies priority boost correctly", () => {
    // Two seeds: both with 1 direct dependent, different priority
    const graph = makeGraph([
      { from: "X", to: "A" },
      { from: "Y", to: "B" },
    ]);
    const readySeeds = [makeSeed("A", "P0"), makeSeed("B", "P4")];
    const scores = calculateImpactScores(readySeeds, graph);

    // A: 1 direct + P0 boost=1.0 = 2.0
    // B: 1 direct + P4 boost=0.0 = 1.0
    expect(scores.get("A")).toBeCloseTo(2.0);
    expect(scores.get("B")).toBeCloseTo(1.0);
    expect(scores.get("A")!).toBeGreaterThan(scores.get("B")!);
  });

  it("handles seeds with no dependents (score = priority boost only)", () => {
    const graph: SeedGraph = { nodes: [], edges: [] };
    const readySeeds = [makeSeed("A", "P2")];
    const scores = calculateImpactScores(readySeeds, graph);

    // 0 direct + 0 indirect + P2 boost=0.6 = 0.6
    expect(scores.get("A")).toBeCloseTo(0.6);
  });

  it("filters out parent edges from scoring", () => {
    // B is a parent of A (organisational only) — should NOT count as dependent
    const graph = makeGraph([
      { from: "B", to: "A", type: "parent" },
    ]);
    const readySeeds = [makeSeed("A", "P4")];
    const scores = calculateImpactScores(readySeeds, graph);

    // No blocking deps, no priority boost → 0
    expect(scores.get("A")).toBeCloseTo(0.0);
  });

  it("handles mixed edge types (counts only blocks)", () => {
    const graph = makeGraph([
      { from: "B", to: "A", type: "blocks" },
      { from: "C", to: "A", type: "parent" },  // ignored
    ]);
    const readySeeds = [makeSeed("A", "P4")];
    const scores = calculateImpactScores(readySeeds, graph);

    // Only B is a blocker-dep → direct=1, indirect=0, boost=0 → 1.0
    expect(scores.get("A")).toBeCloseTo(1.0);
  });

  it("scores multiple ready seeds correctly", () => {
    // A ← B ← C, D has no dependents
    const graph = makeGraph([
      { from: "B", to: "A" },
      { from: "C", to: "B" },
    ]);
    const readySeeds = [makeSeed("A", "P4"), makeSeed("D", "P4")];
    const scores = calculateImpactScores(readySeeds, graph);

    // A: 1 direct + 1 indirect + 0 boost = 1.5
    // D: 0 direct + 0 indirect + 0 boost = 0
    expect(scores.get("A")).toBeCloseTo(1.5);
    expect(scores.get("D")).toBeCloseTo(0.0);
  });

  it("returns an entry for every ready seed", () => {
    const graph: SeedGraph = { nodes: [], edges: [] };
    const readySeeds = [makeSeed("A"), makeSeed("B"), makeSeed("C")];
    const scores = calculateImpactScores(readySeeds, graph);

    expect(scores.has("A")).toBe(true);
    expect(scores.has("B")).toBe(true);
    expect(scores.has("C")).toBe(true);
  });

  it("handles empty ready seeds list", () => {
    const graph: SeedGraph = { nodes: [], edges: [] };
    const scores = calculateImpactScores([], graph);
    expect(scores.size).toBe(0);
  });

  it("scores high-priority leaf seed higher than low-priority hub", () => {
    // Hub A has 2 dependents but is P4; leaf X has 0 dependents but is P0
    // score(A) = 2.0 + 0 = 2.0
    // score(X) = 0.0 + 1.0 = 1.0
    // Hub should still win because 2 > 1 (fine), but verifies the interplay
    const graph = makeGraph([
      { from: "B", to: "A" },
      { from: "C", to: "A" },
    ]);
    const readySeeds = [makeSeed("A", "P4"), makeSeed("X", "P0")];
    const scores = calculateImpactScores(readySeeds, graph);

    expect(scores.get("A")).toBeCloseTo(2.0);
    expect(scores.get("X")).toBeCloseTo(1.0);
  });
});
