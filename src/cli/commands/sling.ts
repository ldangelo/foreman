import { Command } from "commander";
import chalk from "chalk";
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { parseTrd } from "../../orchestrator/trd-parser.js";
import { analyzeParallel } from "../../orchestrator/sprint-parallel.js";
import { execute } from "../../orchestrator/sling-executor.js";
import { runWithPiSdk } from "../../orchestrator/pi-sdk-runner.js";
import { createTrpcClient } from "../../lib/trpc-client.js";
import type { TaskRow } from "../../lib/task-store.js";
import type { SlingPlan, SlingOptions, SlingResult, ParallelResult } from "../../orchestrator/types.js";
import { listRegisteredProjects, resolveRepoRootProjectPath } from "./project-task-support.js";

// ── Legacy backend flag helpers (exported for testing) ────────────────────

/**
 * Legacy helper retained for backward-compatibility tests.
 *
 * Historically sling defaulted to --br-only. Native task migration now ignores
 * the backend-targeting flags, but this helper is retained so older callers and
 * tests do not break while the flag surface remains accepted.
 */
export function resolveDefaultBrOnly(opts: { sdOnly?: boolean; brOnly?: boolean }): void {
  if (!opts.sdOnly && !opts.brOnly) {
    opts.brOnly = true;
  }
}

export function applySdOnlyDeprecation(opts: { sdOnly?: boolean; brOnly?: boolean }): boolean {
  if (!opts.sdOnly) return false;
  process.stderr.write(
    chalk.yellow(
      "SLING-DEPRECATED: --sd-only is deprecated and will be removed in a future release. " +
      "Foreman now writes sling output to the native task store only. Legacy backend flags are ignored.\n",
    ),
  );
  opts.sdOnly = false;
  opts.brOnly = false;
  return true;
}

export function getSlingLegacyBackendFlagNotice(): string {
  return "SLING-DEPRECATED: legacy backend-targeting flags are ignored; sling writes native tasks only.";
}

type SlingTargetingOptions = {
  project?: string;
  projectPath?: string;
};

async function resolveSlingProjectPath(opts: SlingTargetingOptions): Promise<string | null> {
  if (opts.project && opts.projectPath) {
    console.error(chalk.red("SLING-006: --project and --project-path cannot be used together."));
    return null;
  }

  if (opts.projectPath) {
    if (!isAbsolute(opts.projectPath)) {
      console.error(chalk.red("SLING-007: --project-path must be an absolute path."));
      return null;
    }

    return opts.projectPath;
  }

  return resolveRepoRootProjectPath({ project: opts.project });
}

function createDaemonSlingWriter(client: ReturnType<typeof createTrpcClient>, projectId: string) {
  return {
    async getByExternalId(externalId: string) {
      const rows = await client.tasks.list({ projectId, limit: 1000 }) as TaskRow[];
      return rows.find((row) => row.external_id === externalId) ?? null;
    },
    async create(opts: { title: string; description?: string | null; type?: string; priority?: number; externalId?: string }) {
      const existing = await client.tasks.list({ projectId, limit: 1000 }) as TaskRow[];
      const prefix = "foreman";
      let id = "";
      for (;;) {
        const candidate = `${prefix}-${Math.random().toString(16).slice(2, 7)}`;
        if (!existing.some((row) => row.id === candidate)) {
          id = candidate;
          break;
        }
      }
      return await client.tasks.create({
        projectId,
        id,
        title: opts.title,
        description: opts.description ?? undefined,
        type: opts.type ?? "task",
        priority: opts.priority ?? 2,
        externalId: opts.externalId,
      }) as unknown as TaskRow;
    },
    async update(id: string, opts: { title?: string; description?: string | null; priority?: number; force?: boolean }) {
      void opts.force;
      await client.tasks.update({
        projectId,
        taskId: id,
        updates: {
          title: opts.title,
          description: opts.description ?? undefined,
          priority: opts.priority,
        },
      });
      return await client.tasks.get({ projectId, taskId: id }) as unknown as TaskRow;
    },
    async close(id: string, _reason?: string) {
      await client.tasks.close({ projectId, taskId: id });
    },
    async addDependency(fromId: string, toId: string, type: "blocks" | "parent-child" = "blocks") {
      await client.tasks.addDependency({ projectId, fromTaskId: fromId, toTaskId: toId, type });
    },
  };
}

