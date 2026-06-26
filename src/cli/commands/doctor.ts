import { Command } from "commander";
import chalk from "chalk";
import { foremanBackendMode } from "../../lib/backend-mode.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { ForemanStore } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import { destroyPool, isPoolInitialised } from "../../lib/db/pool-manager.js";
import { createTaskClient } from "../../lib/task-client-factory.js";
import { Doctor } from "../../orchestrator/doctor.js";
import { MergeQueue } from "../../orchestrator/merge-queue.js";
import { PostgresMergeQueue } from "../../orchestrator/postgres-merge-queue.js";
import { ensureCliPostgresPool, resolveRepoRootProjectPath } from "./project-task-support.js";
import { findRegisteredProjectByPath } from "./project-context.js";
import { wrapLocalRunStore } from "./local-store-adapter.js";
import { parseNonNegativeIntOption } from "./cli-output.js";
import { purgeLogsAction } from "./purge-logs.js";
import type { CheckResult, CheckStatus } from "../../orchestrator/types.js";

// ── Helpers ──────────────────────────────────────────────────────────────

function icon(status: CheckStatus): string {
  switch (status) {
    case "pass":  return chalk.green("✓");
    case "warn":  return chalk.yellow("⚠");
    case "fail":  return chalk.red("✗");
    case "fixed": return chalk.cyan("⚙");
    case "skip":  return chalk.dim("–");
  }
}

function label(status: CheckStatus): string {
  switch (status) {
    case "pass":  return chalk.green("pass");
    case "warn":  return chalk.yellow("warn");
    case "fail":  return chalk.red("fail");
    case "fixed": return chalk.cyan("fixed");
    case "skip":  return chalk.dim("skip");
  }
}

function printCheck(result: CheckResult): void {
  const pad = 40;
  const nameCol = result.name.padEnd(pad);
  console.log(`  ${icon(result.status)} ${nameCol} ${label(result.status)}`);
  if (result.status !== "pass") {
    console.log(`      ${chalk.dim(result.message)}`);
  }
  if (result.details) {
    console.log(`      ${chalk.dim(result.details)}`);
  }
  if (result.fixApplied) {
    console.log(`      ${chalk.cyan("→ " + result.fixApplied)}`);
  }
}

function printSection(title: string, results: CheckResult[], jsonOutput: boolean): void {
  if (!jsonOutput) {
    console.log(chalk.bold(`${title}:`));
    for (const r of results) printCheck(r);
    console.log();
  }
}

// ── Command ──────────────────────────────────────────────────────────────

async function resolveDoctorProjectPath(): Promise<string> {
  return resolveRepoRootProjectPath({});
}

export async function runElixirDoctor(opts: { jsonOutput?: boolean; fix?: boolean; dryRun?: boolean; cleanLogs?: boolean }): Promise<number> {
  const jsonOutput = opts.jsonOutput ?? false;
  if (opts.fix || opts.cleanLogs) {
    const message = "foreman doctor --fix/--clean-logs run legacy Node/Postgres maintenance. Use 'foreman server doctor' for Elixir health, or set FOREMAN_BACKEND=node for legacy maintenance.";
    if (jsonOutput) console.log(JSON.stringify({ checks: [], summary: { pass: 0, warn: 0, fail: 1, fixed: 0, skip: 0 }, error: message }, null, 2));
    else console.error(chalk.red(message));
    return 1;
  }

  if (!jsonOutput) {
    console.log(chalk.bold("\nforeman doctor (Elixir)\n"));
    if (opts.dryRun) console.log(chalk.dim("(dry-run has no effect for Elixir health checks)\n"));
  }

  const manager = new ElixirServerManager();
  await manager.ensureRunning();
  const doctor = await manager.doctor();
  if (jsonOutput) {
    console.log(JSON.stringify(doctor.ok ? doctor.body : { ok: false, error: doctor.error, body: doctor.body }, null, 2));
  } else if (doctor.ok) {
    console.log(chalk.green("Elixir server doctor: PASS"));
    console.log(JSON.stringify(doctor.body, null, 2));
  } else {
    console.error(chalk.red("Elixir server doctor: FAIL"));
    console.error(chalk.dim(doctor.error ?? JSON.stringify(doctor.body)));
  }
  return doctor.ok ? 0 : 1;
}

