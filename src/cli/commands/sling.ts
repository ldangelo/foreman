import { Command } from "commander";
import chalk from "chalk";
import { readFileSync, existsSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { parseTrd } from "../../orchestrator/trd-parser.js";
import { analyzeParallel } from "../../orchestrator/sprint-parallel.js";
import { execute } from "../../orchestrator/sling-executor.js";
import { ForemanStore } from "../../lib/store.js";
import { NativeTaskStore } from "../../lib/task-store.js";
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
    console.log(chalk.dim(`Reading TRD: ${resolved} (${lines} lines)\n`));

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
      const spinner = createProgressSpinner();
      const result = await execute(
        plan,
        parallel,
        slingOptions,
        taskStore,
        spinner.update,
      );
      spinner.finish();
      printSummary(result);
    } finally {
      store.close();
    }
  });

export const slingCommand = new Command("sling")
  .description("Convert structured documents into task hierarchies")
  .addCommand(trdSubcommand);