const MIN_PRD_READINESS_SCORE = 4;

export function parsePrdReadinessScore(content: string): number | null {
  const normalized = content.replaceAll("*", "");
  const match = normalized.match(
    /readiness(?:\s+score|_score)?\s*[:|]\s*([0-5](?:\.\d+)?)/i,
  );
  if (!match?.[1]) {
    return null;
  }

  const score = Number.parseFloat(match[1]);
  return Number.isFinite(score) ? score : null;
}

function findLatestGeneratedTrd(trdDir: string): string | null {
  if (!existsSync(trdDir)) {
    return null;
  }

  const candidates = readdirSync(trdDir)
    .filter((entry) => /^TRD-.*\.md$/i.test(entry))
    .map((entry) => ({
      path: join(trdDir, entry),
      mtimeMs: statSync(join(trdDir, entry)).mtimeMs,
    }))
    .sort((a, b) => b.mtimeMs - a.mtimeMs);

  return candidates[0]?.path ?? null;
}

type SlingCliOptions = Record<string, boolean | string | undefined>;

async function handleTrdImport(
  projectPath: string,
  resolvedTrdPath: string,
  opts: SlingCliOptions,
  jsonExtras: Record<string, unknown> = {},
): Promise<void> {
  const content = readFileSync(resolvedTrdPath, "utf-8");
  const lines = content.split("\n").length;

  if (!opts.json) {
    console.log(chalk.dim(`Reading TRD: ${resolvedTrdPath} (${lines} lines)\n`));
  }

  let plan: SlingPlan;
  try {
    plan = parseTrd(content);
  } catch (err: unknown) {
    console.error(chalk.red((err as Error).message));
    process.exitCode = 1;
    return;
  }

  const parallel = opts.parallel === false
    ? { groups: [], warnings: [] } as ParallelResult
    : analyzeParallel(plan, content);

  if (opts.json) {
    console.log(JSON.stringify({
      ...jsonExtras,
      sourceTrdPath: resolvedTrdPath,
      epic: plan.epic,
      sprints: plan.sprints,
      parallel: parallel.groups,
      warnings: parallel.warnings,
      acceptanceCriteria: Object.fromEntries(plan.acceptanceCriteria),
      riskMap: Object.fromEntries(plan.riskMap),
    }, null, 2));
    return;
  }

  printSlingPlan(plan, parallel);

  const emittedSdNotice = applySdOnlyDeprecation(opts);
  if (!emittedSdNotice && opts.brOnly) {
    console.warn(chalk.yellow(`${getSlingLegacyBackendFlagNotice()} (--br-only)`));
  }

  // Retained for compatibility with older tests/callers; the native path does
  // not consult these flags anymore.
  resolveDefaultBrOnly(opts);

  if (opts.dryRun) {
    console.log(chalk.dim("Migration note: sling is migrating task creation to the native task store."));
    console.log(chalk.dim("Dry run — native task store preview only; no tasks created."));
    console.log(chalk.dim("Sling now writes native backlog tasks that require explicit approval before dispatch."));
    return;
  }

  if (!opts.auto) {
    const answer = await new Promise<string>((resolveAnswer) => {
      const rl = createInterface({ input: process.stdin, output: process.stdout });
      rl.question(
        chalk.bold("Create native tasks in the project task store? [y/N] "),
        (ans) => {
          rl.close();
          resolveAnswer(ans);
        },
      );
    });
    if (answer.toLowerCase() !== "y") {
      console.log(chalk.dim("Aborted."));
      return;
    }
  }

  const slingOptions: SlingOptions = {
    dryRun: false,
    auto: !!opts.auto,
    json: false,
    sdOnly: !!opts.sdOnly,
    brOnly: !!opts.brOnly,
    skipCompleted: !!opts.skipCompleted,
    closeCompleted: !!opts.closeCompleted,
    noParallel: opts.parallel === false,
    force: !!opts.force,
    noRisks: opts.risks === false,
    noQuality: opts.quality === false,
  };

  const projects = await listRegisteredProjects();
  const project = projects.find((record) => record.path === projectPath);
  if (!project) {
    throw new Error(`Project at '${projectPath}' is not registered with the daemon.`);
  }
  const taskWriter = createDaemonSlingWriter(createTrpcClient(), project.id);
  const spinner = createProgressSpinner();
  const result = await execute(
    plan,
    parallel,
    slingOptions,
    taskWriter as never,
    spinner.update,
  );
  spinner.finish();
  printSummary(result);
}

