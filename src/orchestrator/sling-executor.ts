// ── Sling Executor ────────────────────────────────────────────────────────
//
// Dual-write execution engine: creates task hierarchies in both
// seeds (sd) and beads_rust (br) from a parsed SlingPlan.

import type { SeedsClient, Seed } from "../lib/seeds.js";
import type { BeadsRustClient, BrIssue } from "../lib/beads-rust.js";
import type {
  SlingPlan,
  SlingOptions,
  SlingResult,
  TrackerResult,
  ParallelResult,
  TrdTask,
  TrdStory,
  TrdSprint,
  Priority,
} from "./types.js";

// ── Type/priority mapping ────────────────────────────────────────────────

export function toTrackerPriority(priority: Priority): string {
  switch (priority) {
    case "critical": return "P0";
    case "high": return "P1";
    case "medium": return "P2";
    case "low": return "P3";
    default: return "P2";
  }
}

export function toTrackerType(kind: string): string {
  switch (kind) {
    case "epic": return "epic";
    case "sprint": return "feature";
    case "story": return "feature";
    case "task": return "task";
    case "spike": return "chore";
    case "test": return "task";
    default: return "task";
  }
}

function inferTaskKind(title: string): string {
  const lower = title.toLowerCase();
  if (/\bwrite\s+(unit\s+)?tests?\b/.test(lower) || /\btest\b.*\bfor\b/.test(lower)) return "test";
  if (/\bspike\b/.test(lower) || /\binvestigat/i.test(lower)) return "spike";
  return "task";
}

// ── Progress callback ────────────────────────────────────────────────────

export type ProgressCallback = (
  created: number,
  total: number,
  tracker: "sd" | "br",
) => void;

// ── Existing epic detection ──────────────────────────────────────────────

export async function detectExistingEpic(
  documentId: string,
  seeds: SeedsClient | null,
  beadsRust: BeadsRustClient | null,
): Promise<{ sdEpicId: string | null; brEpicId: string | null }> {
  let sdEpicId: string | null = null;
  let brEpicId: string | null = null;

  const label = `trd:${documentId}`;

  if (seeds) {
    try {
      const results = await seeds.list({ type: "epic" });
      // Search for matching label — sd list doesn't have label filter,
      // so we check via show() for each epic
      for (const epic of results) {
        try {
          const detail = await seeds.show(epic.id);
          if (detail.description?.includes(label) ||
              (detail as unknown as { labels?: string[] }).labels?.includes?.(label)) {
            sdEpicId = epic.id;
            break;
          }
        } catch {
          // Skip inaccessible epics
        }
      }
    } catch {
      // sd list failed — no existing epic
    }
  }

  if (beadsRust) {
    try {
      const results = await beadsRust.list({ label });
      if (results.length > 0) {
        brEpicId = results[0].id;
      }
    } catch {
      // br list failed — no existing epic
    }
  }

  return { sdEpicId, brEpicId };
}

// ── Core execution ──────────────────────────────────────────────────────

interface ExecuteContext {
  plan: SlingPlan;
  parallel: ParallelResult;
  options: SlingOptions;
  onProgress?: ProgressCallback;
}

