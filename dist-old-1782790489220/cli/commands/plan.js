import { Command } from "commander";
import chalk from "chalk";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { ElixirServerClient } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { foremanBackendMode } from "../../lib/backend-mode.js";
import { normalizePriority } from "../../lib/priority.js";
import { ForemanStore } from "../../lib/store.js";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import { listRegisteredProjects, resolveRepoRootProjectPath } from "./project-task-support.js";
function taskRowToIssue(row) {
    return {
        id: row.id,
        title: row.title,
        type: row.type,
        priority: `P${row.priority}`,
        status: row.status,
        assignee: null,
        parent: null,
        created_at: row.created_at,
        updated_at: row.updated_at,
        description: row.description ?? null,
        labels: [],
    };
}
function elixirTaskToIssue(task) {
    const id = task.task_id ?? task.id ?? "";
    return {
        id,
        title: task.title ?? id,
        type: task.task_type ?? task.type ?? "task",
        priority: `P${typeof task.priority === "number" ? task.priority : 2}`,
        status: task.status ?? "backlog",
        assignee: null,
        parent: null,
        created_at: task.created_at ?? new Date(0).toISOString(),
        updated_at: task.updated_at ?? task.created_at ?? new Date(0).toISOString(),
        description: task.description ?? null,
        labels: [],
    };
}
class NativePlanTaskClient {
    projectPath;
    constructor(projectPath) {
        this.projectPath = projectPath;
    }
    async withClient(fn) {
        const projects = await listRegisteredProjects();
        const project = projects.find((record) => record.path === this.projectPath);
        if (!project) {
            throw new Error(`Project at '${this.projectPath}' is not registered with the daemon.`);
        }
        return fn(createTrpcClient(), project.id, project.name);
    }
    async create(title, opts) {
        return this.withClient(async (client, projectId, projectKey) => {
            const existing = await client.tasks.list({ projectId, limit: 1000 });
            const prefix = projectKey.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "task";
            const seen = new Set(existing.map((row) => row.id));
            let id = "";
            for (;;) {
                const candidate = `${prefix}-${Math.random().toString(16).slice(2, 7)}`;
                if (!seen.has(candidate)) {
                    id = candidate;
                    break;
                }
            }
            const row = await client.tasks.create({
                projectId,
                id,
                title,
                description: opts?.description,
                type: opts?.type ?? "task",
                priority: opts?.priority ? normalizePriority(opts.priority) : 2,
            });
            await client.tasks.approve({ projectId, taskId: row.id });
            if (opts?.parent) {
                await client.tasks.addDependency({
                    projectId,
                    fromTaskId: row.id,
                    toTaskId: opts.parent,
                    type: "parent-child",
                });
            }
            const current = await client.tasks.get({ projectId, taskId: row.id });
            return taskRowToIssue(current ?? row);
        });
    }
    async addDependency(fromId, toId) {
        await this.withClient(async (client, projectId) => {
            await client.tasks.addDependency({
                projectId,
                fromTaskId: fromId,
                toTaskId: toId,
                type: "blocks",
            });
        });
    }
    async list(opts) {
        return this.withClient(async (client, projectId) => {
            const rows = await client.tasks.list({ projectId, limit: 1000 });
            return rows
                .filter((row) => !opts?.status || row.status === opts.status)
                .filter((row) => !opts?.type || row.type === opts.type)
                .map(taskRowToIssue);
        });
    }
    async ready() {
        return this.list({ status: "ready" });
    }
    async show(id) {
        return this.withClient(async (client, projectId) => {
            const row = await client.tasks.get({ projectId, taskId: id });
            if (!row) {
                throw new Error(`Native task '${id}' not found`);
            }
            return {
                status: row.status,
                description: row.description ?? null,
                notes: null,
            };
        });
    }
    async update(id, opts) {
        await this.withClient(async (client, projectId) => {
            await client.tasks.update({
                projectId,
                taskId: id,
                updates: {
                    title: opts.title,
                    description: opts.description ?? undefined,
                    status: opts.claim ? "in-progress" : opts.status === "in_progress" ? "in-progress" : opts.status,
                },
            });
        });
    }
    async close(id, reason) {
        void reason;
        await this.withClient(async (client, projectId) => {
            await client.tasks.close({ projectId, taskId: id });
        });
    }
}
class ElixirPlanTaskClient {
    projectPath;
    constructor(projectPath) {
        this.projectPath = projectPath;
    }
    async withClient(fn) {
        const projects = await listRegisteredProjects();
        const project = projects.find((record) => record.path === this.projectPath);
        if (!project) {
            throw new Error(`Project at '${this.projectPath}' is not registered with the daemon.`);
        }
        const manager = new ElixirServerManager();
        const status = await manager.ensureRunning();
        return fn(new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN), project.id, project.name);
    }
    async create(title, opts) {
        return this.withClient(async (client, projectId, projectKey) => {
            const existing = (await client.listTasks()).filter((task) => task.project_id === projectId);
            const prefix = projectKey.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "task";
            const seen = new Set(existing.map((row) => row.task_id ?? row.id ?? ""));
            let id = "";
            for (;;) {
                const candidate = `${prefix}-${Math.random().toString(16).slice(2, 7)}`;
                if (!seen.has(candidate)) {
                    id = candidate;
                    break;
                }
            }
            const priority = opts?.priority ? normalizePriority(opts.priority) : 2;
            const createResponse = await client.sendCommand({
                command_id: `plan-create-${id}`,
                command_type: "task.create",
                payload: {
                    project_id: projectId,
                    task_id: id,
                    title,
                    description: opts?.description,
                    task_type: opts?.type ?? "task",
                    priority,
                    status: "backlog",
                },
            });
            if (!createResponse.ok)
                throw new Error(createResponse.error.message);
            const approveResponse = await client.sendCommand({
                command_id: `plan-approve-${id}`,
                command_type: "task.approve",
                payload: { project_id: projectId, task_id: id },
            });
            if (!approveResponse.ok)
                throw new Error(approveResponse.error.message);
            if (opts?.parent) {
                const depResponse = await client.sendCommand({
                    command_id: `plan-parent-${id}`,
                    command_type: "task.add_dependency",
                    payload: { task_id: id, depends_on: opts.parent },
                });
                if (!depResponse.ok)
                    throw new Error(depResponse.error.message);
            }
            const current = await client.getTask(id);
            return elixirTaskToIssue(current ?? {
                task_id: id,
                project_id: projectId,
                title,
                description: opts?.description,
                task_type: opts?.type ?? "task",
                priority,
                status: "ready",
            });
        });
    }
    async addDependency(fromId, toId) {
        await this.withClient(async (client) => {
            const response = await client.sendCommand({
                command_id: `plan-dep-${fromId}-${toId}`,
                command_type: "task.add_dependency",
                payload: { task_id: fromId, depends_on: toId },
            });
            if (!response.ok)
                throw new Error(response.error.message);
        });
    }
    async list(opts) {
        return this.withClient(async (client, projectId) => {
            const rows = (await client.listTasks()).filter((row) => row.project_id === projectId);
            return rows
                .filter((row) => !opts?.status || row.status === opts.status)
                .filter((row) => !opts?.type || (row.task_type ?? row.type) === opts.type)
                .map(elixirTaskToIssue);
        });
    }
    async ready() {
        return this.list({ status: "ready" });
    }
    async show(id) {
        return this.withClient(async (client) => {
            const row = await client.getTask(id);
            if (!row) {
                throw new Error(`Native task '${id}' not found`);
            }
            return {
                status: row.status ?? "backlog",
                description: row.description ?? null,
                notes: null,
            };
        });
    }
    async update(id, opts) {
        await this.withClient(async (client, projectId) => {
            const response = await client.sendCommand({
                command_id: `plan-update-${id}`,
                command_type: "task.update",
                payload: {
                    project_id: projectId,
                    task_id: id,
                    title: opts.title,
                    description: opts.description ?? undefined,
                    status: opts.claim ? "in-progress" : opts.status === "in_progress" ? "in-progress" : opts.status,
                },
            });
            if (!response.ok)
                throw new Error(response.error.message);
        });
    }
    async close(id, reason) {
        void reason;
        await this.withClient(async (client, projectId) => {
            const response = await client.sendCommand({
                command_id: `plan-close-${id}`,
                command_type: "task.close",
                payload: { project_id: projectId, task_id: id },
            });
            if (!response.ok)
                throw new Error(response.error.message);
        });
    }
}
class BeadsPlanTaskClient {
    clientPromise;
    constructor(projectPath) {
        this.clientPromise = import("../../lib/beads-rust.js").then(({ BeadsRustClient }) => new BeadsRustClient(projectPath));
    }
    async withClient(fn) {
        return fn(await this.clientPromise);
    }
    async create(title, opts) {
        return this.withClient((client) => client.create(title, opts));
    }
    async addDependency(fromId, toId) {
        return this.withClient((client) => client.addDependency(fromId, toId));
    }
    async list(opts) {
        return this.withClient((client) => client.list(opts));
    }
    async ready() {
        return this.withClient((client) => client.ready());
    }
    async show(id) {
        return this.withClient((client) => client.show(id));
    }
    async update(id, opts) {
        return this.withClient((client) => client.update(id, opts));
    }
    async close(id, reason) {
        return this.withClient((client) => client.close(id, reason));
    }
}
export function createPlanClient(projectPath) {
    if (foremanBackendMode() === "elixir") {
        return new ElixirPlanTaskClient(projectPath);
    }
    return new NativePlanTaskClient(projectPath);
}
export const planCommand = new Command("plan")
    .description("Run Ensemble PRD → TRD pipeline (create-prd, refine-prd, create-trd, refine-trd)")
    .argument("<description>", "Product description text or path to a description file")
    .option("--prd-only", "Stop after PRD creation and refinement (skip TRD)")
    .option("--from-prd <path>", "Skip PRD creation, start from existing PRD file")
    .option("--output-dir <dir>", "Directory to save PRD/TRD output (default: ./docs)", "./docs")
    .option("--runtime <runtime>", "AI runtime to use (claude-code | codex)", "claude-code")
    .option("--project <path>", "Project path or registered name (default: current directory)")
    .option("--dry-run", "Show the pipeline steps without executing")
    .action(async (description, opts) => {
    const projectPath = await resolveRepoRootProjectPath(opts.project ? { project: opts.project } : {});
    const outputDir = isAbsolute(opts.outputDir)
        ? resolve(opts.outputDir)
        : resolve(projectPath, opts.outputDir);
    // Determine input
    let productDescription;
    const resolvedPath = isAbsolute(description)
        ? resolve(description)
        : resolve(projectPath, description);
    if (existsSync(resolvedPath)) {
        productDescription = readFileSync(resolvedPath, "utf-8");
        console.log(chalk.dim(`Reading description from: ${resolvedPath}`));
    }
    else {
        productDescription = description;
    }
    // Initialize planning task client
    const projects = await listRegisteredProjects();
    const project = projects.find((record) => record.path === projectPath);
    if (!project) {
        console.error(chalk.red("No project registered for this directory. Run 'foreman init' first."));
        process.exitCode = 1;
        return;
    }
    const store = ForemanStore.forProject(projectPath);
    const seeds = createPlanClient(projectPath);
    const dispatcher = new Dispatcher(seeds, store, projectPath, null, { externalProjectId: project.id });
    try {
        // Validate --from-prd path
        if (opts.fromPrd) {
            const prdPath = isAbsolute(opts.fromPrd)
                ? resolve(opts.fromPrd)
                : resolve(projectPath, opts.fromPrd);
            if (!existsSync(prdPath)) {
                console.error(chalk.red(`PRD file not found: ${prdPath}`));
                process.exitCode = 1;
                return;
            }
            console.log(chalk.dim(`Using existing PRD: ${prdPath}\n`));
        }
        // Build pipeline step definitions
        const steps = buildPipelineSteps(productDescription, outputDir, opts.fromPrd, opts.prdOnly);
        // Display pipeline
        console.log(chalk.bold.cyan("\n Planning Pipeline\n"));
        console.log(chalk.dim(`Runtime: ${opts.runtime} | Output: ${outputDir}\n`));
        for (let i = 0; i < steps.length; i++) {
            const step = steps[i];
            const num = `${i + 1}`.padStart(2);
            console.log(`  ${chalk.bold(`${num}.`)} ${chalk.cyan(step.name)} ${chalk.dim(`(${step.command})`)}`);
            console.log(chalk.dim(`      ${step.description}`));
        }
        if (opts.dryRun) {
            console.log(chalk.yellow("\n--dry-run: Pipeline not executed."));
            console.log(chalk.dim("\nWhen run without --dry-run, Foreman will:"));
            console.log(chalk.dim("  1. Create an epic planning task with child planning tasks (native tasks only)"));
            console.log(chalk.dim("  2. Dispatch each step via Claude Code + Ensemble"));
            console.log(chalk.dim("  3. Track progress in Postgres"));
            console.log(chalk.dim("  4. Suggest 'foreman sling trd <output-dir>/TRD.md' on completion"));
            return;
        }
        // Create epic seed
        const epicTitle = `Plan: ${productDescription.slice(0, 80)}${productDescription.length > 80 ? "..." : ""}`;
        const epic = await seeds.create(epicTitle, {
            type: "epic",
            priority: "P1",
            description: `Planning pipeline for: ${productDescription.slice(0, 200)}`,
        });
        console.log(chalk.dim(`\nEpic task: ${epic.id} — ${epicTitle}`));
        // Create child seeds with sequential dependencies
        const seedIds = [];
        for (let i = 0; i < steps.length; i++) {
            const step = steps[i];
            const child = await seeds.create(step.name, {
                type: "task",
                priority: "P1",
                parent: epic.id,
                description: `${step.command} ${step.input}`,
            });
            // Add dependency on the previous seed (sequential chain)
            if (i > 0) {
                await seeds.addDependency(child.id, seedIds[i - 1]);
            }
            seedIds.push(child.id);
            console.log(chalk.dim(`  Task ${child.id}: ${step.name}${i > 0 ? ` (depends on ${seedIds[i - 1]})` : " (ready)"}`));
        }
        // Sequential dispatch loop
        console.log(chalk.bold("\n Starting pipeline...\n"));
        const seedIdSet = new Set(seedIds);
        let completedCount = 0;
        while (completedCount < seedIds.length) {
            // Find ready seeds that belong to our epic
            const readySeeds = await seeds.ready();
            const epicReady = readySeeds.filter((b) => seedIdSet.has(b.id));
            if (epicReady.length === 0) {
                // No ready seeds yet — poll until one becomes ready
                await sleep(10_000);
                continue;
            }
            for (const readySeed of epicReady) {
                const stepIndex = seedIds.indexOf(readySeed.id);
                const step = steps[stepIndex];
                console.log(chalk.bold(`\n[${completedCount + 1}/${seedIds.length}] ${step.name}...`));
                try {
                    const result = await dispatcher.dispatchPlanStep(project.id, {
                        id: readySeed.id,
                        title: readySeed.title,
                        type: readySeed.type,
                        priority: readySeed.priority,
                    }, step.command, step.input, outputDir);
                    // Close the seed on success
                    await seeds.close(readySeed.id, "Completed");
                    console.log(chalk.green(`  ${step.name} complete (run: ${result.runId})`));
                    completedCount++;
                }
                catch (err) {
                    const message = err instanceof Error ? err.message : String(err);
                    console.error(chalk.red(`  ${step.name} failed: ${message}`));
                    console.log(chalk.yellow("\nPipeline paused. Fix the issue and re-run with --from-prd if needed."));
                    process.exitCode = 1;
                    return;
                }
            }
        }
        // All done — close the epic
        await seeds.close(epic.id, "All planning steps completed");
        console.log(chalk.bold.green("\n Planning pipeline complete!"));
        console.log(chalk.dim(`\nOutputs in: ${outputDir}`));
        console.log(chalk.dim(`Epic: ${epic.id}`));
        const prdHintPath = inferPrdHintPath(outputDir, opts.fromPrd);
        console.log(chalk.dim(`\nNext step: foreman sling prd ${prdHintPath} --auto`));
    }
    finally {
        store.close();
    }
});
planCommand
    .command("prd")
    .description("Run PRD planning through the Elixir orchestration server")
    .argument("<description>", "Product description text or path to a description file")
    .option("--project <path>", "Project path or registered name (default: current directory)")
    .option("--output-dir <dir>", "Directory to save PRD output (default: ./docs)", "./docs")
    .option("--provider <provider>", "Planning provider adapter", "pi_sdk")
    .option("--run-id <id>", "Explicit planning run id")
    .option("--command-id <id>", "Explicit server command id for idempotent retries")
    .option("--no-auto-start", "Require an already-running Elixir server")
    .action(async (description, opts, command) => {
    await runServerPlanningCommand("prd", description, mergedServerPlanOptions(opts, command));
});
planCommand
    .command("trd")
    .description("Run TRD planning through the Elixir orchestration server")
    .argument("<description>", "TRD description or path to an existing PRD/input file")
    .option("--project <path>", "Project path or registered name (default: current directory)")
    .option("--output-dir <dir>", "Directory to save TRD output (default: ./docs)", "./docs")
    .option("--provider <provider>", "Planning provider adapter", "pi_sdk")
    .option("--run-id <id>", "Explicit planning run id")
    .option("--command-id <id>", "Explicit server command id for idempotent retries")
    .option("--no-auto-start", "Require an already-running Elixir server")
    .action(async (description, opts, command) => {
    await runServerPlanningCommand("trd", description, mergedServerPlanOptions(opts, command));
});
// ── Helpers ──────────────────────────────────────────────────────────────
function mergedServerPlanOptions(opts, command) {
    const parentOpts = command.parent?.opts() ?? {};
    const outputDirSource = command.getOptionValueSource("outputDir");
    return {
        ...opts,
        project: opts.project ?? parentOpts.project,
        outputDir: outputDirSource === "cli" ? opts.outputDir : (parentOpts.outputDir ?? opts.outputDir),
    };
}
async function runServerPlanningCommand(kind, description, opts) {
    const projectPath = await resolveRepoRootProjectPath(opts.project ? { project: opts.project } : {});
    const projects = await listRegisteredProjects();
    const project = projects.find((record) => record.path === projectPath);
    if (!project) {
        console.error(chalk.red("No project registered for this directory. Run 'foreman init' first."));
        process.exitCode = 1;
        return;
    }
    const outputDir = isAbsolute(opts.outputDir)
        ? resolve(opts.outputDir)
        : resolve(projectPath, opts.outputDir);
    const input = readPlanningInput(description, projectPath);
    const commandId = opts.commandId ?? `plan-${kind}-${Date.now()}`;
    const manager = new ElixirServerManager();
    const status = opts.autoStart === false ? manager.status() : await manager.ensureRunning();
    if (!status.running) {
        console.error(chalk.red("Elixir server is not running. Start it with 'foreman server start' or omit --no-auto-start."));
        process.exitCode = 1;
        return;
    }
    const client = new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
    const response = await client.sendCommand({
        command_id: commandId,
        command_type: `plan.${kind}`,
        payload: {
            kind,
            project_id: project.id,
            description: input,
            output_dir: outputDir,
            provider: opts.provider,
            ...(opts.runId ? { run_id: opts.runId } : {}),
            ...(kind === "trd" && existsSync(resolve(projectPath, description)) ? { from_prd: resolve(projectPath, description) } : {}),
        },
        metadata: { correlation_id: commandId, source: "foreman-cli-plan" },
    });
    if (!response.ok) {
        console.error(chalk.red(`Planning command failed: ${response.error.message}`));
        process.exitCode = 1;
        return;
    }
    console.log(chalk.green(`✓ Planning ${kind.toUpperCase()} command accepted`));
    console.log(chalk.dim(`Command: ${commandId}`));
    console.log(chalk.dim(`Events: ${response.events.join(", ")}`));
}
export function readPlanningInput(description, projectPath) {
    const resolvedPath = isAbsolute(description) ? resolve(description) : resolve(projectPath, description);
    if (!existsSync(resolvedPath))
        return description;
    console.log(chalk.dim(`Reading description from: ${resolvedPath}`));
    return readFileSync(resolvedPath, "utf-8");
}
function buildPipelineSteps(productDescription, outputDir, fromPrd, prdOnly) {
    const steps = [];
    if (!fromPrd) {
        steps.push({
            name: "Create PRD",
            command: "/ensemble:create-prd",
            description: "Analyze product description, define users, goals, and requirements",
            input: productDescription,
        });
        steps.push({
            name: "Refine PRD",
            command: "/ensemble:refine-prd",
            description: "Review and strengthen acceptance criteria, edge cases, constraints",
            input: `Review and refine the PRD in ${outputDir}`,
        });
    }
    if (!prdOnly) {
        steps.push({
            name: "Create TRD",
            command: "/ensemble:create-trd",
            description: "Translate PRD into technical architecture, task breakdown, sprint planning",
            input: fromPrd
                ? resolve(fromPrd)
                : `${outputDir}/PRD.md`,
        });
        steps.push({
            name: "Refine TRD",
            command: "/ensemble:refine-trd",
            description: "Review technical decisions, validate task dependencies, refine estimates",
            input: `Review and refine the TRD in ${outputDir}`,
        });
    }
    return steps;
}
export function inferPrdHintPath(outputDir, fromPrd) {
    if (fromPrd)
        return fromPrd;
    const candidates = readdirSync(outputDir)
        .filter((name) => name.endsWith(".md") && name.startsWith("PRD"))
        .sort();
    if (candidates.length > 0) {
        return join(outputDir, candidates[candidates.length - 1]);
    }
    return join(outputDir, "PRD.md");
}
function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}
//# sourceMappingURL=plan.js.map