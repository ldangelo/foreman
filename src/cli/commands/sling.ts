import { Command } from "commander";
import chalk from "chalk";
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { parseTrd } from "../../orchestrator/trd-parser.js";
import { analyzeParallel } from "../../orchestrator/sprint-parallel.js";
import { execute } from "../../orchestrator/sling-executor.js";
import { runWithPiSdk } from "../../orchestrator/pi-sdk-runner.js";
import { PLAN_STEP_CONFIG } from "../../orchestrator/roles.js";
import { ForemanStore } from "../../lib/store.js";
import { NativeTaskStore, type CreateTaskOptions, type TaskRow, type UpdateTaskOptions } from "../../lib/task-store.js";
import type { SlingPlan, SlingOptions, SlingResult, ParallelResult } from "../../orchestrator/types.js";
import { resolveProjectPathFromOption } from "./project-task-support.js";

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

function resolveSlingProjectPath(opts: SlingTargetingOptions): string | null {
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

  if (opts.project && isAbsolute(opts.project)) {
    console.warn(
      chalk.yellow("`--project` with an absolute path is deprecated; use `--project-path` instead."),
    );
    return opts.project;
  }

  return resolveProjectPathFromOption(opts.project);
}

export function shouldAnnounceNativeTaskMigration(projectPath: string): boolean {
  const dbPath = join(projectPath, ".foreman", "foreman.db");
  if (!existsSync(dbPath)) {
    return false;
  }

  try {
    const db = ForemanStore.openReadonly(projectPath);
    try {
      const row = db
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'tasks'")
        .get() as { name: string } | undefined;
      return !row;
    } finally {
      db.close();
    }
  } catch {
    return false;
  }
}

function openNativeTaskStore(projectPath: string): { store: ForemanStore; taskStore: NativeTaskStore } {
  if (shouldAnnounceNativeTaskMigration(projectPath)) {
    console.log(chalk.dim("Migrating task store to native format..."));
  }

  const store = ForemanStore.forProject(projectPath);
  return {
    store,
    taskStore: new NativeTaskStore(store.getDb()),
  };
}

class ReadyLeafTaskStore extends NativeTaskStore {
  override create(opts: CreateTaskOptions): TaskRow {
    const row = super.create(opts);
    if (row.type === "task" || row.type === "chore") {
      this.approve(row.id);
      return this.get(row.id) ?? row;
    }
    return row;
  }

  override update(id: string, opts: UpdateTaskOptions): TaskRow {
    const row = super.update(id, opts);
    if ((row.type === "task" || row.type === "chore") && row.status === "backlog") {
      this.approve(row.id);
      return this.get(row.id) ?? row;
    }
    return row;
  }
}

export function parsePrdReadinessScore(content: string): number | null {
  const patterns = [
    /^\s*(?:[-*]\s*)?\*\*Readiness Score:\*\*\s*([0-9]+(?:\.[0-9]+)?)/im,
    /^\s*Readiness Score:\s*([0-9]+(?:\.[0-9]+)?)/im,
    /^\s*readiness_score:\s*([0-9]+(?:\.[0-9]+)?)/im,
  ];

  for (const pattern of patterns) {
    const match = content.match(pattern);
    if (match) {
      return parseFloat(match[1]);
    }
  }

  return null;
}

function resolveTrdOutputDir(prdPath: string): string {
  const prdDir = dirname(prdPath);
  if (prdDir.includes(`${join("docs", "PRD")}`)) {
    return prdDir.replace(`${join("docs", "PRD")}`, join("docs", "TRD"));
  }
  return prdDir;
}

function findNewestMarkdownFile(dir: string, prefix: string, startedAtMs: number): string | null {
  if (!existsSync(dir)) return null;

  const candidates = readdirSync(dir)
    .filter((name) => name.endsWith(".md") && name.startsWith(prefix))
    .map((name) => {
      const fullPath = join(dir, name);
      return { fullPath, mtimeMs: statSync(fullPath).mtimeMs };
    })
    .filter((entry) => entry.mtimeMs >= startedAtMs - 1_000)
    .sort((a, b) => b.mtimeMs - a.mtimeMs);

  return candidates[0]?.fullPath ?? null;
}

async function generateForemanTrd(
  projectPath: string,
  prdPath: string,
  outputDir: string,
): Promise<string> {
  const startedAt = Date.now();
  const prompt = `/ensemble:create-trd-foreman ${prdPath}\n\nWrite outputs to ${outputDir}/.`;
  const result = await runWithPiSdk({
    prompt,
    systemPrompt: `You are a planning agent running /ensemble:create-trd-foreman for ${prdPath}`,
    cwd: projectPath,
    model: PLAN_STEP_CONFIG.model,
  });

  if (!result.success) {
    throw new Error(result.errorMessage ?? "create-trd-foreman failed");
  }

  const generated = findNewestMarkdownFile(outputDir, "TRD", startedAt);
  if (!generated) {
    throw new Error(`SLING-008: create-trd-foreman did not produce a TRD in ${outputDir}`);
  }

  return generated;
}

