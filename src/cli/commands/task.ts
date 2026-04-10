import { Command } from "commander";
import chalk from "chalk";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { ForemanStore } from "../../lib/store.js";
import {
  NativeTaskStore,
  parsePriority,
  type TaskRow,
} from "../../lib/task-store.js";
import { BeadsRustClient } from "../../lib/beads-rust.js";
import { resolveProjectPathFromOptions } from "./project-task-support.js";

function getTaskStore(projectPath: string): { store: ForemanStore; taskStore: NativeTaskStore } {
  const store = ForemanStore.forProject(projectPath);
  const taskStore = new NativeTaskStore(store.getDb());
  return { store, taskStore };
}

interface ImportedBeadRecord {
  id?: string;
  title?: string;
  description?: string | null;
  type?: string;
  issue_type?: string;
  priority?: string | number | null;
  status?: string | null;
  labels?: string[];
  dependencies?: Array<string | { depends_on_id?: string; type?: string }>;
}

interface ImportPreviewRow {
  externalId: string;
  title: string;
  type: string;
  priority: number;
  mappedStatus: string;
}

export interface ImportBeadsResult {
  imported: number;
  updated: number;
  skipped: number;
  dependencyErrors: number;
  preview: ImportPreviewRow[];
}

function resolveBeadsImportPath(projectPath: string): string | null {
  const candidates = [
    join(projectPath, ".beads", "issues.jsonl"),
    join(projectPath, ".beads", "beads.jsonl"),
  ];
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function mapImportedTaskType(record: ImportedBeadRecord): string {
  if (record.labels?.includes("kind:story")) return "story";
  return record.issue_type ?? record.type ?? "task";
}

function mapImportedTaskStatus(status: string | null | undefined): string {
  switch (status) {
    case "in_progress":
      return "ready";
    case "closed":
    case "completed":
      return "merged";
    case "blocked":
      return "blocked";
    case "open":
    default:
      return "backlog";
  }
}

function parseImportedPriority(value: ImportedBeadRecord["priority"]): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.min(Math.max(Math.trunc(value), 0), 4);
  }
  if (typeof value === "string") {
    try {
      return parsePriority(value);
    } catch {
      return 2;
    }
  }
  return 2;
}

/**
 * Transitional import helper for the native-task prototype.
 * Public Foreman task management remains beads-first; this helper exists only so
 * older experiments can ingest `.beads/` data into the SQLite task tables.
 */
export function importTasksFromBeads(
  projectPath: string,
  taskStore: NativeTaskStore,
  opts?: { dryRun?: boolean },
): ImportBeadsResult {
  const beadsPath = resolveBeadsImportPath(projectPath);
  if (!beadsPath) {
    throw new Error(`No beads import source found under ${join(projectPath, ".beads")}`);
  }

  const dryRun = opts?.dryRun ?? false;
  const lines = readFileSync(beadsPath, "utf-8")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);

  const records: ImportedBeadRecord[] = [];
  for (const line of lines) {
    try {
      records.push(JSON.parse(line) as ImportedBeadRecord);
    } catch {
      // Ignore malformed rows during import; existing data may be partially corrupt.
    }
  }

  const existingTasksByExternalId = new Map<string, TaskRow>();
  const externalIdToTaskId = new Map<string, string>();
  for (const task of taskStore.list()) {
    const fullTask = taskStore.get(task.id);
    if (fullTask?.external_id) {
      existingTasksByExternalId.set(fullTask.external_id, fullTask);
      externalIdToTaskId.set(fullTask.external_id, fullTask.id);
    }
  }

  let imported = 0;
  let updated = 0;
  let skipped = 0;
  let dependencyErrors = 0;
  const preview: ImportPreviewRow[] = [];

  for (const record of records) {
    if (!record.id || !record.title) {
      skipped++;
      continue;
    }

    const type = mapImportedTaskType(record);
    const priority = parseImportedPriority(record.priority);
    const mappedStatus = mapImportedTaskStatus(record.status);

    if (preview.length < 5) {
      preview.push({
        externalId: record.id,
        title: record.title,
        type,
        priority,
        mappedStatus,
      });
    }

    const existingTask = existingTasksByExternalId.get(record.id);
    if (existingTask) {
      if (existingTask.type !== type) {
        if (!dryRun) {
          taskStore.update(existingTask.id, { type });
          existingTasksByExternalId.set(record.id, taskStore.get(existingTask.id) ?? existingTask);
        }
        updated++;
      } else {
        skipped++;
      }
      continue;
    }

    if (dryRun) {
      imported++;
      externalIdToTaskId.set(record.id, `dry-run:${record.id}`);
      continue;
    }

    const created = taskStore.create({
      title: record.title,
      description: record.description ?? null,
      type,
      priority,
      externalId: record.id,
    });
    externalIdToTaskId.set(record.id, created.id);
    imported++;

    if (mappedStatus !== "backlog") {
      taskStore.updateStatus(created.id, mappedStatus);
    }
  }

  for (const record of records) {
    if (!record.id) continue;
    const targetTaskId = externalIdToTaskId.get(record.id);
    if (!targetTaskId || targetTaskId.startsWith("dry-run:")) continue;

    for (const dependency of record.dependencies ?? []) {
      const dependsOnId = typeof dependency === "string"
        ? dependency
        : dependency.depends_on_id;
      if (!dependsOnId) continue;
      const sourceTaskId = externalIdToTaskId.get(dependsOnId);
      if (!sourceTaskId || sourceTaskId.startsWith("dry-run:")) continue;

      const depType = typeof dependency === "string"
        ? "blocks"
        : dependency.type === "parent-child"
          ? "parent-child"
          : "blocks";

      try {
        if (!dryRun) {
          taskStore.addDependency(targetTaskId, sourceTaskId, depType);
        }
      } catch {
        dependencyErrors++;
      }
    }
  }

  return { imported, updated, skipped, dependencyErrors, preview };
}

