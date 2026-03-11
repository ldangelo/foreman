import { Command } from "commander";
import chalk from "chalk";
import { mkdirSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

import { BeadsClient } from "../../lib/beads.js";
import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import type { RuntimeSelection } from "../../orchestrator/types.js";

export const runCommand = new Command("run")
  .description("Dispatch ready tasks to agents")
  .option("--max-agents <n>", "Maximum concurrent agents", "5")
  .option("--runtime <type>", "Force a specific runtime (claude-code, pi, codex)")
  .option("--dry-run", "Show what would be dispatched without doing it")
  .option("--ralph", "Run in Ralph Wiggum loop: pick tasks from bd ready until none remain")
  .option("--max-iterations <n>", "Max Ralph loop iterations (default: unlimited)", "0")
  .action(async (opts) => {
    const maxAgents = parseInt(opts.maxAgents, 10);
    const runtime = opts.runtime as RuntimeSelection | undefined;
    const dryRun = opts.dryRun as boolean | undefined;
    const ralph = opts.ralph as boolean | undefined;
    const maxIterations = parseInt(opts.maxIterations, 10);

    if (ralph) {
      setupRalphLoop(maxIterations);
      return;
    }

    try {
      const projectPath = await getRepoRoot(process.cwd());
      const beads = new BeadsClient(projectPath);
      const store = new ForemanStore();
      const dispatcher = new Dispatcher(beads, store, projectPath);

      if (dryRun) {
        console.log(chalk.yellow("(dry run — no changes will be made)\n"));
      }

      const result = await dispatcher.dispatch({
        maxAgents,
        runtime,
        dryRun,
      });

      // Print dispatched tasks
      if (result.dispatched.length > 0) {
        console.log(chalk.green.bold(`Dispatched ${result.dispatched.length} task(s):\n`));
        for (const task of result.dispatched) {
          console.log(`  ${chalk.cyan(task.beadId)} ${task.title}`);
          console.log(`    Runtime:  ${chalk.magenta(task.runtime)}`);
          console.log(`    Branch:   ${task.branchName}`);
          console.log(`    Worktree: ${task.worktreePath}`);
          console.log(`    Run ID:   ${task.runId}`);
          console.log();
        }
      } else {
        console.log(chalk.yellow("No tasks dispatched."));
      }

      // Print skipped tasks
      if (result.skipped.length > 0) {
        console.log(chalk.dim(`Skipped ${result.skipped.length} task(s):`));
        for (const task of result.skipped) {
          console.log(`  ${chalk.dim(task.beadId)} ${chalk.dim(task.title)} — ${task.reason}`);
        }
        console.log();
      }

      console.log(chalk.bold(`Active agents: ${result.activeAgents}/${maxAgents}`));

      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });

/**
 * Set up a Ralph Wiggum loop that iterates over bd ready tasks.
 *
 * Creates the .claude/ralph-loop.local.md state file with a prompt that
 * instructs Claude to pick the next ready task, implement it, and close it.
 * The ralph-loop plugin's stop hook handles re-feeding the prompt each iteration.
 * The loop terminates when bd ready returns 0 tasks and the agent outputs
 * <promise>NO TASKS REMAINING</promise>.
 */
function setupRalphLoop(maxIterations: number): void {
  const completionPromise = "NO TASKS REMAINING";
  const startedAt = new Date().toISOString();
  const sessionId = process.env.CLAUDE_CODE_SESSION_ID ?? "";

  const prompt = `You are a foreman agent working through a beads task backlog.

## Instructions

1. Run \`bd ready --type task -n 1\` and \`bd ready --type chore -n 1\` to find the highest priority ready task
2. If NO tasks are returned, output <promise>${completionPromise}</promise> and stop
3. Pick the task and run \`bd update <id> --status=in_progress\`
4. Run \`bd show <id>\` to read the full description and dependencies
5. Implement the task:
   - Read relevant existing code first
   - Write the implementation with unit tests
   - Run the test suite to verify
6. When the task passes tests:
   - \`git add <files>\` (only files you changed)
   - \`git commit -m "<task title> (<task id>)"\`
   - \`bd close <id> --reason="Implemented and tested"\`
7. Done — the loop will feed this prompt again for the next task

## Rules

- Work on exactly ONE task per iteration
- Do NOT skip tasks or mark them done without implementing them
- If a task is blocked or impossible, close it with \`bd close <id> --reason="Blocked: <explanation>"\` and move to the next
- Keep commits focused — one commit per task
- Only output <promise>${completionPromise}</promise> when \`bd ready\` genuinely returns zero tasks`;

  const stateContent = `---
active: true
iteration: 1
session_id: ${sessionId}
max_iterations: ${maxIterations}
completion_promise: "${completionPromise}"
started_at: "${startedAt}"
---

${prompt}
`;

  mkdirSync(".claude", { recursive: true });
  writeFileSync(".claude/ralph-loop.local.md", stateContent, "utf-8");

  console.log(chalk.bold("🔄 Ralph Wiggum loop activated!\n"));
  console.log(`  Mode:               ${chalk.cyan("bd ready → implement → close → repeat")}`);
  console.log(`  Max iterations:     ${chalk.yellow(maxIterations > 0 ? String(maxIterations) : "unlimited")}`);
  console.log(`  Completion promise: ${chalk.green(completionPromise)}`);
  console.log(`  State file:         ${chalk.dim(".claude/ralph-loop.local.md")}\n`);
  console.log(chalk.dim("The stop hook will keep feeding the prompt until bd ready returns 0 tasks."));
  console.log(chalk.dim("Monitor progress: bd stats\n"));

  // Find Claude CLI
  const claudePath = process.env.CLAUDE_PATH || "/opt/homebrew/bin/claude";

  // Spawn Claude interactively with the prompt.
  // The ralph-loop stop hook intercepts session exit and re-feeds the prompt.
  // stdio: "inherit" gives Claude full terminal control (interactive mode).
  // Strip CLAUDECODE env var to allow spawning Claude from within a Claude session
  const cleanEnv: Record<string, string | undefined> = { ...process.env, PATH: `/opt/homebrew/bin:${process.env.PATH}` };
  delete cleanEnv.CLAUDECODE;

  const result = spawnSync(claudePath, [
    "--permission-mode", "bypassPermissions",
    prompt,
  ], {
    cwd: process.cwd(),
    stdio: "inherit",
    env: cleanEnv,
  });

  // Exit with Claude's exit code
  process.exit(result.status ?? 0);
}
