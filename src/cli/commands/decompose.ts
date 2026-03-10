import { Command } from "commander";
import chalk from "chalk";
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { decomposePrd } from "../../orchestrator/decomposer.js";
import { executePlan } from "../../orchestrator/planner.js";
import { BeadsClient } from "../../lib/beads.js";
import type { DecompositionPlan, TaskPlan } from "../../orchestrator/types.js";

export const decomposeCommand = new Command("decompose")
  .description("Decompose a TRD into beads task hierarchy")
  .argument("<trd>", "Path to TRD file")
  .option("--auto", "Skip confirmation and create beads immediately")
  .option("--dry-run", "Show the plan without creating beads")
  .action(async (trd: string, opts: { auto?: boolean; dryRun?: boolean }) => {
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
    console.log(chalk.bold("Decomposing TRD into tasks..."));
    let plan: DecompositionPlan;
    try {
      plan = await decomposePrd(content, process.cwd());
    } catch (err: any) {
      console.error(chalk.red(`Decomposition failed: ${err.message}`));
      process.exitCode = 1;
      return;
    }

    // Display the plan
    printPlan(plan);

    if (opts.dryRun) {
      console.log(chalk.yellow("\n--dry-run: No beads created."));
      return;
    }

    // Confirmation gate
    if (!opts.auto) {
      const ok = await confirm("Create these beads?");
      if (!ok) {
        console.log(chalk.yellow("Aborted."));
        return;
      }
    }

    // Execute
    console.log(chalk.bold("\nCreating beads..."));
    const beads = new BeadsClient(process.cwd());
    try {
      const result = await executePlan(plan, beads);
      console.log(chalk.green(`\nEpic created: ${result.epicBeadId}`));
      console.log(
        chalk.green(`Tasks created: ${result.taskBeadIds.length} beads`),
      );
      for (const id of result.taskBeadIds) {
        console.log(chalk.dim(`  - ${id}`));
      }
    } catch (err: any) {
      console.error(chalk.red(`Failed to create beads: ${err.message}`));
      process.exitCode = 1;
    }
  });

// ── Display helpers ─────────────────────────────────────────────────────

function printPlan(plan: DecompositionPlan): void {
  console.log(chalk.bold.cyan(`\nEpic: ${plan.epic.title}`));
  console.log(chalk.dim(plan.epic.description));
  console.log(chalk.bold(`\nTasks (${plan.tasks.length}):`));

  for (let i = 0; i < plan.tasks.length; i++) {
    const task = plan.tasks[i];
    const num = `${i + 1}.`.padStart(3);
    const complexity = complexityBadge(task.estimatedComplexity);
    const priority = priorityBadge(task.priority);

    console.log(`${num} ${priority} ${complexity} ${task.title}`);
    if (task.description) {
      const desc =
        task.description.length > 80
          ? task.description.slice(0, 77) + "..."
          : task.description;
      console.log(chalk.dim(`      ${desc}`));
    }
    if (task.dependencies.length > 0) {
      console.log(
        chalk.dim(`      deps: ${task.dependencies.join(", ")}`),
      );
    }
  }
}

function priorityBadge(p: TaskPlan["priority"]): string {
  switch (p) {
    case "critical":
      return chalk.bgRed.white(" CRIT ");
    case "high":
      return chalk.bgYellow.black(" HIGH ");
    case "medium":
      return chalk.bgBlue.white(" MED  ");
    case "low":
      return chalk.bgGray.white(" LOW  ");
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
