import { Command } from "commander";
import chalk from "chalk";

import { BeadsRustClient } from "../../lib/beads-rust.js";
import { resolveRepoRootProjectPath } from "./project-task-support.js";
import { ForemanStore } from "../../lib/store.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import type { ModelSelection } from "../../orchestrator/types.js";

// ── Types ─────────────────────────────────────────────────────────────

export interface RetryOpts {
  dispatch?: boolean;
  model?: ModelSelection;
  dryRun?: boolean;
}

// ── Core action (exported for testing) ───────────────────────────────

/**
 * Core retry logic extracted for testability.
 * Returns the exit code (0 = success, 1 = error).
 */
export async function retryAction(
  beadId: string,
  opts: RetryOpts,
  beadsClient: BeadsRustClient,
  store: ForemanStore,
  projectPath: string,
  dispatcher?: Dispatcher,
): Promise<number> {
  const dryRun = opts.dryRun ?? false;

  if (dryRun) {
    console.log(chalk.yellow("(dry run — no changes will be made)\n"));
  }

  // 1. Validate project exists
  const project = store.getProjectByPath(projectPath);
  if (!project) {
    console.error(
      chalk.red("No project registered for this path. Run 'foreman init' first."),
    );
    return 1;
  }

  // 2. Look up bead via BeadsRustClient
  let bead: Awaited<ReturnType<typeof beadsClient.show>>;
  try {
    bead = await beadsClient.show(beadId);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(chalk.red(`Bead "${beadId}" not found: ${msg}`));
    return 1;
  }

  console.log(
    chalk.bold(
      `${dryRun ? "Previewing retry plan for bead" : "Retrying bead"}: ${chalk.cyan(bead.id)}`
    ) + chalk.dim(` (${bead.title})`),
  );
  console.log(`  Status: ${chalk.yellow(bead.status)}`);

  const runs = store.getRunsForSeed(beadId, project.id);
  const latestRun = runs.length > 0 ? runs[0] : null;

  if (latestRun) {
    console.log(
      `  Latest run: ${chalk.dim(latestRun.id)} status=${latestRun.status}`,
    );
  } else {
    console.log(`  Latest run: ${chalk.dim("(none)")}`);
  }

  const beadNeedsReset =
    bead.status === "completed" ||
    bead.status === "closed" ||
    bead.status === "in_progress" ||
    bead.status === "blocked";

  const runNeedsReset =
    latestRun !== null &&
    (latestRun.status === "stuck" ||
      latestRun.status === "running" ||
      latestRun.status === "pending" ||
      latestRun.status === "failed");

  const runNeedsExplicitReset =
    latestRun !== null &&
    (latestRun.status === "completed" ||
      latestRun.status === "merged" ||
      latestRun.status === "pr-created" ||
      latestRun.status === "conflict" ||
      latestRun.status === "test-failed");

  const wouldChangeState = beadNeedsReset || runNeedsReset || runNeedsExplicitReset;
  let changedState = false;

  if (!dryRun) {
    if (beadNeedsReset) {
      console.log(
        `  ${chalk.yellow("reset")} bead status: ${bead.status} → open`,
      );
      await beadsClient.update(beadId, { status: "open" });
      changedState = true;
    } else if (bead.status !== "open") {
      console.log(
        `  ${chalk.dim("skip")} bead status already: ${bead.status}`,
      );
    } else {
      console.log(`  ${chalk.dim("ok")} bead status is already "open"`);
    }

    if (runNeedsReset && latestRun) {
      console.log(
        `  ${chalk.yellow("reset")} run ${latestRun.id}: ${latestRun.status} → failed`,
      );
      store.updateRun(latestRun.id, {
        status: "failed",
        completed_at: new Date().toISOString(),
      });
      store.logEvent(
        project.id,
        "restart",
        { reason: "foreman retry", beadId, previousRunId: latestRun.id },
        latestRun.id,
      );
      changedState = true;
    } else if (runNeedsExplicitReset && latestRun) {
      console.log(
        `  ${chalk.yellow("reset")} run ${latestRun.id}: ${latestRun.status} → reset`,
      );
      store.updateRun(latestRun.id, {
        status: "reset",
        completed_at: new Date().toISOString(),
      });
      store.logEvent(
        project.id,
        "restart",
        { reason: "foreman retry", beadId, previousRunId: latestRun.id },
        latestRun.id,
      );
      changedState = true;
    } else if (latestRun) {
      console.log(
        `  ${chalk.dim("skip")} run status "${latestRun.status}" does not need reset`,
      );
    }
  } else {
    if (beadNeedsReset) {
      console.log(
        chalk.dim(
          `  Would reset bead status: ${bead.status} → open`,
        ),
      );
    }

    if (runNeedsReset && latestRun) {
      console.log(
        chalk.dim(
          `  Would reset run ${latestRun.id}: ${latestRun.status} → failed`,
        ),
      );
    }

    if (runNeedsExplicitReset && latestRun) {
      console.log(
        chalk.dim(
          `  Would reset run ${latestRun.id}: ${latestRun.status} → reset`,
        ),
      );
    }

    if (!wouldChangeState && !opts.dispatch) {
      console.log(chalk.dim("  Would not change bead or run state."));
    }
  }

  let dispatchRequestedButNotStarted = false;

  if (opts.dispatch) {
    console.log();
    console.log(chalk.bold(dryRun ? "Previewing dispatch…" : "Dispatching…"));
    const disp =
      dispatcher ?? new Dispatcher(beadsClient, store, projectPath);
    const result = await disp.dispatch({
      maxAgents: 1,
      model: opts.model,
      seedId: beadId,
      dryRun,
    });

    dispatchRequestedButNotStarted =
      result.dispatched.length === 0 && result.resumed.length === 0;

    for (const task of result.dispatched) {
      console.log(
        `  ${chalk.green(dryRun ? "would dispatch" : "dispatched")} ${task.seedId} → worktree ${task.worktreePath}`,
      );
    }

    for (const task of result.resumed) {
      console.log(
        `  ${chalk.green(dryRun ? "would resume" : "resumed")} ${task.seedId} → run ${task.runId}`,
      );
    }

    const skippedWriter = dryRun ? console.log : console.warn;
    for (const skipped of result.skipped) {
      skippedWriter(
        `  ${chalk.yellow(dryRun ? "would skip" : "skipped")} ${skipped.seedId}: ${skipped.reason}`,
      );
    }

    if (dispatchRequestedButNotStarted && result.skipped.length === 0) {
      const message = dryRun
        ? "  would not dispatch a new run"
        : changedState
          ? "  reset state, but did not dispatch a new run"
          : "  did not dispatch a new run";
      const writer = dryRun ? console.log : console.error;
      writer(chalk.yellow(message));
    }
  }

  console.log();
  if (dryRun) {
    if (!wouldChangeState && !opts.dispatch) {
      console.log(chalk.yellow("Dry run complete — retry would make no changes."));
    } else {
      console.log(chalk.yellow("Dry run complete — no changes were made."));
    }
    return 0;
  }

  if (opts.dispatch) {
    if (dispatchRequestedButNotStarted) {
      console.error(
        chalk.red(
          changedState
            ? "Retry updated state, but no new run was dispatched."
            : "Retry made no changes and did not dispatch a new run.",
        ),
      );
      return 1;
    }

    console.log(chalk.green("Retry complete — dispatched a new run."));
    return 0;
  }

  if (!changedState) {
    console.error(
      chalk.red(
        "Retry made no changes: bead is already open and the latest run does not need reset.",
      ),
    );
    return 1;
  }

  console.log(
    chalk.green("Retry state reset complete.") +
      chalk.dim(" Use --dispatch to immediately queue a new run."),
  );

  return 0;
}

// ── CLI Command ─────────────────────────────────────────────────────────

export const retryCommand = new Command("retry")
  .description(
    "Reset a bead and optionally re-dispatch it for execution",
  )
  .argument("<bead-id>", "Bead ID (seed ID) to retry, e.g. bd-ps1")
  .option("--dispatch", "Dispatch the bead immediately after resetting")
  .option("--model <model>", "Override agent model for dispatch")
  .option("--dry-run", "Show what would happen without making changes")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (beadId: string, opts: RetryOpts & { project?: string; projectPath?: string }) => {
    let projectPath: string;
    try {
      projectPath = await resolveRepoRootProjectPath(opts);
    } catch {
      console.error(
        chalk.red(
          "Not in a git repository. Run from within a foreman project.",
        ),
      );
      process.exit(1);
    }

    const store = ForemanStore.forProject(projectPath);
    const beadsClient = new BeadsRustClient(projectPath);

    try {
      const exitCode = await retryAction(
        beadId,
        opts,
        beadsClient,
        store,
        projectPath,
      );
      store.close();
      process.exit(exitCode);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Unexpected error: ${msg}`));
      store.close();
      process.exit(1);
    }
  });
