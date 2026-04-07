/**
 * `foreman task` CLI commands — manage native tasks in the Foreman SQLite store.
 *
 * Sub-commands:
 *   foreman task create --title <text> [--description <text>] [--type <type>]
 *                        [--priority <level>]
 *   foreman task list [--status <status>] [--all]
 *   foreman task show <id>
 *   foreman task update <id> [--title <text>] [--description <text>]
 *                           [--priority <level>] [--status <status>] [--force]
 *   foreman task approve <id>
 *   foreman task close <id>
 *   foreman task dep add <from-id> <to-id> [--type blocks|parent-child]
 *   foreman task dep list <id>
 *   foreman task dep remove <from-id> <to-id> [--type blocks|parent-child]
 *
 * @module src/cli/commands/task
 */

import { Command } from "commander";
import chalk from "chalk";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { ForemanStore } from "../../lib/store.js";
import {
  NativeTaskStore,
  parsePriority,
  priorityLabel,
  TaskNotFoundError,
  InvalidStatusTransitionError,
  CircularDependencyError,
  type TaskRow,
  type DependencyRow,
} from "../../lib/task-store.js";
import { resolveProjectPathFromOptions } from "./project-task-support.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Column widths for the task table. */
const COL_ID = 10;
const COL_TITLE = 40;
const COL_TYPE = 10;
const COL_PRI = 12;
const COL_STATUS = 14;

function pad(str: string, width: number): string {
  return str.length >= width ? str.slice(0, width - 1) + "…" : str.padEnd(width);
}

function priorityChalk(priority: number): string {
  const label = priorityLabel(priority);
  switch (priority) {
    case 0:
      return chalk.red(label);
    case 1:
      return chalk.yellow(label);
    case 2:
      return chalk.cyan(label);
    case 3:
      return chalk.dim(label);
    default:
      return chalk.dim(label);
  }
}

function statusChalk(status: string): string {
  switch (status) {
    case "ready":
      return chalk.green(status);
    case "in-progress":
    case "explorer":
    case "developer":
    case "qa":
    case "reviewer":
    case "finalize":
      return chalk.cyan(status);
    case "merged":
    case "closed":
      return chalk.dim(status);
    case "blocked":
    case "conflict":
      return chalk.yellow(status);
    case "failed":
    case "stuck":
      return chalk.red(status);
    case "backlog":
    default:
      return chalk.dim(status);
  }
}