// ── Preview display ──────────────────────────────────────────────────────

function printSlingPlan(plan: SlingPlan, parallel: ParallelResult): void {
  const totalTasks = plan.sprints.reduce(
    (sum, s) => sum + s.stories.reduce((ss, st) => ss + st.tasks.length, 0),
    0,
  );
  const totalHours = plan.sprints.reduce(
    (sum, s) =>
      sum +
      s.stories.reduce(
        (ss, st) => ss + st.tasks.reduce((ts, t) => ts + t.estimateHours, 0),
        0,
      ),
    0,
  );

  console.log(
    chalk.bold(
      `\nEpic: ${plan.epic.title} (${totalTasks} tasks, ${plan.sprints.length} sprints, ~${totalHours}h)\n`,
    ),
  );

  const sprintToGroup = new Map<number, string>();
  for (const group of parallel.groups) {
    for (const idx of group.sprintIndices) {
      sprintToGroup.set(idx, group.label);
    }
  }

  for (let si = 0; si < plan.sprints.length; si++) {
    const sprint = plan.sprints[si];
    if (!sprint) continue;
    const sprintTasks = sprint.stories.reduce((sum, st) => sum + st.tasks.length, 0);
    const sprintHours = sprint.stories.reduce(
      (sum, st) => sum + st.tasks.reduce((ts, t) => ts + t.estimateHours, 0),
      0,
    );
    const groupLabel = sprintToGroup.get(si);
    const prefix = groupLabel ? chalk.cyan("║ ") : "  ";
    const groupTag = groupLabel ? chalk.cyan(` [parallel:${groupLabel}]`) : "";
    const priorityTag = chalk.dim(`[${sprint.priority}]`);

    console.log(
      `${prefix}${chalk.bold(sprint.title)} (${sprintHours}h, ${sprintTasks} tasks)` +
        ` ${priorityTag}${groupTag}`,
    );

    for (const story of sprint.stories) {
      const storyCompleted = story.tasks.filter((t) => t.status === "completed").length;
      const storyTag =
        storyCompleted === story.tasks.length
          ? chalk.green(" (all completed)")
          : storyCompleted > 0
            ? chalk.yellow(` (${storyCompleted}/${story.tasks.length} completed)`)
            : "";

      console.log(`${prefix}  ${story.title}${storyTag}`);

      for (const task of story.tasks) {
        const statusIcon =
          task.status === "completed"
            ? chalk.green("✓")
            : task.status === "in_progress"
              ? chalk.yellow("~")
              : chalk.dim("○");
        const deps =
          task.dependencies.length > 0
            ? chalk.dim(` ← ${task.dependencies.join(", ")}`)
            : "";
        const est = task.estimateHours > 0 ? chalk.dim(` ${task.estimateHours}h`) : "";
        const risk = task.riskLevel ? chalk.red(` [${task.riskLevel}]`) : "";

        console.log(
          `${prefix}    ${statusIcon} ${chalk.dim(task.trdId)}  ${task.title}${est}${deps}${risk}`,
        );
      }
    }
    console.log();
  }

  if (parallel.groups.length > 0) {
    console.log(chalk.bold("Parallel Groups:"));
    for (const group of parallel.groups) {
      const sprintNames = group.sprintIndices
        .map((i) => plan.sprints[i]?.title)
        .filter((title): title is string => Boolean(title))
        .join(", ");
      console.log(`  ${chalk.cyan(group.label)}: ${sprintNames}`);
    }
    console.log();
  }

  if (parallel.warnings.length > 0) {
    console.log(chalk.yellow("Parallelization warnings:"));
    for (const warning of parallel.warnings) {
      console.log(chalk.yellow(`  ⚠ ${warning}`));
    }
    console.log();
  }
}