async function executeSlingPlan(
  plan: SlingPlan,
  parallel: ParallelResult,
  slingOptions: SlingOptions,
  taskStore: NativeTaskStore,
): Promise<SlingResult> {
  const spinner = createProgressSpinner();
  try {
    const result = await execute(
      plan,
      parallel,
      slingOptions,
      taskStore,
      spinner.update,
    );
    printSummary(result);
    return result;
  } finally {
    spinner.finish();
  }
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
  .action(async (trdFile: string, opts: Record<string, boolean | string | undefined>) => {
    const projectPath = resolveSlingProjectPath({
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

    const content = readFileSync(resolved, "utf-8");
    const lines = content.split("\n").length;
    if (!opts.json) {
      console.log(chalk.dim(`Reading TRD: ${resolved} (${lines} lines)\n`));
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
      const output = {
        epic: plan.epic,
        sprints: plan.sprints,
        parallel: parallel.groups,
        warnings: parallel.warnings,
        acceptanceCriteria: Object.fromEntries(plan.acceptanceCriteria),
        riskMap: Object.fromEntries(plan.riskMap),
      };
      console.log(JSON.stringify(output, null, 2));
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

    const { store, taskStore } = openNativeTaskStore(projectPath);
    try {
      await executeSlingPlan(plan, parallel, slingOptions, taskStore);
    } finally {
      store.close();
    }
  });

const prdSubcommand = new Command("prd")
  .description("Generate a Foreman-native TRD from a PRD and create ready native tasks")
  .argument("<prd-file>", "Path to PRD markdown file")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path for advanced/scripted usage")
  .option("--output-dir <dir>", "Directory for the generated TRD (default: infer from PRD path)")
  .option("--dry-run", "Generate and preview the resulting task hierarchy without creating tasks")
  .option("--auto", "Skip confirmation prompt")
  .option("--json", "Output parsed structure as JSON")
  .option("--force", "Refresh matching native tasks even if trd:<ID> already exists")
  .option("--no-parallel", "Disable parallel sprint detection")
  .option("--no-risks", "Skip risk register parsing")
  .option("--no-quality", "Skip quality requirements parsing")
  .action(async (prdFile: string, opts: Record<string, boolean | string | undefined>) => {
    const projectPath = resolveSlingProjectPath({
      project: typeof opts.project === "string" ? opts.project : undefined,
      projectPath: typeof opts.projectPath === "string" ? opts.projectPath : undefined,
    });
    if (!projectPath) {
      process.exitCode = 1;
      return;
    }

    const resolvedPrd = isAbsolute(prdFile) ? resolve(prdFile) : resolve(projectPath, prdFile);
    if (!existsSync(resolvedPrd)) {
      console.error(chalk.red(`SLING-001: PRD file not found: ${resolvedPrd}`));
      process.exitCode = 1;
      return;
    }

    const prdContent = readFileSync(resolvedPrd, "utf-8");
    const readinessScore = parsePrdReadinessScore(prdContent);
    if (readinessScore !== null && readinessScore < 3.5) {
      console.error(
        chalk.red(
          `SLING-009: PRD readiness score ${readinessScore.toFixed(1)} is below 3.5. Run /ensemble:refine-prd before sling prd.`,
        ),
      );
      process.exitCode = 1;
      return;
    }
    if (readinessScore !== null && readinessScore < 4.0) {
      console.warn(
        chalk.yellow(
          `SLING-WARN: PRD readiness score ${readinessScore.toFixed(1)} has concerns. Proceeding with caution.`,
        ),
      );
    } else if (readinessScore === null) {
      if (!opts.json) {
        console.log(chalk.dim("No PRD readiness score found — proceeding without gate metadata."));
      }
    }

    const outputDir = typeof opts.outputDir === "string"
      ? (isAbsolute(opts.outputDir) ? resolve(opts.outputDir) : resolve(projectPath, opts.outputDir))
      : resolveTrdOutputDir(resolvedPrd);

    if (!opts.json) {
      console.log(chalk.dim(`Reading PRD: ${resolvedPrd}`));
      console.log(chalk.dim(`Generating Foreman-native TRD in: ${outputDir}\n`));
    }

    let generatedTrdPath: string;
    try {
      generatedTrdPath = await generateForemanTrd(projectPath, resolvedPrd, outputDir);
    } catch (err: unknown) {
      console.error(chalk.red((err as Error).message));
      process.exitCode = 1;
      return;
    }

    const content = readFileSync(generatedTrdPath, "utf-8");
    if (!opts.json) {
      console.log(chalk.dim(`Generated TRD: ${generatedTrdPath} (${content.split("\n").length} lines)\n`));
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
        generatedTrdPath,
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

    if (opts.dryRun) {
      console.log(chalk.dim("Dry run — generated TRD parsed successfully; no native tasks created."));
      return;
    }

    if (!opts.auto) {
      const answer = await new Promise<string>((resolveAnswer) => {
        const rl = createInterface({ input: process.stdin, output: process.stdout });
        rl.question(
          chalk.bold("Generate the TRD and create ready native tasks? [y/N] "),
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
      sdOnly: false,
      brOnly: false,
      skipCompleted: false,
      closeCompleted: false,
      noParallel: opts.parallel === false,
      force: !!opts.force,
      noRisks: opts.risks === false,
      noQuality: opts.quality === false,
    };

    const { store } = openNativeTaskStore(projectPath);
    const readyTaskStore = new ReadyLeafTaskStore(store.getDb());
    try {
      const result = await executeSlingPlan(plan, parallel, slingOptions, readyTaskStore);
      if (result.native.failed === 0) {
        console.log(chalk.green(`\nNext step: foreman run --project-path ${projectPath}`));
      }
    } finally {
      store.close();
    }
  });

export const slingCommand = new Command("sling")
  .description("Convert structured documents into task hierarchies")
  .addCommand(trdSubcommand)
  .addCommand(prdSubcommand);
