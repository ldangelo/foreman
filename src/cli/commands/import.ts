import { Command } from "commander";
import chalk from "chalk";
import { performBeadsImport } from "./task.js";
import { resolveProjectPathFromOptions } from "./project-task-support.js";

export const importCommand = new Command("import")
  .description("Import legacy beads data into the native task store (idempotent by external_id)")
  .option("--from-beads", "Import tasks from .beads/issues.jsonl or .beads/beads.jsonl", true)
  .option("--dry-run", "Preview the first 5 mappings without writing to the database")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action((opts: { dryRun?: boolean; project?: string; projectPath?: string }) => {
    const projectPath = resolveProjectPathFromOptions(opts);

    try {
      const result = performBeadsImport(projectPath, { dryRun: opts.dryRun });
      if (opts.dryRun) {
        console.log(chalk.bold("\n  Dry-run preview (first 5 tasks)\n"));
        for (const record of result.preview.slice(0, 5)) {
          console.log(
            `  ${chalk.dim(record.bead.id)} → ${record.nativeId.slice(0, 8)} ` +
              `${chalk.cyan(record.status)} ${record.bead.title}`,
          );
        }
        console.log();
        console.log(
          chalk.green(
            `Would import ${result.imported} tasks (${result.duplicateSkips} skipped: already exist by external_id/title${result.unsupportedStatusSkips > 0 ? `, ${result.unsupportedStatusSkips} skipped: unsupported status` : ""}).`,
          ),
        );
        return;
      }

      console.log(
        chalk.green(
          `Imported ${result.imported} tasks (${result.duplicateSkips} skipped: already exist by external_id/title${result.unsupportedStatusSkips > 0 ? `, ${result.unsupportedStatusSkips} skipped: unsupported status` : ""}).`,
        ),
      );
      console.log(chalk.dim(`  Source: ${result.jsonlPath}`));
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });
