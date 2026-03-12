import type { SeedsClient, Seed } from "../lib/seeds.js";
import type { DecompositionPlan } from "./types.js";

export interface ExecutionResult {
  epicSeedId: string;
  sprintSeedIds: string[];
  storySeedIds: string[];
  taskSeedIds: string[];
}

/**
 * Map word priorities to seeds P0-P4 format.
 * Seeds CLI expects: P0 (highest) through P4 (lowest).
 */
function toSeedsPriority(priority: string): string {
  switch (priority.toLowerCase()) {
    case "critical": return "P0";
    case "high": return "P1";
    case "medium": return "P2";
    case "low": return "P3";
    default: return "P2";
  }
}

/**
 * Map our hierarchy/issue types to valid sd types.
 *
 * sd supports: bug | feature | task | epic | chore | decision
 * Our types:   epic | sprint | story | task | spike | test
 *
 * We map unsupported types to the closest sd type and preserve
 * the semantic type via a label (e.g., "kind:sprint").
 */
function toSeedsType(type: string): string {
  switch (type) {
    case "epic": return "epic";
    case "sprint": return "feature";  // sprint is a container; feature allows deps on stories/tasks
    case "story": return "feature";   // story maps to feature
    case "task": return "task";
    case "spike": return "chore";     // spike is research/investigation
    case "test": return "task";       // test tasks are still tasks
    default: return "task";
  }
}

/**
 * Execute a decomposition plan by creating the full seed hierarchy:
 * epic → sprint → story → task/spike/test
 *
 * Since sd only supports a limited set of types (bug|feature|task|epic|chore|decision),
 * we map our hierarchy types to valid sd types and use labels to preserve semantics:
 *   sprint → epic + label "kind:sprint"
 *   story  → feature + label "kind:story"
 *   spike  → chore + label "kind:spike"
 *   test   → task + label "kind:test"
 */
export async function executePlan(
  plan: DecompositionPlan,
  seeds: SeedsClient,
): Promise<ExecutionResult> {
  // 1. Create the epic seed
  const epicSeed: Seed = await seeds.create(plan.epic.title, {
    type: "epic",
    priority: "P1",
    description: plan.epic.description,
  });

  const sprintSeedIds: string[] = [];
  const storySeedIds: string[] = [];
  const taskSeedIds: string[] = [];

  // Map task title → seed ID for cross-story dependency resolution
  const titleToId = new Map<string, string>();

  // 2. Create sprint → story → task hierarchy
  for (const sprint of plan.sprints) {
    const sprintSeed: Seed = await seeds.create(sprint.title, {
      type: toSeedsType("sprint"),
      priority: "P1",
      parent: epicSeed.id,
      description: sprint.goal,
      labels: ["kind:sprint"],
    });
    sprintSeedIds.push(sprintSeed.id);

    for (const story of sprint.stories) {
      const storySeed: Seed = await seeds.create(story.title, {
        type: toSeedsType("story"),
        priority: toSeedsPriority(story.priority),
        parent: sprintSeed.id,
        description: story.description,
        labels: ["kind:story"],
      });
      storySeedIds.push(storySeed.id);

      for (const task of story.tasks) {
        const labels = [`complexity:${task.estimatedComplexity}`];
        if (task.type !== "task") {
          labels.push(`kind:${task.type}`);
        }

        const taskSeed: Seed = await seeds.create(task.title, {
          type: toSeedsType(task.type),
          priority: toSeedsPriority(task.priority),
          parent: storySeed.id,
          description: task.description,
          labels,
        });
        titleToId.set(task.title, taskSeed.id);
        taskSeedIds.push(taskSeed.id);
      }
    }
  }

  // 3. Wire up cross-task dependencies
  const depErrors: string[] = [];

  async function safeDep(childId: string, parentId: string, context: string): Promise<void> {
    try {
      await seeds.addDependency(childId, parentId);
    } catch (err: any) {
      depErrors.push(`${context}: ${childId} → ${parentId}: ${err.message}`);
    }
  }

  const depPromises: Promise<void>[] = [];
  for (const sprint of plan.sprints) {
    for (const story of sprint.stories) {
      for (const task of story.tasks) {
        const taskId = titleToId.get(task.title);
        if (!taskId) continue;

        for (const depTitle of task.dependencies) {
          const depId = titleToId.get(depTitle);
          if (depId) {
            depPromises.push(safeDep(taskId, depId, `task "${task.title}" depends on "${depTitle}"`));
          }
        }
      }
    }
  }
  await Promise.all(depPromises);

  // Note: We do NOT add explicit container dependencies (story→task, sprint→story).
  // sd automatically creates implicit parent-child dependencies where children
  // depend on their parent. Adding explicit reverse deps would create circular
  // dependencies and deadlock everything. The parent-child relationship already
  // ensures sd auto-closes containers when all children close.

  if (depErrors.length > 0) {
    const summary = depErrors.map((e) => `  - ${e}`).join("\n");
    throw new Error(`${depErrors.length} dependency error(s):\n${summary}`);
  }

  return { epicSeedId: epicSeed.id, sprintSeedIds, storySeedIds, taskSeedIds };
}