function printSummary(result: SlingResult): void {
  const native = result.native;
  console.log(
    chalk.bold(
      `\nSummary: native: ${native.created} created, ${native.skipped} skipped, ${native.failed} failed`,
    ),
  );

  if (result.depErrors.length > 0) {
    console.log(chalk.yellow(`\nDependency warnings (${result.depErrors.length}):`));
    for (const err of result.depErrors.slice(0, 10)) {
      console.log(chalk.yellow(`  ⚠ ${err}`));
    }
    if (result.depErrors.length > 10) {
      console.log(chalk.dim(`  ... and ${result.depErrors.length - 10} more`));
    }
  }

  const nonDependencyErrors = result.native.errors.filter((error) => !error.includes("SLING-007"));
  if (nonDependencyErrors.length > 0) {
    console.log(chalk.red(`\nErrors (${nonDependencyErrors.length}):`));
    for (const err of nonDependencyErrors) {
      console.log(chalk.red(`  ✗ ${err}`));
    }
  }
}

// ── Progress spinner ─────────────────────────────────────────────────────

function createProgressSpinner() {
  let processedCount = 0;

  return {
    update(processed: number, total: number, _tracker: "native") {
      processedCount = processed;
      const line = `Writing native tasks... ${processedCount}/${total}`;
      if (process.stdout.isTTY) {
        createInterface({ input: process.stdin, output: process.stdout });
        process.stdout.write(`\r${chalk.dim(line)}`);
      }
    },
    finish() {
      if (process.stdout.isTTY) {
        process.stdout.write("\r" + " ".repeat(80) + "\r");
      }
    },
  };
}

// ── CLI Commands ─────────────────────────────────────────────────────────

const trdSubcommand = new Command("trd")
  .description("Convert a TRD into native task hierarchies")
  .argument("<trd-file>", "Path to TRD markdown file")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path for advanced/scripted usage")
  .option("--dry-run", "Preview without creating tasks")
  .option("--auto", "Skip confirmation prompt")
  .option("--json", "Output parsed structure as JSON")
  .option("--sd-only", "Legacy no-op; sling now writes to the native task store only")
  .option("--br-only", "Legacy no-op; sling now writes to the native task store only")
  .option("--skip-completed", "Skip [x] tasks (not created)")
  .option("--close-completed", "Create [x] tasks and immediately close them")
  .option("--no-parallel", "Disable parallel sprint detection")
  .option("--force", "Refresh matching native tasks even if trd:<ID> already exists")
  .option("--no-risks", "Skip risk register parsing")
  .option("--no-quality", "Skip quality requirements parsing")
  .action(async (trdFile: string, opts: SlingCliOptions) => {
    const projectPath = await resolveSlingProjectPath({
      project: typeof opts.project === "string" ? opts.project : undefined,
      projectPath: typeof opts.projectPath === "string" ? opts.projectPath : undefined,
    });
    if (!projectPath) {
      process.exitCode = 1;
      return;
    }

    const resolved = isAbsolute(trdFile) ? resolve(trdFile) : resolve(projectPath, trdFile);
    if (!existsSync(resolved)) {
      console.error(chalk.red(`SLING-001: TRD file not found: ${resolved}`));
      process.exitCode = 1;
      return;
    }
    await handleTrdImport(projectPath, resolved, opts);
  });