function printTaskTable(rows: TaskRow[]): void {
  if (rows.length === 0) {
    console.log(chalk.dim("No tasks found."));
    return;
  }

  // Header
  console.log(
    chalk.bold(pad("ID", COL_ID)) +
      chalk.bold(pad("TITLE", COL_TITLE)) +
      chalk.bold(pad("TYPE", COL_TYPE)) +
      chalk.bold(pad("PRIORITY", COL_PRI)) +
      chalk.bold("STATUS"),
  );
  console.log("─".repeat(COL_ID + COL_TITLE + COL_TYPE + COL_PRI + COL_STATUS));

  for (const t of rows) {
    const shortId = t.id.slice(0, 8);
    const priStr = priorityChalk(t.priority);
    const priPadded = pad(priStr + " ".repeat(Math.max(0, COL_PRI - priorityLabel(t.priority).length)), COL_PRI);
    console.log(
      chalk.dim(pad(shortId, COL_ID)) +
        pad(t.title, COL_TITLE) +
        chalk.dim(pad(t.type, COL_TYPE)) +
        priPadded +
        statusChalk(t.status),
    );
  }
}

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

  const existingByExternalId = new Set(
    taskStore
      .list()
      .map((task) => task.description) // touch rows so store is initialized consistently
  );
  void existingByExternalId; // appease lint for list side effects not needed directly

  const existingTasksByExternalId = new Map<string, TaskRow>();
  const externalIdToTaskId = new Map<string, string>();
  for (const task of taskStore.list()) {
    if (task.description !== undefined) {
      const fullTask = taskStore.get(task.id);
      if (fullTask?.external_id) {
        existingTasksByExternalId.set(fullTask.external_id, fullTask);
        externalIdToTaskId.set(fullTask.external_id, fullTask.id);
      }
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
          existingTasksByExternalId.set(record.id, {
            ...(taskStore.get(existingTask.id) ?? existingTask),
          });
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

// ── foreman task create ───────────────────────────────────────────────────────

const createCommand = new Command("create")
  .description("Create a new task in backlog status")
  .requiredOption("--title <text>", "Task title")
  .option("--description <text>", "Optional task description")
  .option(
    "--type <type>",
    "Task type: task, bug, feature, epic, chore, docs, question (default: task)",
    "task",
  )
  .option(
    "--priority <level>",
    "Priority: 0-4 or critical/high/medium/low/backlog (default: medium)",
    "medium",
  )
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(
    (opts: {
      title: string;
      description?: string;
      type: string;
      priority: string;
      project?: string;
      projectPath?: string;
    }) => {
      const projectPath = resolveProjectPathFromOptions(opts);

      let priority: number;
      try {
        priority = parsePriority(opts.priority);
      } catch {
        console.error(
          chalk.red(
            `Error: Invalid priority '${opts.priority}'. Use 0-4 or: critical, high, medium, low, backlog`,
          ),
        );
        process.exit(1);
      }

      const validTypes = ["task", "bug", "feature", "epic", "chore", "docs", "question"];
      if (!validTypes.includes(opts.type)) {
        console.error(
          chalk.red(
            `Error: Invalid type '${opts.type}'. Valid types: ${validTypes.join(", ")}`,
          ),
        );
        process.exit(1);
      }

      try {
        const { taskStore } = getTaskStore(projectPath);
        const task = taskStore.create({
          title: opts.title,
          description: opts.description ?? null,
          type: opts.type,
          priority,
        });

        console.log(
          chalk.green(`✓ Task created`) + chalk.dim(` [${task.id.slice(0, 8)}]`),
        );
        console.log(`  Title:    ${task.title}`);
        console.log(`  Type:     ${task.type}`);
        console.log(`  Priority: ${priorityLabel(task.priority)}`);
        console.log(`  Status:   ${task.status}`);
        console.log(
          chalk.dim(`\n  Run 'foreman task approve ${task.id}' to make it ready for dispatch.`),
        );
      } catch (err) {
        console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
        process.exit(1);
      }
    },
  );

// ── foreman task list ─────────────────────────────────────────────────────────

const listCommand = new Command("list")
  .description("List tasks in the native task store")
  .option("--status <status>", "Filter by status (e.g. ready, backlog, in-progress)")
  .option("--all", "Include closed and merged tasks (excluded by default)")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action((opts: { status?: string; all?: boolean; project?: string; projectPath?: string }) => {
    const projectPath = resolveProjectPathFromOptions(opts);

    try {
      const { store, taskStore } = getTaskStore(projectPath);

      if (!taskStore.hasNativeTasks() && !opts.status) {
        console.log(
          chalk.dim("No tasks in native store. Use 'foreman task create' to add tasks."),
        );
        return;
      }

      const db = store.getDb();
      let sql = "SELECT * FROM tasks";
      const params: string[] = [];
      const conditions: string[] = [];

      if (opts.status) {
        conditions.push("status = ?");
        params.push(opts.status);
      } else if (!opts.all) {
        // By default, exclude closed/merged tasks
        conditions.push("status NOT IN ('closed', 'merged')");
      }

      if (conditions.length > 0) {
        sql += " WHERE " + conditions.join(" AND ");
      }
      sql += " ORDER BY priority ASC, created_at ASC";

      const rows = (
        params.length > 0 ? db.prepare(sql).all(...params) : db.prepare(sql).all()
      ) as TaskRow[];

      if (rows.length === 0) {
        if (opts.status) {
          console.log(chalk.dim(`No tasks with status '${opts.status}'.`));
        } else {
          console.log(
            chalk.dim("No tasks found. Use 'foreman task create' to add tasks."),
          );
        }
        return;
      }

      const label = opts.status
        ? `Tasks (status: ${opts.status})`
        : opts.all
          ? `All Tasks`
          : `Active Tasks`;
      console.log(chalk.bold(`\n  ${label} (${rows.length})\n`));
      printTaskTable(rows);
      console.log();
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

// ── foreman task show ─────────────────────────────────────────────────────────

const showCommand = new Command("show")
  .description("Show details of a specific task")
  .argument("<id>", "Task ID (or short prefix)")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action((id: string, opts: { project?: string; projectPath?: string }) => {
    const projectPath = resolveProjectPathFromOptions(opts);

    try {
      const { store, taskStore } = getTaskStore(projectPath);
      const db = store.getDb();

      // Support short ID prefix (first 8 chars)
      let task: TaskRow | null;
      if (id.length < 36) {
        const rows = db
          .prepare("SELECT * FROM tasks WHERE id LIKE ? LIMIT 2")
          .all(`${id}%`) as TaskRow[];
        if (rows.length === 0) {
          console.error(chalk.red(`Error: Task '${id}' not found.`));
          process.exit(1);
        }
        if (rows.length > 1) {
          console.error(
            chalk.red(`Error: Ambiguous ID prefix '${id}' matches multiple tasks.`),
          );
          process.exit(1);
        }
        task = rows[0];
      } else {
        task = taskStore.get(id);
        if (!task) {
          console.error(chalk.red(`Error: Task '${id}' not found.`));
          process.exit(1);
        }
      }

      console.log(chalk.bold(`\n  Task: ${task.title}`));
      console.log(`  ID:          ${task.id}`);
      console.log(`  Type:        ${task.type}`);
      console.log(`  Priority:    ${priorityLabel(task.priority)} (${task.priority})`);
      console.log(`  Status:      ${statusChalk(task.status)}`);
      if (task.description) {
        console.log(`  Description: ${task.description}`);
      }
      if (task.run_id) {
        console.log(`  Run ID:      ${task.run_id}`);
      }
      if (task.branch) {
        console.log(`  Branch:      ${task.branch}`);
      }
      if (task.external_id) {
        console.log(`  External ID: ${task.external_id}`);
      }
      console.log(`  Created:     ${new Date(task.created_at).toLocaleString()}`);
      console.log(`  Updated:     ${new Date(task.updated_at).toLocaleString()}`);
      if (task.approved_at) {
        console.log(`  Approved:    ${new Date(task.approved_at).toLocaleString()}`);
      }
      if (task.closed_at) {
        console.log(`  Closed:      ${new Date(task.closed_at).toLocaleString()}`);
      }

      // Show dependencies
      const outgoing = taskStore.getDependencies(task.id, "outgoing");
      const incoming = taskStore.getDependencies(task.id, "incoming");

      if (incoming.length > 0) {
        console.log(chalk.bold("\n  Blocked by:"));
        for (const dep of incoming) {
          console.log(chalk.yellow(`    [${dep.type}] ← ${dep.from_task_id.slice(0, 8)}`));
        }
      }

      if (outgoing.length > 0) {
        console.log(chalk.bold("\n  Blocking:"));
        for (const dep of outgoing) {
          console.log(chalk.dim(`    [${dep.type}] → ${dep.to_task_id.slice(0, 8)}`));
        }
      }
      console.log();
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

// ── foreman task approve ──────────────────────────────────────────────────────

const approveCommand = new Command("approve")
  .description("Approve a backlog task, making it ready for dispatch")
  .argument("<id>", "Task ID")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action((id: string, opts: { project?: string; projectPath?: string }) => {
    const projectPath = resolveProjectPathFromOptions(opts);

    try {
      const { taskStore } = getTaskStore(projectPath);
      taskStore.approve(id);

      // Check what status it transitioned to
      const task = taskStore.get(id);
      if (task?.status === "ready") {
        console.log(
          chalk.green(`✓ Task '${id.slice(0, 8)}' approved and ready for dispatch.`),
        );
      } else {
        console.log(chalk.green(`✓ Task '${id.slice(0, 8)}' approved.`));
        if (task?.status) {
          console.log(chalk.dim(`  Status: ${task.status}`));
        }
      }
    } catch (err) {
      if (err instanceof TaskNotFoundError) {
        console.error(chalk.red(`Error: Task '${id}' not found.`));
        process.exit(1);
      }
      if (err instanceof InvalidStatusTransitionError) {
        console.error(
          chalk.red(
            `Error: Task '${id.slice(0, 8)}' cannot be approved — it is currently '${err.fromStatus}'.`,
          ),
        );
        console.error(chalk.dim("  Only 'backlog' tasks can be approved."));
        process.exit(1);
      }
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

// ── foreman task update ───────────────────────────────────────────────────────

const updateCommand = new Command("update")
  .description("Update fields on an existing task")
  .argument("<id>", "Task ID")
  .option("--title <text>", "New task title")
  .option("--description <text>", "New task description (use --no-description to clear)")
  .option("--no-description", "Clear the description field")
  .option("--priority <level>", "New priority: 0-4 or critical/high/medium/low/backlog")
  .option("--status <status>", "New status (e.g. backlog, ready, in-progress)")
  .option("--force", "Allow backward status transitions (e.g. merged → backlog)")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(
    (id: string, opts: {
      title?: string;
      description?: string;
      noDescription?: boolean;
      priority?: string;
      status?: string;
      force?: boolean;
      project?: string;
      projectPath?: string;
    }) => {
      const projectPath = resolveProjectPathFromOptions(opts);

      const updateOpts: {
        title?: string;
        description?: string | null;
        priority?: number;
        status?: string;
        force?: boolean;
      } = {};

      if (opts.title !== undefined) {
        updateOpts.title = opts.title;
      }
      if (opts.noDescription) {
        updateOpts.description = null;
      } else if (opts.description !== undefined) {
        updateOpts.description = opts.description;
      }
      if (opts.priority !== undefined) {
        try {
          updateOpts.priority = parsePriority(opts.priority);
        } catch {
          console.error(
            chalk.red(
              `Error: Invalid priority '${opts.priority}'. Use 0-4 or: critical, high, medium, low, backlog`,
            ),
          );
          process.exit(1);
        }
      }
      if (opts.status !== undefined) {
        updateOpts.status = opts.status;
      }
      if (opts.force) {
        updateOpts.force = true;
      }

      try {
        const { taskStore } = getTaskStore(projectPath);
        const task = taskStore.update(id, updateOpts);

        console.log(chalk.green(`✓ Task '${id.slice(0, 8)}' updated.`));
        console.log(`  Title:    ${task.title}`);
        console.log(`  Type:     ${task.type}`);
        console.log(`  Priority: ${priorityLabel(task.priority)}`);
        console.log(`  Status:   ${statusChalk(task.status)}`);
        if (task.description) {
          console.log(`  Description: ${task.description}`);
        }
      } catch (err) {
        if (err instanceof TaskNotFoundError) {
          console.error(chalk.red(`Error: Task '${id}' not found.`));
          process.exit(1);
        }
        if (err instanceof InvalidStatusTransitionError) {
          console.error(
            chalk.red(
              `Error: Task '${id.slice(0, 8)}' cannot transition from '${err.fromStatus}' to '${err.toStatus}'.`,
            ),
          );
          console.error(
            chalk.dim("  Use --force to override this check."),
          );
          process.exit(1);
        }
        console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
        process.exit(1);
      }
    },
  );

// ── foreman task close ────────────────────────────────────────────────────────

const closeCommand = new Command("close")
  .description("Close a task (mark as merged)")
  .argument("<id>", "Task ID")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action((id: string, opts: { project?: string; projectPath?: string }) => {
    const projectPath = resolveProjectPathFromOptions(opts);

    try {
      const { taskStore } = getTaskStore(projectPath);
      taskStore.close(id);

      console.log(chalk.green(`✓ Task '${id.slice(0, 8)}' closed.`));
    } catch (err) {
      if (err instanceof TaskNotFoundError) {
        console.error(chalk.red(`Error: Task '${id}' not found.`));
        process.exit(1);
      }
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

// ── foreman task dep ──────────────────────────────────────────────────────────

const depAddCommand = new Command("add")
  .description("Add a dependency between two tasks (from-id blocks to-id)")
  .argument("<from-id>", "The blocking task ID")
  .argument("<to-id>", "The blocked task ID")
  .option(
    "--type <type>",
    "Dependency type: blocks (default) or parent-child",
    "blocks",
  )
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(
    (fromId: string, toId: string, opts: { type: string; project?: string; projectPath?: string }) => {
      const projectPath = resolveProjectPathFromOptions(opts);

      if (opts.type !== "blocks" && opts.type !== "parent-child") {
        console.error(
          chalk.red(`Error: Invalid type '${opts.type}'. Use 'blocks' or 'parent-child'.`),
        );
        process.exit(1);
      }

      try {
        const { taskStore } = getTaskStore(projectPath);
        taskStore.addDependency(fromId, toId, opts.type as "blocks" | "parent-child");
        const verb = opts.type === "blocks" ? "blocks" : "is parent of";
        console.log(
          chalk.green(
            `✓ Dependency added: '${fromId.slice(0, 8)}' ${verb} '${toId.slice(0, 8)}'.`,
          ),
        );
      } catch (err) {
        if (err instanceof TaskNotFoundError) {
          console.error(chalk.red(`Error: Task '${err.taskId}' not found.`));
          process.exit(1);
        }
        if (err instanceof CircularDependencyError) {
          console.error(
            chalk.red(`Error: Adding this dependency would create a circular dependency.`),
          );
          process.exit(1);
        }
        console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
        process.exit(1);
      }
    },
  );

const depListCommand = new Command("list")
  .description("List dependencies for a task")
  .argument("<id>", "Task ID")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action((id: string, opts: { project?: string; projectPath?: string }) => {
    const projectPath = resolveProjectPathFromOptions(opts);

    try {
      const { taskStore } = getTaskStore(projectPath);

      const blockedBy = taskStore.getDependencies(id, "incoming") as DependencyRow[];
      const blocking = taskStore.getDependencies(id, "outgoing") as DependencyRow[];

      if (blockedBy.length === 0 && blocking.length === 0) {
        console.log(chalk.dim(`Task '${id.slice(0, 8)}' has no dependencies.`));
        return;
      }

      if (blockedBy.length > 0) {
        console.log(chalk.bold("\n  Blocked by:"));
        for (const dep of blockedBy) {
          console.log(chalk.yellow(`    [${dep.type}] ← ${dep.from_task_id.slice(0, 8)}`));
        }
      }

      if (blocking.length > 0) {
        console.log(chalk.bold("\n  Blocking:"));
        for (const dep of blocking) {
          console.log(chalk.dim(`    [${dep.type}] → ${dep.to_task_id.slice(0, 8)}`));
        }
      }
      console.log();
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

const depRemoveCommand = new Command("remove")
  .description("Remove a dependency between two tasks")
  .argument("<from-id>", "The blocking task ID")
  .argument("<to-id>", "The blocked task ID")
  .option(
    "--type <type>",
    "Dependency type: blocks (default) or parent-child",
    "blocks",
  )
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(
    (fromId: string, toId: string, opts: { type: string; project?: string; projectPath?: string }) => {
      const projectPath = resolveProjectPathFromOptions(opts);

      try {
        const { taskStore } = getTaskStore(projectPath);
        taskStore.removeDependency(fromId, toId, opts.type as "blocks" | "parent-child");
        console.log(
          chalk.green(
            `✓ Dependency removed: '${fromId.slice(0, 8)}' → '${toId.slice(0, 8)}'.`,
          ),
        );
      } catch (err) {
        console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
        process.exit(1);
      }
    },
  );

const depCommand = new Command("dep")
  .description("Manage task dependencies")
  .addCommand(depAddCommand)
  .addCommand(depListCommand)
  .addCommand(depRemoveCommand);

const importCommand = new Command("import")
  .description("Import beads into the native task store")
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
      const { taskStore } = getTaskStore(projectPath);
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
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

// ── Parent command ────────────────────────────────────────────────────────────

export const taskCommand = new Command("task")
  .description("Manage native tasks in the Foreman SQLite store")
  .addCommand(createCommand)
  .addCommand(importCommand)
  .addCommand(listCommand)
  .addCommand(showCommand)
  .addCommand(approveCommand)
  .addCommand(updateCommand)
  .addCommand(closeCommand)
  .addCommand(depCommand);
