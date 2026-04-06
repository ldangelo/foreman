import { Command } from "commander";
import chalk from "chalk";
import { readFileSync, existsSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import { createInterface } from "node:readline";
import { parseTrd } from "../../orchestrator/trd-parser.js";
import { analyzeParallel } from "../../orchestrator/sprint-parallel.js";
import { execute } from "../../orchestrator/sling-executor.js";
import { BeadsRustClient } from "../../lib/beads-rust.js";
import type { SlingPlan, SlingOptions, SlingResult, ParallelResult } from "../../orchestrator/types.js";
import { resolveProjectPathFromOption } from "./project-task-support.js";

// ── TRD-021: --sd-only deprecation helper (exported for testing) ─────────

/**
 * Checks if --sd-only is set; if so, prints a deprecation warning to stderr
 * and clears the flag so the command behaves as br-only.
 *
 * Returns true if the warning was emitted (flag was set), false otherwise.
 */
/**
 * TRD-022: br-only is now the default write target.
 * When neither --sd-only nor --br-only is specified, br-only is used.
 * --br-only flag is retained but is now a no-op (already the default).
 *
 * Exported for testing.
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
      "Foreman now uses br (beads_rust) exclusively. The flag is ignored.\n",
    ),
  );
  opts.sdOnly = false;
  opts.brOnly = true; // enforce br-only to match the deprecation message's promise
  return true;
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

  // Build parallel group lookup: sprintIndex → group label
  const sprintToGroup = new Map<number, string>();
  for (const group of parallel.groups) {
    for (const idx of group.sprintIndices) {
      sprintToGroup.set(idx, group.label);
    }
  }

  for (let si = 0; si < plan.sprints.length; si++) {
    const sprint = plan.sprints[si];
    const sprintTasks = sprint.stories.reduce((sum, st) => sum + st.tasks.length, 0);
    const sprintHours = sprint.stories.reduce(
      (sum, st) => sum + st.tasks.reduce((ts, t) => ts + t.estimateHours, 0),
      0,
    );
    const groupLabel = sprintToGroup.get(si);
    const prefix = groupLabel ? chalk.cyan(`║ `) : "  ";
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

  // Parallel groups summary
  if (parallel.groups.length > 0) {
    console.log(chalk.bold("Parallel Groups:"));
    for (const group of parallel.groups) {
      const sprintNames = group.sprintIndices
        .map((i) => plan.sprints[i].title)
        .join(", ");
      console.log(`  ${chalk.cyan(group.label)}: ${sprintNames}`);
    }
    console.log();
  }

  // Warnings
  if (parallel.warnings.length > 0) {
    console.log(chalk.yellow("Parallelization warnings:"));
    for (const w of parallel.warnings) {
      console.log(chalk.yellow(`  ⚠ ${w}`));
    }
    console.log();
  }
}

function printSummary(result: SlingResult): void {
  const parts: string[] = [];
  if (result.sd) {
    parts.push(`sd: ${result.sd.created} created, ${result.sd.skipped} skipped, ${result.sd.failed} failed`);
  }
  if (result.br) {
    parts.push(`br: ${result.br.created} created, ${result.br.skipped} skipped, ${result.br.failed} failed`);
  }
  console.log(chalk.bold(`\nSummary: ${parts.join(" | ")}`));

  if (result.depErrors.length > 0) {
    console.log(chalk.yellow(`\nDependency warnings (${result.depErrors.length}):`));
    for (const err of result.depErrors.slice(0, 10)) {
      console.log(chalk.yellow(`  ⚠ ${err}`));
    }
    if (result.depErrors.length > 10) {
      console.log(chalk.dim(`  ... and ${result.depErrors.length - 10} more`));
    }
  }

  const allErrors = [
    ...(result.sd?.errors ?? []),
    ...(result.br?.errors ?? []),
  ].filter((e) => !e.includes("SLING-007"));
  if (allErrors.length > 0) {
    console.log(chalk.red(`\nErrors (${allErrors.length}):`));
    for (const err of allErrors) {
      console.log(chalk.red(`  ✗ ${err}`));
    }
  }
}

// ── Progress spinner ─────────────────────────────────────────────────────

function createProgressSpinner() {
  let sdCount = 0;
  let brCount = 0;

  return {
    update(created: number, total: number, tracker: "sd" | "br") {
      if (tracker === "sd") sdCount = created;
      else brCount = created;

      const totalCreated = sdCount + brCount;
      const line = `Creating tasks... ${totalCreated} (sd: ${sdCount}, br: ${brCount})`;
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
  .description("Convert a TRD into task hierarchies in sd and br")
  .argument("<trd-file>", "Path to TRD markdown file")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path for advanced/scripted usage")
  .option("--dry-run", "Preview without creating tasks")
  .option("--auto", "Skip confirmation prompt")
  .option("--json", "Output parsed structure as JSON")
  .option("--sd-only", "Write to beads_rust (br) only (deprecated, use --br-only)")
  .option("--br-only", "Write to beads_rust (br) only")
  .option("--skip-completed", "Skip [x] tasks (not created)")
  .option("--close-completed", "Create [x] tasks and immediately close them")
  .option("--no-parallel", "Disable parallel sprint detection")
  .option("--force", "Recreate tasks even if trd:<ID> labels already exist")
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

    // Read TRD file
    const resolved = isAbsolute(trdFile) ? resolve(trdFile) : resolve(projectPath, trdFile);
    if (!existsSync(resolved)) {
      console.error(chalk.red(`SLING-001: TRD file not found: ${resolved}`));
      process.exitCode = 1;
      return;
    }

    const content = readFileSync(resolved, "utf-8");
    const lines = content.split("\n").length;
    console.log(chalk.dim(`Reading TRD: ${resolved} (${lines} lines)\n`));

    // Parse
    let plan: SlingPlan;
    try {
      plan = parseTrd(content);
    } catch (err: unknown) {
      console.error(chalk.red((err as Error).message));
      process.exitCode = 1;
      return;
    }

    // Analyze parallelization
    const parallel = opts.parallel === false
      ? { groups: [], warnings: [] } as ParallelResult
      : analyzeParallel(plan, content);

    // JSON output
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

    // Preview
    printSlingPlan(plan, parallel);

    // Dry run?
    if (opts.dryRun) {
      console.log(chalk.dim("Dry run — no tasks created."));
      return;
    }

    // --sd-only is deprecated: warn and treat as no-op (br-only write)
    applySdOnlyDeprecation(opts);

    // TRD-022: br-only is the default when neither flag is set
    resolveDefaultBrOnly(opts);

    // Confirmation
    if (!opts.auto) {
      const targets: string[] = [];
      if (!opts.brOnly) targets.push("sd (beads)");
      if (!opts.sdOnly) targets.push("br (beads_rust)");

      const answer = await new Promise<string>((resolve) => {
        const rl = createInterface({ input: process.stdin, output: process.stdout });
        rl.question(
          chalk.bold(`Create in ${targets.join(" + ")}? [y/N] `),
          (ans) => {
            rl.close();
            resolve(ans);
          },
        );
      });
      if (answer.toLowerCase() !== "y") {
        console.log(chalk.dim("Aborted."));
        return;
      }
    }

    // Build options
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

    // Detect available trackers
    const seeds = null;
    let beadsRust: BeadsRustClient | null = null;

    if (!slingOptions.sdOnly) {
      try {
        beadsRust = new BeadsRustClient(projectPath);
        await beadsRust.ensureBrInstalled();
      } catch {
        console.warn(chalk.yellow("SLING-004: br CLI not available — skipping beads_rust creation"));
        beadsRust = null;
      }
    }

    if (!beadsRust) {
      console.error(chalk.red("SLING-005: br CLI not available. Cannot create tasks."));
      process.exitCode = 1;
      return;
    }

    const spinner = createProgressSpinner();
    const result = await execute(
      plan,
      parallel,
      slingOptions,
      seeds,
      beadsRust,
      spinner.update,
    );
    spinner.finish();

    // Summary
    printSummary(result);
  });

export const slingCommand = new Command("sling")
  .description("Convert structured documents into task hierarchies")
  .addCommand(trdSubcommand);