const prdSubcommand = new Command("prd")
  .description("Generate a TRD from a PRD and preview or import the parsed task plan")
  .argument("<prd-file>", "Path to PRD markdown file")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path for advanced/scripted usage")
  .option("--dry-run", "Generate and preview the TRD-derived plan without creating tasks")
  .option("--auto", "Skip confirmation prompt")
  .option("--json", "Output the generated TRD path and parsed structure as JSON")
  .option("--sd-only", "Legacy no-op; sling now writes to the native task store only")
  .option("--br-only", "Legacy no-op; sling now writes to the native task store only")
  .option("--skip-completed", "Skip [x] tasks (not created)")
  .option("--close-completed", "Create [x] tasks and immediately close them")
  .option("--no-parallel", "Disable parallel sprint detection")
  .option("--force", "Refresh matching native tasks even if trd:<ID> already exists")
  .option("--no-risks", "Skip risk register parsing")
  .option("--no-quality", "Skip quality requirements parsing")
  .action(async (prdFile: string, opts: SlingCliOptions) => {
    const projectPath = await resolveSlingProjectPath({
      project: typeof opts.project === "string" ? opts.project : undefined,
      projectPath: typeof opts.projectPath === "string" ? opts.projectPath : undefined,
    });
    if (!projectPath) {
      process.exitCode = 1;
      return;
    }

    const resolvedPrdPath = isAbsolute(prdFile) ? resolve(prdFile) : resolve(projectPath, prdFile);
    if (!existsSync(resolvedPrdPath)) {
      console.error(chalk.red(`SLING-008: PRD file not found: ${resolvedPrdPath}`));
      process.exitCode = 1;
      return;
    }

    const prdContent = readFileSync(resolvedPrdPath, "utf-8");
    const readinessScore = parsePrdReadinessScore(prdContent);
    if (readinessScore !== null && readinessScore < MIN_PRD_READINESS_SCORE) {
      console.error(
        chalk.red(
          `SLING-009: PRD readiness score ${readinessScore.toFixed(1)} is below the minimum required score of ${MIN_PRD_READINESS_SCORE.toFixed(1)}.`,
        ),
      );
      process.exitCode = 1;
      return;
    }

    const trdOutputDir = join(projectPath, "docs", "TRD");
    const result = await runWithPiSdk({
      prompt: [
        `You are a planning agent running /ensemble:create-trd-foreman for ${resolvedPrdPath}`,
        "",
        `/ensemble:create-trd-foreman ${resolvedPrdPath}`,
        "",
        `Write outputs to ${trdOutputDir}.`,
      ].join("\n"),
      systemPrompt: `You are a planning agent running /ensemble:create-trd-foreman for ${resolvedPrdPath}.`,
      cwd: projectPath,
      model: "minimax/MiniMax-M2.7",
    });

    if (!result.success) {
      console.error(chalk.red(`SLING-010: TRD generation failed: ${result.errorMessage ?? "unknown error"}`));
      process.exitCode = 1;
      return;
    }

    const generatedTrdPath = findLatestGeneratedTrd(trdOutputDir);
    if (!generatedTrdPath) {
      console.error(chalk.red(`SLING-011: No generated TRD found in ${trdOutputDir}`));
      process.exitCode = 1;
      return;
    }

    await handleTrdImport(projectPath, generatedTrdPath, opts, { generatedTrdPath });
  });

export const slingCommand = new Command("sling")
  .description("Convert structured documents into task hierarchies")
  .addCommand(prdSubcommand)
  .addCommand(trdSubcommand);