async function executeForSeeds(
  seeds: SeedsClient,
  ctx: ExecuteContext,
  existingEpicId: string | null,
): Promise<TrackerResult> {
  const { plan, parallel, options } = ctx;
  const result: TrackerResult = { created: 0, skipped: 0, failed: 0, epicId: null, errors: [] };
  const trdIdToSdId = new Map<string, string>();

  // Count total items for progress
  const totalTasks = plan.sprints.reduce(
    (sum, s) => sum + s.stories.reduce((ss, st) => ss + st.tasks.length, 0),
    0,
  );
  const totalItems = 1 + plan.sprints.length +
    plan.sprints.reduce((sum, s) => sum + s.stories.length, 0) + totalTasks;

  let created = 0;

  try {
    // Epic
    let epicId: string;
    if (existingEpicId) {
      epicId = existingEpicId;
      result.skipped++;
    } else {
      const labels = [`trd:${plan.epic.documentId}`];
      let description = plan.epic.description;
      if (plan.epic.qualityNotes && !options.noQuality) {
        description += `\n\n## Quality Requirements\n${plan.epic.qualityNotes}`;
      }
      const epicSeed = await seeds.create(plan.epic.title, {
        type: "epic",
        priority: "P0",
        description,
        labels,
      });
      epicId = epicSeed.id;
      result.created++;
      created++;
    }
    result.epicId = epicId;
    ctx.onProgress?.(created, totalItems, "sd");

    // Sprints
    for (let si = 0; si < plan.sprints.length; si++) {
      const sprint = plan.sprints[si];
      const sprintLabels = ["kind:sprint", `trd:${plan.epic.documentId}`];

      // Apply parallel labels
      if (!options.noParallel) {
        for (const group of parallel.groups) {
          if (group.sprintIndices.includes(si)) {
            sprintLabels.push(`parallel:${group.label}`);
          }
        }
      }

      let sprintDescription = sprint.goal;
      if (sprint.summary) {
        sprintDescription += `\n\nFocus: ${sprint.summary.focus}\n` +
          `Estimated Hours: ${sprint.summary.estimatedHours}\n` +
          `Deliverables: ${sprint.summary.deliverables}`;
      }

      const sprintSeed = await seeds.create(sprint.title, {
        type: toTrackerType("sprint"),
        priority: toTrackerPriority(sprint.priority),
        parent: epicId,
        description: sprintDescription,
        labels: sprintLabels,
      });
      result.created++;
      created++;
      ctx.onProgress?.(created, totalItems, "sd");

      // Stories
      for (const story of sprint.stories) {
        const storyLabels = ["kind:story"];
        let storyDescription = "";
        if (story.acceptanceCriteria) {
          storyDescription += `## Acceptance Criteria\n${story.acceptanceCriteria}`;
        }

        const storySeed = await seeds.create(story.title, {
          type: toTrackerType("story"),
          priority: toTrackerPriority(sprint.priority),
          parent: sprintSeed.id,
          description: storyDescription || undefined,
          labels: storyLabels,
        });
        result.created++;
        created++;
        ctx.onProgress?.(created, totalItems, "sd");

        // Tasks
        for (const task of story.tasks) {
          if (options.skipCompleted && task.status === "completed") {
            result.skipped++;
            continue;
          }

          try {
            const kind = inferTaskKind(task.title);
            const taskLabels = [`trd:${task.trdId}`];
            if (kind !== "task") taskLabels.push(`kind:${kind}`);
            if (task.estimateHours > 0) taskLabels.push(`est:${task.estimateHours}h`);
            if (task.riskLevel && !options.noRisks) taskLabels.push(`risk:${task.riskLevel}`);

            let taskDescription = task.title;
            if (task.files.length > 0) {
              taskDescription += `\n\nFiles: ${task.files.map((f) => `\`${f}\``).join(", ")}`;
            }

            const taskSeed = await seeds.create(task.title, {
              type: toTrackerType(kind),
              priority: toTrackerPriority(sprint.priority),
              parent: storySeed.id,
              description: taskDescription,
              labels: taskLabels,
            });
            trdIdToSdId.set(task.trdId, taskSeed.id);
            result.created++;
            created++;

            if (options.closeCompleted && task.status === "completed") {
              await seeds.close(taskSeed.id, "Completed in TRD");
            }
          } catch (err: unknown) {
            result.failed++;
            result.errors.push(
              `SLING-006: Failed to create sd task ${task.trdId}: ${(err as Error).message}`,
            );
          }
          ctx.onProgress?.(created, totalItems, "sd");
        }
      }
    }

    // Wire dependencies
    await wireDependencies(seeds, plan, trdIdToSdId, options, result);
  } catch (err: unknown) {
    result.errors.push(`SLING-006: Unexpected sd error: ${(err as Error).message}`);
  }

  return result;
}

async function executeForBeadsRust(
  beadsRust: BeadsRustClient,
  ctx: ExecuteContext,
  existingEpicId: string | null,
): Promise<TrackerResult> {
  const { plan, parallel, options } = ctx;
  const result: TrackerResult = { created: 0, skipped: 0, failed: 0, epicId: null, errors: [] };
  const trdIdToBrId = new Map<string, string>();

  const totalTasks = plan.sprints.reduce(
    (sum, s) => sum + s.stories.reduce((ss, st) => ss + st.tasks.length, 0),
    0,
  );
  const totalItems = 1 + plan.sprints.length +
    plan.sprints.reduce((sum, s) => sum + s.stories.length, 0) + totalTasks;

  let created = 0;

  try {
    // Epic
    let epicId: string;
    if (existingEpicId) {
      epicId = existingEpicId;
      result.skipped++;
    } else {
      const labels = [`trd:${plan.epic.documentId}`];
      let description = plan.epic.description;
      if (plan.epic.qualityNotes && !options.noQuality) {
        description += `\n\n## Quality Requirements\n${plan.epic.qualityNotes}`;
      }
      const epicIssue = await beadsRust.create(plan.epic.title, {
        type: "epic",
        priority: "P0",
        description,
        labels,
      });
      epicId = epicIssue.id;
      result.created++;
      created++;
    }
    result.epicId = epicId;
    ctx.onProgress?.(created, totalItems, "br");

    // Sprints
    for (let si = 0; si < plan.sprints.length; si++) {
      const sprint = plan.sprints[si];
      const sprintLabels = ["kind:sprint", `trd:${plan.epic.documentId}`];

      if (!options.noParallel) {
        for (const group of parallel.groups) {
          if (group.sprintIndices.includes(si)) {
            sprintLabels.push(`parallel:${group.label}`);
          }
        }
      }

      let sprintDescription = sprint.goal;
      if (sprint.summary) {
        sprintDescription += `\n\nFocus: ${sprint.summary.focus}\n` +
          `Estimated Hours: ${sprint.summary.estimatedHours}\n` +
          `Deliverables: ${sprint.summary.deliverables}`;
      }

      const sprintIssue = await beadsRust.create(sprint.title, {
        type: toTrackerType("sprint"),
        priority: toTrackerPriority(sprint.priority),
        parent: epicId,
        description: sprintDescription,
        labels: sprintLabels,
      });
      result.created++;
      created++;
      ctx.onProgress?.(created, totalItems, "br");

      // Stories
      for (const story of sprint.stories) {
        const storyLabels = ["kind:story"];
        const storyOpts: Parameters<BeadsRustClient["create"]>[1] = {
          type: toTrackerType("story"),
          priority: toTrackerPriority(sprint.priority),
          parent: sprintIssue.id,
          labels: storyLabels,
        };
        if (story.acceptanceCriteria) {
          storyOpts!.description = `## Acceptance Criteria\n${story.acceptanceCriteria}`;
        }

        const storyIssue = await beadsRust.create(story.title, storyOpts);
        result.created++;
        created++;
        ctx.onProgress?.(created, totalItems, "br");

        // Tasks
        for (const task of story.tasks) {
          if (options.skipCompleted && task.status === "completed") {
            result.skipped++;
            continue;
          }

          try {
            const kind = inferTaskKind(task.title);
            const taskLabels = [`trd:${task.trdId}`];
            if (kind !== "task") taskLabels.push(`kind:${kind}`);
            if (task.riskLevel && !options.noRisks) taskLabels.push(`risk:${task.riskLevel}`);

            let taskDescription = task.title;
            if (task.files.length > 0) {
              taskDescription += `\n\nFiles: ${task.files.map((f) => `\`${f}\``).join(", ")}`;
            }

            const taskIssue = await beadsRust.create(task.title, {
              type: toTrackerType(kind),
              priority: toTrackerPriority(sprint.priority),
              parent: storyIssue.id,
              description: taskDescription,
              labels: taskLabels,
              estimate: task.estimateHours > 0 ? task.estimateHours * 60 : undefined,
            });
            trdIdToBrId.set(task.trdId, taskIssue.id);
            result.created++;
            created++;

            if (options.closeCompleted && task.status === "completed") {
              await beadsRust.close(taskIssue.id, "Completed in TRD");
            }
          } catch (err: unknown) {
            result.failed++;
            result.errors.push(
              `SLING-006: Failed to create br task ${task.trdId}: ${(err as Error).message}`,
            );
          }
          ctx.onProgress?.(created, totalItems, "br");
        }
      }
    }

    // Wire dependencies
    await wireDependenciesBr(beadsRust, plan, trdIdToBrId, options, result);
  } catch (err: unknown) {
    result.errors.push(`SLING-006: Unexpected br error: ${(err as Error).message}`);
  }

  return result;
}

// ── Dependency wiring ────────────────────────────────────────────────────

async function wireDependencies(
  client: SeedsClient,
  plan: SlingPlan,
  trdIdToTrackerId: Map<string, string>,
  options: SlingOptions,
  result: TrackerResult,
): Promise<string[]> {
  const depErrors: string[] = [];

  for (const sprint of plan.sprints) {
    for (const story of sprint.stories) {
      for (const task of story.tasks) {
        if (options.skipCompleted && task.status === "completed") continue;

        for (const depTrdId of task.dependencies) {
          const depTrackerId = trdIdToTrackerId.get(depTrdId);
          const taskTrackerId = trdIdToTrackerId.get(task.trdId);

          if (!taskTrackerId) continue; // Task was skipped or failed
          if (!depTrackerId) {
            // Dependency target was skipped — silently drop
            if (options.skipCompleted) continue;
            const msg = `SLING-007: Dependency target ${depTrdId} not found for ${task.trdId}`;
            depErrors.push(msg);
            continue;
          }

          try {
            await client.addDependency(taskTrackerId, depTrackerId);
          } catch (err: unknown) {
            const msg = `SLING-007: Failed to wire dep ${task.trdId} -> ${depTrdId}: ${(err as Error).message}`;
            depErrors.push(msg);
          }
        }
      }
    }
  }

  return depErrors;
}

async function wireDependenciesBr(
  client: BeadsRustClient,
  plan: SlingPlan,
  trdIdToTrackerId: Map<string, string>,
  options: SlingOptions,
  result: TrackerResult,
): Promise<string[]> {
  const depErrors: string[] = [];

  for (const sprint of plan.sprints) {
    for (const story of sprint.stories) {
      for (const task of story.tasks) {
        if (options.skipCompleted && task.status === "completed") continue;

        for (const depTrdId of task.dependencies) {
          const depTrackerId = trdIdToTrackerId.get(depTrdId);
          const taskTrackerId = trdIdToTrackerId.get(task.trdId);

          if (!taskTrackerId) continue;
          if (!depTrackerId) {
            if (options.skipCompleted) continue;
            const msg = `SLING-007: Dependency target ${depTrdId} not found for ${task.trdId}`;
            depErrors.push(msg);
            continue;
          }

          try {
            await client.addDependency(taskTrackerId, depTrackerId);
          } catch (err: unknown) {
            const msg = `SLING-007: Failed to wire dep ${task.trdId} -> ${depTrdId}: ${(err as Error).message}`;
            depErrors.push(msg);
          }
        }
      }
    }
  }

  return depErrors;
}

// ── Public API ───────────────────────────────────────────────────────────

export async function execute(
  plan: SlingPlan,
  parallel: ParallelResult,
  options: SlingOptions,
  seeds: SeedsClient | null,
  beadsRust: BeadsRustClient | null,
  onProgress?: ProgressCallback,
): Promise<SlingResult> {
  const result: SlingResult = { sd: null, br: null, depErrors: [] };
  const ctx: ExecuteContext = { plan, parallel, options, onProgress };

  // Detect existing epics
  const existing = await detectExistingEpic(
    plan.epic.documentId,
    options.force ? null : seeds,
    options.force ? null : beadsRust,
  );

  // Execute for sd first, then br
  if (seeds && !options.brOnly) {
    result.sd = await executeForSeeds(seeds, ctx, existing.sdEpicId);
  }

  if (beadsRust && !options.sdOnly) {
    result.br = await executeForBeadsRust(beadsRust, ctx, existing.brEpicId);
  }

  // Collect dep errors
  if (result.sd) result.depErrors.push(...result.sd.errors.filter((e) => e.includes("SLING-007")));
  if (result.br) result.depErrors.push(...result.br.errors.filter((e) => e.includes("SLING-007")));

  return result;
}