export const doctorCommand = new Command("doctor")
  .description("Check Foreman health (Elixir by default; legacy Node/Postgres maintenance with FOREMAN_BACKEND=node)")
  .option("--fix", "Auto-fix issues where possible")
  .option("--dry-run", "Show what --fix would do without making changes")
  .option("--json", "Output results as JSON")
  .option("--clean-logs", "Remove old agent log files after health checks (default: keep last 7 days)")
  .option(
    "--log-days <n>",
    "Retention window for --clean-logs in days (default: 7)",
    parseNonNegativeIntOption("--log-days"),
  )
  .action(async (opts) => {
    const fix = (opts.fix as boolean | undefined) ?? false;
    const dryRun = (opts.dryRun as boolean | undefined) ?? false;
    const jsonOutput = (opts.json as boolean | undefined) ?? false;
    const cleanLogs = (opts.cleanLogs as boolean | undefined) ?? false;
    const logDays = (opts.logDays as number | undefined) ?? 7;

    if (foremanBackendMode() === "elixir") {
      process.exit(await runElixirDoctor({ jsonOutput, fix, dryRun, cleanLogs }));
    }

    if (!jsonOutput) {
      console.log(chalk.bold("\nforeman doctor\n"));
      if (dryRun && fix) {
        console.log(chalk.yellow("⚠ Both --fix and --dry-run specified; --fix will be ignored (dry-run takes precedence).\n"));
      } else if (dryRun) {
        console.log(chalk.dim("(dry-run mode — no changes will be made)\n"));
      }
    }

    // Determine project path
    let projectPath: string;
    try {
      projectPath = await resolveDoctorProjectPath();
    } catch {
      if (!jsonOutput) {
        console.log(chalk.bold("Repository:"));
        console.log(`  ${chalk.red("✗")} ${"git repository".padEnd(40)} ${chalk.red("fail")}`);
        console.log(`      ${chalk.dim("Not inside a git repository. Run from your project directory.")}`);
        console.log();
      } else {
        console.log(JSON.stringify({
          checks: [],
          summary: { pass: 0, warn: 0, fail: 1, fixed: 0, skip: 0 },
          error: "Not inside a git repository",
        }, null, 2));
      }
      process.exit(1);
    }

    let store: ForemanStore | null = null;
    let shouldDestroyCliPool = false;
    let exitCode = 0;
    try {
      store = ForemanStore.forProject(projectPath);
      // initPool: false — doctor records whether the pool was already
      // initialised before ensuring it, so it can destroy it on exit.
      const registered = await findRegisteredProjectByPath(projectPath, { initPool: false });
      const mq = new MergeQueue(store.getDb());
      if (registered) {
        shouldDestroyCliPool = !isPoolInitialised();
        ensureCliPostgresPool(projectPath);
      }
      const runLookup = registered ? PostgresStore.forProject(registered.id) : undefined;
      const registeredMergeQueue = registered ? new PostgresMergeQueue(registered.id) : undefined;
      const { taskClient, backendType } = await createTaskClient(projectPath);
      const doctor = new Doctor(store, projectPath, mq, taskClient, undefined, registeredMergeQueue, runLookup, backendType);

      const report = await doctor.runAll({ fix, dryRun, projectPath });

      if (jsonOutput) {
        const allChecks = [...report.system, ...report.repository, ...report.dataIntegrity];
        console.log(JSON.stringify({ checks: allChecks, summary: report.summary }, null, 2));
      } else {
        printSection("System", report.system, false);
        printSection("Repository", report.repository, false);
        if (report.dataIntegrity.length > 0) {
          printSection("Data integrity", report.dataIntegrity, false);
        }

        // Summary
        const { pass, fixed, warn, fail } = report.summary;
        const parts: string[] = [];
        if (pass > 0)  parts.push(chalk.green(`${pass} passed`));
        if (fixed > 0) parts.push(chalk.cyan(`${fixed} fixed`));
        if (warn > 0)  parts.push(chalk.yellow(`${warn} warning(s)`));
        if (fail > 0)  parts.push(chalk.red(`${fail} failed`));

        console.log(chalk.bold("Summary: ") + parts.join(chalk.dim(", ")));

        if ((warn > 0 || fail > 0) && !fix && !dryRun) {
          console.log(chalk.dim("\nRe-run with --fix to auto-resolve fixable issues."));
          console.log(chalk.dim("Re-run with --dry-run to preview what --fix would change."));
        }

        if (fail > 0) {
          console.log();
        }
      }

      store.close();
      store = null;

      // Run log cleanup if --clean-logs was requested
      if (cleanLogs) {
      if (!jsonOutput) {
        console.log();
        console.log(chalk.bold("Log cleanup:"));
      }
      if (registered) {
        ensureCliPostgresPool(projectPath);
      }
      if (registered) {
        const purgeStore = PostgresStore.forProject(registered.id);
        try {
          await purgeLogsAction({ days: logDays, dryRun }, purgeStore);
        } finally {
          purgeStore.close();
        }
      } else {
        const localPurgeStore = ForemanStore.forProject(projectPath);
        try {
          await purgeLogsAction({ days: logDays, dryRun }, wrapLocalRunStore(localPurgeStore));
        } finally {
          localPurgeStore.close();
        }
      }
      }

      if (report.summary.fail > 0) {
        exitCode = 1;
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!jsonOutput) {
        console.error(chalk.red(`Error: ${msg}`));
      } else {
        console.log(JSON.stringify({ error: msg }, null, 2));
      }
      exitCode = 1;
    } finally {
      if (store) store.close();
      if (shouldDestroyCliPool) {
        await destroyPool();
      }
    }

    if (exitCode !== 0) {
      process.exit(exitCode);
    }
  });
