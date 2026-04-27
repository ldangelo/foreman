import { Command } from "commander";
import chalk from "chalk";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";

import { normalizePriority } from "../../lib/priority.js";
import { ForemanStore } from "../../lib/store.js";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { type TaskRow } from "../../lib/task-store.js";
import { selectTaskReadBackend } from "../../lib/task-client-factory.js";
import type { ITaskClient, Issue, UpdateOptions } from "../../lib/task-client.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import type { PlanStepDefinition } from "../../orchestrator/types.js";
import { listRegisteredProjects, resolveRepoRootProjectPath } from "./project-task-support.js";

// ── Client factory (TRD-016) ──────────────────────────────────────────────

interface PlanCreateOptions {
  type?: string;
  priority?: string;
  parent?: string;
  description?: string;
}

export interface PlanTaskClient extends ITaskClient {
  create(title: string, opts?: PlanCreateOptions): Promise<Issue>;
  addDependency(fromId: string, toId: string): Promise<void>;
}

function taskRowToIssue(row: TaskRow): Issue {
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

class NativePlanTaskClient implements PlanTaskClient {
  constructor(private readonly projectPath: string) {}

  private async withClient<T>(fn: (client: ReturnType<typeof createTrpcClient>, projectId: string, projectKey: string) => Promise<T>): Promise<T> {
    const projects = await listRegisteredProjects();
    const project = projects.find((record) => record.path === this.projectPath);
    if (!project) {
      throw new Error(`Project at '${this.projectPath}' is not registered with the daemon.`);
    }
    return fn(createTrpcClient(), project.id, project.name);
  }

  async create(title: string, opts?: PlanCreateOptions): Promise<Issue> {
    return this.withClient(async (client, projectId, projectKey) => {
      const existing = await client.tasks.list({ projectId, limit: 1000 }) as TaskRow[];
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
      }) as TaskRow;
      await client.tasks.approve({ projectId, taskId: row.id });
      if (opts?.parent) {
        await client.tasks.addDependency({
          projectId,
          fromTaskId: row.id,
          toTaskId: opts.parent,
          type: "parent-child",
        });
      }
      const current = await client.tasks.get({ projectId, taskId: row.id }) as TaskRow | null;
      return taskRowToIssue(current ?? row);
    });
  }

  async addDependency(fromId: string, toId: string): Promise<void> {
    await this.withClient(async (client, projectId) => {
      await client.tasks.addDependency({
        projectId,
        fromTaskId: fromId,
        toTaskId: toId,
        type: "blocks",
      });
    });
  }

  async list(opts?: { status?: string; type?: string }): Promise<Issue[]> {
    return this.withClient(async (client, projectId) => {
      const rows = await client.tasks.list({ projectId, limit: 1000 }) as TaskRow[];
      return rows
        .filter((row) => !opts?.status || row.status === opts.status)
        .filter((row) => !opts?.type || row.type === opts.type)
        .map(taskRowToIssue);
    });
  }

  async ready(): Promise<Issue[]> {
    return this.list({ status: "ready" });
  }

  async show(id: string): Promise<{ status: string; description?: string | null; notes?: string | null }> {
    return this.withClient(async (client, projectId) => {
      const row = await client.tasks.get({ projectId, taskId: id }) as TaskRow | null;
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

  async update(id: string, opts: UpdateOptions): Promise<void> {
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

  async close(id: string, reason?: string): Promise<void> {
    void reason;
    await this.withClient(async (client, projectId) => {
      await client.tasks.close({ projectId, taskId: id });
    });
  }
}

class BeadsPlanTaskClient implements PlanTaskClient {
  private readonly clientPromise: Promise<PlanTaskClient>;

  constructor(projectPath: string) {
    this.clientPromise = import("../../lib/beads-rust.js").then(({ BeadsRustClient }) =>
      new BeadsRustClient(projectPath) as PlanTaskClient
    );
  }

  private async withClient<T>(fn: (client: PlanTaskClient) => Promise<T>): Promise<T> {
    return fn(await this.clientPromise);
  }

  async create(title: string, opts?: PlanCreateOptions): Promise<Issue> {
    return this.withClient((client) => client.create(title, opts));
  }

  async addDependency(fromId: string, toId: string): Promise<void> {
    return this.withClient((client) => client.addDependency(fromId, toId));
  }

  async list(opts?: { status?: string; type?: string }): Promise<Issue[]> {
    return this.withClient((client) => client.list(opts));
  }

  async ready(): Promise<Issue[]> {
    return this.withClient((client) => client.ready());
  }

  async show(id: string): Promise<{ status: string; description?: string | null; notes?: string | null }> {
    return this.withClient((client) => client.show(id));
  }

  async update(id: string, opts: UpdateOptions): Promise<void> {
    return this.withClient((client) => client.update(id, opts));
  }

  async close(id: string, reason?: string): Promise<void> {
    return this.withClient((client) => client.close(id, reason));
  }
}

export function createPlanClient(
  projectPath: string,
): PlanTaskClient {
  return selectTaskReadBackend(projectPath) === "native"
    ? new NativePlanTaskClient(projectPath)
    : new BeadsPlanTaskClient(projectPath);
}

export const planCommand = new Command("plan")
  .description(
    "Run Ensemble PRD → TRD pipeline (create-prd, refine-prd, create-trd, refine-trd)",
  )
  .argument(
    "<description>",
    "Product description text or path to a description file",
  )
  .option(
    "--prd-only",
    "Stop after PRD creation and refinement (skip TRD)",
  )
  .option(
    "--from-prd <path>",
    "Skip PRD creation, start from existing PRD file",
  )
  .option(
    "--output-dir <dir>",
    "Directory to save PRD/TRD output (default: ./docs)",
    "./docs",
  )
  .option(
    "--runtime <runtime>",
    "AI runtime to use (claude-code | codex)",
    "claude-code",
  )
  .option("--project <path>", "Project path or registered name (default: current directory)")
  .option("--dry-run", "Show the pipeline steps without executing")
  .action(
    async (
      description: string,
      opts: {
        prdOnly?: boolean;
        fromPrd?: string;
        outputDir: string;
        runtime: string;
        project?: string;
        dryRun?: boolean;
      },
    ) => {
      const projectPath = await resolveRepoRootProjectPath(opts.project ? { project: opts.project } : {});
      const outputDir = isAbsolute(opts.outputDir)
        ? resolve(opts.outputDir)
        : resolve(projectPath, opts.outputDir);

      // Determine input
      let productDescription: string;
      const resolvedPath = isAbsolute(description)
        ? resolve(description)
        : resolve(projectPath, description);
      if (existsSync(resolvedPath)) {
        productDescription = readFileSync(resolvedPath, "utf-8");
        console.log(chalk.dim(`Reading description from: ${resolvedPath}`));
      } else {
        productDescription = description;
      }

      // Initialize planning task client
      const projects = await listRegisteredProjects();
      const project = projects.find((record) => record.path === projectPath);
      if (!project) {
        console.error(
          chalk.red(
            "No project registered for this directory. Run 'foreman init' first.",
          ),
        );
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
        const steps = buildPipelineSteps(
          productDescription,
          outputDir,
          opts.fromPrd,
          opts.prdOnly,
        );

        // Display pipeline
        console.log(chalk.bold.cyan("\n Planning Pipeline\n"));
        console.log(
          chalk.dim(`Runtime: ${opts.runtime} | Output: ${outputDir}\n`),
        );
        for (let i = 0; i < steps.length; i++) {
          const step = steps[i];
          const num = `${i + 1}`.padStart(2);
          console.log(
            `  ${chalk.bold(`${num}.`)} ${chalk.cyan(step.name)} ${chalk.dim(`(${step.command})`)}`,
          );
          console.log(chalk.dim(`      ${step.description}`));
        }

        if (opts.dryRun) {
          console.log(
            chalk.yellow("\n--dry-run: Pipeline not executed."),
          );
          console.log(
            chalk.dim(
              "\nWhen run without --dry-run, Foreman will:",
            ),
          );
          console.log(
            chalk.dim(
              "  1. Create an epic planning task with child planning tasks (native-first, beads fallback)",
            ),
          );
          console.log(chalk.dim("  2. Dispatch each step via Claude Code + Ensemble"));
          console.log(chalk.dim("  3. Track progress in SQLite"));
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
        console.log(
          chalk.dim(`\nEpic task: ${epic.id} — ${epicTitle}`),
        );

        // Create child seeds with sequential dependencies
        const seedIds: string[] = [];
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
          console.log(
            chalk.dim(
              `  Task ${child.id}: ${step.name}${i > 0 ? ` (depends on ${seedIds[i - 1]})` : " (ready)"}`,
            ),
          );
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
            console.log(
              chalk.bold(
                `\n[${completedCount + 1}/${seedIds.length}] ${step.name}...`,
              ),
            );

            try {
              const result = await dispatcher.dispatchPlanStep(
                project.id,
                {
                  id: readySeed.id,
                  title: readySeed.title,
                  type: readySeed.type,
                  priority: readySeed.priority,
                },
                step.command,
                step.input,
                outputDir,
              );

              // Close the seed on success
              await seeds.close(readySeed.id, "Completed");
              console.log(
                chalk.green(
                  `  ${step.name} complete (run: ${result.runId})`,
                ),
              );
              completedCount++;
            } catch (err: unknown) {
              const message = err instanceof Error ? err.message : String(err);
              console.error(
                chalk.red(`  ${step.name} failed: ${message}`),
              );
              console.log(
                chalk.yellow(
                  "\nPipeline paused. Fix the issue and re-run with --from-prd if needed.",
                ),
              );
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
        console.log(
          chalk.dim(
            `\nNext step: foreman sling prd ${prdHintPath} --auto`,
          ),
        );
      } finally {
        store.close();
      }
    },
  );

// ── Helpers ──────────────────────────────────────────────────────────────

function buildPipelineSteps(
  productDescription: string,
  outputDir: string,
  fromPrd: string | undefined,
  prdOnly: boolean | undefined,
): PlanStepDefinition[] {
  const steps: PlanStepDefinition[] = [];

  if (!fromPrd) {
    steps.push({
      name: "Create PRD",
      command: "/ensemble:create-prd",
      description:
        "Analyze product description, define users, goals, and requirements",
      input: productDescription,
    });
    steps.push({
      name: "Refine PRD",
      command: "/ensemble:refine-prd",
      description:
        "Review and strengthen acceptance criteria, edge cases, constraints",
      input: `Review and refine the PRD in ${outputDir}`,
    });
  }

  if (!prdOnly) {
    steps.push({
      name: "Create TRD",
      command: "/ensemble:create-trd",
      description:
        "Translate PRD into technical architecture, task breakdown, sprint planning",
      input: fromPrd
        ? resolve(fromPrd)
        : `${outputDir}/PRD.md`,
    });
    steps.push({
      name: "Refine TRD",
      command: "/ensemble:refine-trd",
      description:
        "Review technical decisions, validate task dependencies, refine estimates",
      input: `Review and refine the TRD in ${outputDir}`,
    });
  }

  return steps;
}

export function inferPrdHintPath(outputDir: string, fromPrd?: string): string {
  if (fromPrd) return fromPrd;
  const candidates = readdirSync(outputDir)
    .filter((name) => name.endsWith(".md") && name.startsWith("PRD"))
    .sort();
  if (candidates.length > 0) {
    return join(outputDir, candidates[candidates.length - 1]);
  }
  return join(outputDir, "PRD.md");
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