const approveCommand = new Command("approve")
  .description("Approve a backlog bead for dispatch in the beads-first backend")
  .argument("<bead-id>", "Bead ID to approve")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .option("--no-recursive", "Do not approve parent-child descendants when approving a container bead")
  .action(async (beadId: string, opts: { project?: string; projectPath?: string; recursive?: boolean }) => {
    const projectPath = resolveProjectPathFromOptions(opts);
    const client = new BeadsRustClient(projectPath);

    try {
      const result = await client.approve(beadId, { recursive: opts.recursive !== false });
      if (result.approved.length === 0) {
        console.log(chalk.yellow(`No backlog labels were removed for ${beadId}. It may already be approved.`));
        return;
      }

      console.log(chalk.green(`✓ Approved ${result.approved.length} bead(s) for dispatch`));
      for (const approvedId of result.approved) {
        console.log(chalk.dim(`  ${approvedId}`));
      }
      if (result.skipped.length > 0) {
        console.log(chalk.dim(`Skipped already-approved beads: ${result.skipped.join(", ")}`));
      }
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });


const importCommand = new Command("import")
  .description("Import beads into the transitional native-task prototype store")
  .option("--from-beads", "Import from .beads/issues.jsonl or .beads/beads.jsonl")
  .option("--dry-run", "Preview the import without writing tasks")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action((opts: { fromBeads?: boolean; dryRun?: boolean; project?: string; projectPath?: string }) => {
    if (!opts.fromBeads) {
      console.error(chalk.red("Error: specify --from-beads to import beads data."));
      process.exit(1);
    }

    const projectPath = resolveProjectPathFromOptions(opts);

    try {
      const { store, taskStore } = getTaskStore(projectPath);
      try {
        const result = importTasksFromBeads(projectPath, taskStore, { dryRun: opts.dryRun });

        if (opts.dryRun) {
          console.log(
            chalk.cyan(
              `Dry run: would import ${result.imported} task(s), update ${result.updated}, skip ${result.skipped}.`,
            ),
          );
          if (result.preview.length > 0) {
            console.log(chalk.bold("\nPreview:"));
            for (const row of result.preview) {
              console.log(`  ${row.externalId} → ${row.title} [${row.type}] P${row.priority} status:${row.mappedStatus}`);
            }
          }
        } else {
          console.log(chalk.green(`✓ Imported ${result.imported} task(s)`));
          console.log(chalk.green(`  Updated: ${result.updated}`));
          console.log(chalk.dim(`  Skipped: ${result.skipped}`));
        }

        if (result.dependencyErrors > 0) {
          console.log(chalk.yellow(`  Dependency errors: ${result.dependencyErrors}`));
        }
      } finally {
        store.close();
      }
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

export const taskCommand = new Command("task")
  .description("Beads-first task helpers plus transitional native-task import commands")
  .addCommand(approveCommand)
  .addCommand(importCommand);
