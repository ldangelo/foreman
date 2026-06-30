// ── Sling Executor ────────────────────────────────────────────────────────
//
// Native-write execution engine: creates task hierarchies in the Foreman
// Postgres task store from a parsed SlingPlan.
// ── Type/priority mapping ────────────────────────────────────────────────
export function toTrackerPriority(priority) {
    switch (priority) {
        case "critical": return "P0";
        case "high": return "P1";
        case "medium": return "P2";
        case "low": return "P3";
        default: return "P2";
    }
}
function toNativePriority(priority) {
    switch (priority) {
        case "critical": return 0;
        case "high": return 1;
        case "medium": return 2;
        case "low": return 3;
        default: return 2;
    }
}
export function toTrackerType(kind) {
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
function inferTaskKind(title) {
    const lower = title.toLowerCase();
    if (/\bwrite\s+(unit\s+)?tests?\b/.test(lower) || /\btest\b.*\bfor\b/.test(lower))
        return "test";
    if (/\bspike\b/.test(lower) || /\binvestigat/i.test(lower))
        return "spike";
    return "task";
}
const MAX_TITLE_LENGTH = 490;
/**
 * Truncate a title to fit tracker limits. If truncated, the full text
 * should be preserved in the description.
 */
function truncateTitle(title) {
    if (title.length <= MAX_TITLE_LENGTH)
        return { title, truncated: false };
    return {
        title: title.slice(0, MAX_TITLE_LENGTH - 3) + "...",
        truncated: true,
    };
}
function appendMetadata(description, metadata) {
    if (metadata.length === 0)
        return description;
    return `${description}\n\nMetadata: ${metadata.join(", ")}`;
}
function buildEpicDescription(plan, options) {
    let description = plan.epic.description;
    if (plan.epic.qualityNotes && !options.noQuality) {
        description += `\n\n## Quality Requirements\n${plan.epic.qualityNotes}`;
    }
    return description;
}
function buildSprintDescription(sprint) {
    let description = sprint.goal;
    if (sprint.summary) {
        description += `\n\nFocus: ${sprint.summary.focus}\n` +
            `Estimated Hours: ${sprint.summary.estimatedHours}\n` +
            `Deliverables: ${sprint.summary.deliverables}`;
    }
    return description;
}
function buildStoryDescription(story) {
    if (!story.acceptanceCriteria)
        return null;
    return `## Acceptance Criteria\n${story.acceptanceCriteria}`;
}
function buildTaskDescription(task, metadata) {
    let description = task.title;
    if (task.files.length > 0) {
        description += `\n\nFiles: ${task.files.map((file) => `\`${file}\``).join(", ")}`;
    }
    return appendMetadata(description, metadata);
}
function epicExternalId(documentId) {
    return `trd:${documentId}`;
}
function sprintExternalId(documentId, sprintNumber) {
    return `trd:${documentId}:sprint:${sprintNumber}`;
}
function storyExternalId(documentId, sprintNumber, storyIndex) {
    return `trd:${documentId}:story:${sprintNumber}.${storyIndex + 1}`;
}
async function upsertTask(taskStore, result, externalId, createOpts, force) {
    const existing = await Promise.resolve(taskStore.getByExternalId(externalId));
    if (existing && !force) {
        result.skipped++;
        return existing;
    }
    if (existing && force) {
        const updated = await Promise.resolve(taskStore.update(existing.id, {
            title: createOpts.title,
            description: createOpts.description ?? null,
            priority: createOpts.priority,
            force: true,
        }));
        result.created++;
        return updated;
    }
    const created = await Promise.resolve(taskStore.create({
        ...createOpts,
        externalId,
    }));
    result.created++;
    return created;
}
async function safeAddDependency(taskStore, result, fromId, toId, type, label) {
    try {
        await Promise.resolve(taskStore.addDependency(fromId, toId, type));
    }
    catch (err) {
        result.errors.push(`SLING-007: Failed to wire ${label} ${fromId} -> ${toId}: ${err.message}`);
    }
}
async function wireTaskDependencies(taskStore, plan, trdIdToTaskId, options, result) {
    const depErrors = [];
    for (const sprint of plan.sprints) {
        for (const story of sprint.stories) {
            for (const task of story.tasks) {
                if (options.skipCompleted && task.status === "completed")
                    continue;
                for (const depTrdId of task.dependencies) {
                    const depTaskId = trdIdToTaskId.get(depTrdId);
                    const taskId = trdIdToTaskId.get(task.trdId);
                    if (!taskId)
                        continue;
                    if (!depTaskId) {
                        if (options.skipCompleted)
                            continue;
                        depErrors.push(`SLING-007: Dependency target ${depTrdId} not found for ${task.trdId}`);
                        continue;
                    }
                    try {
                        await Promise.resolve(taskStore.addDependency(taskId, depTaskId, "blocks"));
                    }
                    catch (err) {
                        depErrors.push(`SLING-007: Failed to wire dep ${task.trdId} -> ${depTrdId}: ${err.message}`);
                    }
                }
            }
        }
    }
    return depErrors;
}
async function wireContainerDependencies(taskStore, plan, trdIdToSprintId, trdIdToStoryId) {
    const depErrors = [];
    const sprintDeps = new Set();
    const storyDeps = new Set();
    for (const sprint of plan.sprints) {
        for (const story of sprint.stories) {
            for (const task of story.tasks) {
                const taskSprintId = trdIdToSprintId.get(task.trdId);
                const taskStoryId = trdIdToStoryId.get(task.trdId);
                if (!taskSprintId || !taskStoryId)
                    continue;
                for (const depTrdId of task.dependencies) {
                    const depSprintId = trdIdToSprintId.get(depTrdId);
                    const depStoryId = trdIdToStoryId.get(depTrdId);
                    if (!depSprintId || !depStoryId)
                        continue;
                    if (taskSprintId !== depSprintId)
                        sprintDeps.add(`${taskSprintId}|${depSprintId}`);
                    if (taskStoryId !== depStoryId)
                        storyDeps.add(`${taskStoryId}|${depStoryId}`);
                }
            }
        }
    }
    for (const pair of sprintDeps) {
        const [sprintId, depSprintId] = pair.split("|");
        try {
            await Promise.resolve(taskStore.addDependency(sprintId, depSprintId, "blocks"));
        }
        catch (err) {
            depErrors.push(`SLING-007: Failed to wire sprint dep ${sprintId} -> ${depSprintId}: ${err.message}`);
        }
    }
    for (const pair of storyDeps) {
        const [storyId, depStoryId] = pair.split("|");
        try {
            await Promise.resolve(taskStore.addDependency(storyId, depStoryId, "blocks"));
        }
        catch (err) {
            depErrors.push(`SLING-007: Failed to wire story dep ${storyId} -> ${depStoryId}: ${err.message}`);
        }
    }
    return depErrors;
}
async function executeForNative(taskStore, ctx) {
    const { plan, parallel, options } = ctx;
    const result = { created: 0, skipped: 0, failed: 0, epicId: null, errors: [] };
    const trdIdToTaskId = new Map();
    const trdIdToSprintId = new Map();
    const trdIdToStoryId = new Map();
    const totalTasks = plan.sprints.reduce((sum, sprint) => sum + sprint.stories.reduce((storySum, story) => storySum + story.tasks.length, 0), 0);
    const totalItems = 1 + plan.sprints.length +
        plan.sprints.reduce((sum, sprint) => sum + sprint.stories.length, 0) + totalTasks;
    let processed = 0;
    try {
        const epic = await upsertTask(taskStore, result, epicExternalId(plan.epic.documentId), {
            title: plan.epic.title,
            description: buildEpicDescription(plan, options),
            type: "epic",
            priority: 0,
        }, options.force);
        result.epicId = epic.id;
        processed++;
        ctx.onProgress?.(processed, totalItems, "native");
        for (let sprintIndex = 0; sprintIndex < plan.sprints.length; sprintIndex++) {
            const sprint = plan.sprints[sprintIndex];
            const sprintMetadata = ["kind:sprint", `source:${epicExternalId(plan.epic.documentId)}`];
            if (!options.noParallel) {
                for (const group of parallel.groups) {
                    if (group.sprintIndices.includes(sprintIndex)) {
                        sprintMetadata.push(`parallel:${group.label}`);
                    }
                }
            }
            const sprintTask = await upsertTask(taskStore, result, sprintExternalId(plan.epic.documentId, sprint.number), {
                title: sprint.title,
                description: appendMetadata(buildSprintDescription(sprint), sprintMetadata),
                type: toTrackerType("sprint"),
                priority: toNativePriority(sprint.priority),
            }, options.force);
            processed++;
            ctx.onProgress?.(processed, totalItems, "native");
            await safeAddDependency(taskStore, result, sprintTask.id, epic.id, "parent-child", "parent-child");
            for (let storyIndex = 0; storyIndex < sprint.stories.length; storyIndex++) {
                const story = sprint.stories[storyIndex];
                const storyTask = await upsertTask(taskStore, result, storyExternalId(plan.epic.documentId, sprint.number, storyIndex), {
                    title: story.title,
                    description: appendMetadata(buildStoryDescription(story) ?? story.title, ["kind:story"]),
                    type: toTrackerType("story"),
                    priority: toNativePriority(sprint.priority),
                }, options.force);
                processed++;
                ctx.onProgress?.(processed, totalItems, "native");
                await safeAddDependency(taskStore, result, storyTask.id, sprintTask.id, "parent-child", "parent-child");
                for (const task of story.tasks) {
                    if (options.skipCompleted && task.status === "completed") {
                        result.skipped++;
                        processed++;
                        ctx.onProgress?.(processed, totalItems, "native");
                        continue;
                    }
                    try {
                        const kind = inferTaskKind(task.title);
                        const metadata = [`trd:${task.trdId}`];
                        if (kind !== "task")
                            metadata.push(`kind:${kind}`);
                        if (task.estimateHours > 0)
                            metadata.push(`estimate:${task.estimateHours}h`);
                        if (task.riskLevel && !options.noRisks)
                            metadata.push(`risk:${task.riskLevel}`);
                        const { title: taskTitle, truncated } = truncateTitle(task.title);
                        const nativeTask = await upsertTask(taskStore, result, `trd:${task.trdId}`, {
                            title: taskTitle,
                            description: buildTaskDescription(task, truncated ? [`full-title:${JSON.stringify(task.title)}`, ...metadata] : metadata),
                            type: toTrackerType(kind),
                            priority: toNativePriority(sprint.priority),
                        }, options.force);
                        trdIdToTaskId.set(task.trdId, nativeTask.id);
                        trdIdToSprintId.set(task.trdId, sprintTask.id);
                        trdIdToStoryId.set(task.trdId, storyTask.id);
                        await safeAddDependency(taskStore, result, nativeTask.id, storyTask.id, "parent-child", "parent-child");
                        if (options.closeCompleted && task.status === "completed") {
                            await Promise.resolve(taskStore.close(nativeTask.id, "Completed in TRD"));
                        }
                    }
                    catch (err) {
                        result.failed++;
                        result.errors.push(`SLING-006: Failed to create native task ${task.trdId}: ${err.message}`);
                    }
                    processed++;
                    ctx.onProgress?.(processed, totalItems, "native");
                }
            }
        }
        const depErrors = await wireTaskDependencies(taskStore, plan, trdIdToTaskId, options, result);
        result.errors.push(...depErrors);
        const containerDepErrors = await wireContainerDependencies(taskStore, plan, trdIdToSprintId, trdIdToStoryId);
        result.errors.push(...containerDepErrors);
    }
    catch (err) {
        result.errors.push(`SLING-006: Unexpected native task error: ${err.message}`);
    }
    return result;
}
// ── Public API ───────────────────────────────────────────────────────────
export async function execute(plan, parallel, options, taskStore, onProgress) {
    const native = await executeForNative(taskStore, { plan, parallel, options, onProgress });
    return {
        native,
        depErrors: native.errors.filter((error) => error.includes("SLING-007")),
    };
}
//# sourceMappingURL=sling-executor.js.map