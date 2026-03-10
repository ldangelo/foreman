import type { BeadsClient, Bead } from "../lib/beads.js";
import type { DecompositionPlan } from "./types.js";

export interface ExecutionResult {
  epicBeadId: string;
  sprintBeadIds: string[];
  storyBeadIds: string[];
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
 * Map our hierarchy/issue types to valid bd types.
 *
 * bd supports: bug | feature | task | epic | chore | decision
 * Our types:   epic | sprint | story | task | spike | test
 *
 * We map unsupported types to the closest bd type and preserve
 * the semantic type via a label (e.g., "kind:sprint").
 */
function toBeadsType(type: string): string {
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
 * Execute a decomposition plan by creating the full bead hierarchy:
 * epic → sprint → story → task/spike/test
 *
 * Since bd only supports a limited set of types (bug|feature|task|epic|chore|decision),
 * we map our hierarchy types to valid bd types and use labels to preserve semantics:
 *   sprint → epic + label "kind:sprint"
 *   story  → feature + label "kind:story"
 *   spike  → chore + label "kind:spike"
 *   test   → task + label "kind:test"
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

  const sprintBeadIds: string[] = [];
  const storyBeadIds: string[] = [];
  const taskBeadIds: string[] = [];

  // Map task title → bead ID for cross-story dependency resolution
  const titleToId = new Map<string, string>();

  // 2. Create sprint → story → task hierarchy
  for (const sprint of plan.sprints) {
    const sprintBead: Bead = await beads.create(sprint.title, {
      type: toBeadsType("sprint"),
      priority: "P1",
      parent: epicBead.id,
      description: sprint.goal,
      labels: ["kind:sprint"],
    });
    sprintBeadIds.push(sprintBead.id);

    for (const story of sprint.stories) {
      const storyBead: Bead = await beads.create(story.title, {
        type: toBeadsType("story"),
        priority: toBeadsPriority(story.priority),
        parent: sprintBead.id,
        description: story.description,
        labels: ["kind:story"],
      });
      storyBeadIds.push(storyBead.id);

      for (const task of story.tasks) {
        const labels = [`complexity:${task.estimatedComplexity}`];
        if (task.type !== "task") {
          labels.push(`kind:${task.type}`);
        }

        const taskBead: Bead = await beads.create(task.title, {
          type: toBeadsType(task.type),
          priority: toBeadsPriority(task.priority),
          parent: storyBead.id,
          description: task.description,
          labels,
        });
        titleToId.set(task.title, taskBead.id);
        taskBeadIds.push(taskBead.id);
      }
    }
  }

  // 3. Wire up cross-task dependencies
  const depErrors: string[] = [];

  async function safeDep(childId: string, parentId: string, context: string): Promise<void> {
    try {
      await beads.addDependency(childId, parentId);
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
  // bd automatically creates implicit parent-child dependencies where children
  // depend on their parent. Adding explicit reverse deps would create circular
  // dependencies and deadlock everything. The parent-child relationship already
  // ensures bd auto-closes containers when all children close.

  if (depErrors.length > 0) {
    const summary = depErrors.map((e) => `  - ${e}`).join("\n");
    throw new Error(`${depErrors.length} dependency error(s):\n${summary}`);
  }

  return { epicBeadId: epicBead.id, sprintBeadIds, storyBeadIds, taskBeadIds };
}
