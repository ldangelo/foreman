import { Command } from "commander";
import chalk from "chalk";
import { mkdirSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

import { BeadsClient } from "../../lib/beads.js";
import { ForemanStore } from "../../lib/store.js";
import type { Run, RunProgress } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import type { ModelSelection } from "../../orchestrator/types.js";

export const runCommand = new Command("run")
  .description("Dispatch ready tasks to agents")
  .option("--max-agents <n>", "Maximum concurrent agents", "5")
  .option("--model <model>", "Force a specific model (claude-opus-4-6, claude-sonnet-4-6, claude-haiku-4-5-20251001)")
  .option("--dry-run", "Show what would be dispatched without doing it")
  .option("--no-watch", "Exit immediately after dispatching (don't monitor agents)")
  .option("--telemetry", "Enable OpenTelemetry tracing on spawned agents (requires OTEL_* env vars)")
  .option("--ralph", "Run in Ralph Wiggum loop: pick tasks from bd ready until none remain")
  .option("--max-iterations <n>", "Max Ralph loop iterations (default: unlimited)", "0")
  .action(async (opts) => {
    const maxAgents = parseInt(opts.maxAgents, 10);
    const model = opts.model as ModelSelection | undefined;
    const dryRun = opts.dryRun as boolean | undefined;
    const ralph = opts.ralph as boolean | undefined;
    const maxIterations = parseInt(opts.maxIterations, 10);
    const watch = opts.watch as boolean;
    const telemetry = opts.telemetry as boolean | undefined;

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
        model,
        dryRun,
        telemetry,
      });

      // Print dispatched tasks
      if (result.dispatched.length > 0) {
        console.log(chalk.green.bold(`Dispatched ${result.dispatched.length} task(s):\n`));
        for (const task of result.dispatched) {
          console.log(`  ${chalk.cyan(task.beadId)} ${task.title}`);
          console.log(`    Model:    ${chalk.magenta(task.model)}`);
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

      // Watch mode: poll agent status until all finish
      if (watch && !dryRun && result.dispatched.length > 0) {
        const runIds = result.dispatched.map((t) => t.runId);
        await watchRuns(store, runIds);
      }

      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });

// ── Watch / Progress ─────────────────────────────────────────────────────

const STATUS_ICON: Record<string, string> = {
  pending: chalk.dim("○"),
  running: chalk.blue("●"),
  completed: chalk.green("✓"),
  failed: chalk.red("✗"),
  stuck: chalk.yellow("⚠"),
  merged: chalk.green("⊕"),
  conflict: chalk.red("⊘"),
  "test-failed": chalk.red("⊘"),
};

function elapsed(since: string | null): string {
  if (!since) return "—";
  const ms = Date.now() - new Date(since).getTime();
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m${s % 60}s`;
  return `${Math.floor(m / 60)}h${m % 60}m`;
}

function formatProgress(progress: RunProgress | null): string {
  if (!progress || progress.toolCalls === 0) return chalk.dim("starting...");

  const parts: string[] = [];

  // Tool calls with top tools
  parts.push(chalk.white(`${progress.toolCalls} tools`));

  // Top 3 tools breakdown
  const topTools = Object.entries(progress.toolBreakdown)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 3)
    .map(([name, count]) => `${name}:${count}`);
  if (topTools.length > 0) {
    parts.push(chalk.dim(`(${topTools.join(" ")})`));
  }

  // Files changed
  if (progress.filesChanged.length > 0) {
    parts.push(chalk.yellow(`${progress.filesChanged.length} files`));
  }

  // Cost
  if (progress.costUsd > 0) {
    parts.push(chalk.green(`$${progress.costUsd.toFixed(3)}`));
  }

  // Last tool
  if (progress.lastToolCall) {
    parts.push(chalk.dim(`→ ${progress.lastToolCall}`));
  }

  return parts.join(" ");
}

async function watchRuns(store: ForemanStore, runIds: string[]): Promise<void> {
  console.log(chalk.dim("\nWatching agent progress (Ctrl+C to detach)...\n"));

  const POLL_MS = 3_000;
  let interrupted = false;
  let prevLineCount = 0;

  const onSigint = () => {
    interrupted = true;
    // Move past the table before printing
    if (prevLineCount > 0) {
      process.stdout.write(`\n${"\n".repeat(prevLineCount)}`);
    }
    console.log(chalk.dim("\n\nDetached — agents continue in background."));
    console.log(chalk.dim("Check status: foreman monitor\n"));
  };
  process.on("SIGINT", onSigint);

  try {
    while (!interrupted) {
      const runs = runIds
        .map((id) => store.getRun(id))
        .filter((r): r is Run => r !== null);

      if (runs.length === 0) break;

      const lines: string[] = [];
      let allDone = true;
      let totalCost = 0;
      let totalTools = 0;

      for (const run of runs) {
        const icon = STATUS_ICON[run.status] ?? chalk.dim("?");
        const progress = store.getRunProgress(run.id);

        if (progress) {
          totalCost += progress.costUsd;
          totalTools += progress.toolCalls;
        }

        const time = run.status === "running" || run.status === "pending"
          ? chalk.dim(elapsed(run.started_at ?? run.created_at))
          : chalk.dim(elapsed(run.started_at));

        const logHint = run.status === "failed"
          ? chalk.dim(` logs:~/.foreman/logs/${run.id}.log`)
          : "";

        // Line 1: status + bead + model + elapsed
        lines.push(
          `  ${icon} ${chalk.cyan(run.bead_id)} ${chalk.dim(`[${run.agent_type}]`)} ${time}${logHint}`,
        );

        // Line 2: progress details (indented under agent)
        if (run.status === "running" || run.status === "completed") {
          lines.push(`    ${formatProgress(progress)}`);
        }

        if (run.status === "pending" || run.status === "running") {
          allDone = false;
        }
      }

      // Summary line
      lines.push("");
      lines.push(
        chalk.dim(`  Total: ${totalTools} tool calls, $${totalCost.toFixed(3)}`),
      );

      // Move cursor up and overwrite (clear previous table)
      if (prevLineCount > 0) {
        process.stdout.write(`\x1b[${prevLineCount + 1}A`);
      }

      process.stdout.write(`\r\x1b[K${chalk.bold("Agent status:")}\n`);
      for (const line of lines) {
        process.stdout.write(`\x1b[K${line}\n`);
      }
      prevLineCount = lines.length;

      // Move cursor back up for next refresh
      process.stdout.write(`\x1b[${lines.length + 1}A`);

      if (allDone) {
        // Final render — move down past the table
        process.stdout.write(`\n${"\n".repeat(lines.length)}`);
        const completed = runs.filter((r) => r.status === "completed").length;
        const failed = runs.filter(
          (r) => r.status === "failed" || r.status === "test-failed",
        ).length;

        console.log(
          chalk.bold(
            `\nAll agents finished: ${chalk.green(`${completed} completed`)}, ${chalk.red(`${failed} failed`)}`,
          ),
        );
        console.log(
          chalk.dim(`  ${totalTools} tool calls, $${totalCost.toFixed(3)} total cost`),
        );
        break;
      }

      await new Promise((resolve) => setTimeout(resolve, POLL_MS));
    }
  } finally {
    process.removeListener("SIGINT", onSigint);
  }
}

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
