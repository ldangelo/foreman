import { Command } from "commander";
import chalk from "chalk";
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { decomposePrd } from "../../orchestrator/decomposer.js";
import { decomposePrdWithLlm } from "../../orchestrator/decomposer-llm.js";
import { executePlan } from "../../orchestrator/planner.js";
import { BeadsRustClient } from "../../lib/beads-rust.js";
import type { DecompositionPlan, TaskPlan } from "../../orchestrator/types.js";

export const decomposeCommand = new Command("decompose")
  .description("Decompose a TRD into beads hierarchy (epic → sprint → story → task)")
  .argument("<trd>", "Path to TRD file")
  .option("--no-auto", "Prompt for confirmation before creating seeds")
  .option("--dry-run", "Show the plan without creating seeds")
  .option("--no-llm", "Use heuristic decomposition instead of LLM")
  .option("--model <model>", "Model to use for LLM decomposition")
  .action(async (trd: string, opts: { auto?: boolean; dryRun?: boolean; llm?: boolean; model?: string }) => {
    let content: string;

    // Check if it's a file path
    const resolved = resolve(trd);
    if (existsSync(resolved)) {
      content = readFileSync(resolved, "utf-8");
      console.log(chalk.dim(`Reading TRD from: ${resolved}`));
    } else {
      console.error(chalk.red(`TRD file not found: ${resolved}`));
      console.log(chalk.dim("Run 'foreman plan' first to generate a PRD → TRD pipeline."));
      process.exitCode = 1;
      return;
    }

    const lines = content.split("\n").length;
    const chars = content.length;
    console.log(
      chalk.dim(`TRD summary: ${lines} lines, ${chars} characters\n`),
    );

    // Decompose
    const mode = opts.llm ? "LLM" : "heuristic";
    console.log(chalk.bold(`Decomposing TRD into hierarchy... ${chalk.dim(`(${mode} mode)`)}`));
    let plan: DecompositionPlan;
    try {
      if (opts.llm) {
        plan = await decomposePrdWithLlm(content, opts.model);
      } else {
        plan = await decomposePrd(content, process.cwd());
      }
    } catch (err: any) {
      console.error(chalk.red(`Decomposition failed: ${err.message}`));
      process.exitCode = 1;
      return;
    }

    // Display the plan
    printPlan(plan);

    if (opts.dryRun) {
      console.log(chalk.yellow("\n--dry-run: No seeds created."));
      return;
    }

    // Confirmation gate
    if (!opts.auto) {
      const ok = await confirm("Create these seeds?");
      if (!ok) {
        console.log(chalk.yellow("Aborted."));
        return;
      }
    }

    // Execute
    console.log(chalk.bold("\nCreating beads hierarchy..."));
    const seeds = new BeadsRustClient(process.cwd());
    try {
      const result = await executePlan(plan, seeds);
      console.log(chalk.green(`\nEpic created: ${result.epicSeedId}`));
      console.log(chalk.green(`Sprints created: ${result.sprintSeedIds.length}`));
      console.log(chalk.green(`Stories created: ${result.storySeedIds.length}`));
      console.log(chalk.green(`Tasks created: ${result.taskSeedIds.length}`));
      for (const id of result.taskSeedIds) {
        console.log(chalk.dim(`  - ${id}`));
      }
    } catch (err: any) {
      console.error(chalk.red(`Failed to create seeds: ${err.message}`));
      process.exitCode = 1;
    }
  });

// ── Display helpers ─────────────────────────────────────────────────────

function printPlan(plan: DecompositionPlan): void {
  console.log(chalk.bold.cyan(`\nEpic: ${plan.epic.title}`));
  console.log(chalk.dim(plan.epic.description));

  let totalTasks = 0;
  for (const sprint of plan.sprints) {
    for (const story of sprint.stories) {
      totalTasks += story.tasks.length;
    }
  }

  console.log(chalk.bold(`\n${plan.sprints.length} sprint(s), ${totalTasks} task(s):\n`));

  for (const sprint of plan.sprints) {
    console.log(chalk.bold.magenta(`  ${sprint.title}`));
    console.log(chalk.dim(`  Goal: ${sprint.goal}`));

    for (const story of sprint.stories) {
      const priority = priorityBadge(story.priority);
      console.log(`\n    ${priority} ${chalk.bold(story.title)}`);

      for (let i = 0; i < story.tasks.length; i++) {
        const task = story.tasks[i];
        const complexity = complexityBadge(task.estimatedComplexity);
        const typeBadge = task.type !== "task" ? chalk.cyan(` [${task.type}]`) : "";

        console.log(`      ${complexity} ${task.title}${typeBadge}`);
        if (task.dependencies.length > 0) {
          console.log(
            chalk.dim(`         deps: ${task.dependencies.join(", ")}`),
          );
        }
      }
    }
    console.log();
  }
}

function priorityBadge(p: string): string {
  switch (p) {
    case "critical":
      return chalk.bgRed.white(" CRIT ");
    case "high":
      return chalk.bgYellow.black(" HIGH ");
    case "medium":
      return chalk.bgBlue.white(" MED  ");
    case "low":
      return chalk.bgGray.white(" LOW  ");
    default:
      return chalk.dim(" ???  ");
  }
}

function complexityBadge(c: string): string {
  switch (c) {
    case "high":
      return chalk.red("■■■");
    case "medium":
      return chalk.yellow("■■□");
    case "low":
      return chalk.green("■□□");
    default:
      return chalk.dim("□□□");
  }
}

async function confirm(message: string): Promise<boolean> {
  const { createInterface } = await import("node:readline");
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(`${message} [y/N] `, (answer) => {
      rl.close();
      resolve(answer.toLowerCase() === "y" || answer.toLowerCase() === "yes");
    });
  });
}
