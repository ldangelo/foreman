import { Command } from "commander";
import chalk from "chalk";
import { getRepoRoot } from "../../lib/git.js";
import { ForemanStore } from "../../lib/store.js";
import { Doctor } from "../../orchestrator/doctor.js";
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

export const doctorCommand = new Command("doctor")
  .description("Check foreman installation and project health, with optional auto-fix")
  .option("--fix", "Auto-fix issues where possible")
  .option("--dry-run", "Show what --fix would do without making changes")
  .option("--json", "Output results as JSON")
  .action(async (opts) => {
    const fix = (opts.fix as boolean | undefined) ?? false;
    const dryRun = (opts.dryRun as boolean | undefined) ?? false;
    const jsonOutput = (opts.json as boolean | undefined) ?? false;

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
      projectPath = await getRepoRoot(process.cwd());
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
    try {
      store = ForemanStore.forProject(projectPath);
      const doctor = new Doctor(store, projectPath);

      const report = await doctor.runAll({ fix, dryRun });

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

      if (report.summary.fail > 0) {
        process.exit(1);
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      if (store) store.close();
      if (!jsonOutput) {
        console.error(chalk.red(`Error: ${msg}`));
      } else {
        console.log(JSON.stringify({ error: msg }, null, 2));
      }
      process.exit(1);
    }
  });
