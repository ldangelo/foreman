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
import { randomUUID } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import chalk from "chalk";
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

type ImportedBeadStatus = "open" | "in_progress" | "closed";

interface ImportedBeadDependency {
  issue_id?: string;
  depends_on_id?: string;
  type?: string;
}

interface ImportedBeadRecord {
  id: string;
  title: string;
  description?: string | null;
  status?: string;
  priority?: number | string;
  issue_type?: string;
  type?: string;
  created_at?: string;
  updated_at?: string;
  closed_at?: string;
  dependencies?: ImportedBeadDependency[];
}

interface PreparedImportRecord {
  nativeId: string;
  bead: ImportedBeadRecord;
  type: string;
  priority: number;
  status: string;
  createdAt: string;
  updatedAt: string;
  approvedAt: string | null;
  closedAt: string | null;
}

const IMPORTABLE_BEAD_STATUS_TO_TASK_STATUS: Record<ImportedBeadStatus, string> = {
  open: "backlog",
  in_progress: "ready",
  closed: "merged",
};

function resolveBeadsImportPath(projectPath: string): string {
  const candidates = [
    join(projectPath, ".beads", "issues.jsonl"),
    join(projectPath, ".beads", "beads.jsonl"),
  ];

  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }

  throw new Error(
    `No beads export found. Expected one of: ${candidates.join(", ")}`,
  );
}

function parseBeadsJsonl(jsonlPath: string): ImportedBeadRecord[] {
  const raw = readFileSync(jsonlPath, "utf8");
  const lines = raw
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter(Boolean);

  return lines.map((line, index) => {
    try {
      return JSON.parse(line) as ImportedBeadRecord;
    } catch (error) {
      throw new Error(
        `Invalid JSON in ${jsonlPath} at line ${index + 1}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  });
}

function normalizeImportedBeadPriority(
  bead: ImportedBeadRecord,
): number {
  if (typeof bead.priority === "number") {
    if (Number.isInteger(bead.priority) && bead.priority >= 0 && bead.priority <= 4) {
      return bead.priority;
    }
    throw new Error(
      `Bead '${bead.id}' has unsupported numeric priority '${bead.priority}'. Expected 0-4.`,
    );
  }

  if (typeof bead.priority === "string") {
    return parsePriority(bead.priority);
  }

  return 2;
}

function normalizeImportedBeadType(bead: ImportedBeadRecord): string {
  const type = bead.type ?? bead.issue_type;
  if (typeof type === "string" && type.trim().length > 0) {
    return type;
  }
  return "task";
}

function mapImportedBeadStatus(status: string | undefined): string | null {
  if (!status) return null;
  return IMPORTABLE_BEAD_STATUS_TO_TASK_STATUS[status as ImportedBeadStatus] ?? null;
}

function summarizeImportPreview(records: PreparedImportRecord[]): void {
  if (records.length === 0) {
    console.log(chalk.dim("No importable beads found in the JSONL export."));
    return;
  }

  console.log(chalk.bold("\n  Dry-run preview (first 5 tasks)\n"));
  for (const record of records.slice(0, 5)) {
    console.log(
      `  ${chalk.dim(record.bead.id)} → ${record.nativeId.slice(0, 8)} ` +
        `${chalk.cyan(record.status)} ` +
        `${chalk.dim(`[${record.type}, ${priorityLabel(record.priority)}]`)} ` +
        `${record.bead.title}`,
    );
  }
  console.log();
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

// ── foreman task import ───────────────────────────────────────────────────────

const importCommand = new Command("import")
  .description("Import legacy beads JSONL data into the native task store")
  .requiredOption("--from-beads", "Import tasks from .beads/issues.jsonl or .beads/beads.jsonl")
  .option("--dry-run", "Preview the first 5 mappings without writing to the database")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action((opts: { fromBeads: boolean; dryRun?: boolean; project?: string; projectPath?: string }) => {
    const projectPath = resolveProjectPathFromOptions(opts);

    try {
      const jsonlPath = resolveBeadsImportPath(projectPath);
      const beads = parseBeadsJsonl(jsonlPath);
      const { store, taskStore } = getTaskStore(projectPath);
      const db = store.getDb();
      const now = new Date().toISOString();
      const existingRows = db.prepare("SELECT id, title, external_id FROM tasks").all() as Array<{
        id: string;
        title: string;
        external_id: string | null;
      }>;

      const existingByExternalId = new Map<string, string>();
      const existingByTitle = new Map<string, string>();
      for (const row of existingRows) {
        if (row.external_id) {
          existingByExternalId.set(row.external_id, row.id);
        }
        if (!existingByTitle.has(row.title)) {
          existingByTitle.set(row.title, row.id);
        }
      }

      const beadToNativeId = new Map<string, string>();
      const prepared: PreparedImportRecord[] = [];
      let duplicateSkips = 0;
      let unsupportedStatusSkips = 0;

      for (const bead of beads) {
        const mappedStatus = mapImportedBeadStatus(bead.status);
        if (!mappedStatus) {
          unsupportedStatusSkips += 1;
          continue;
        }

        const existingId = existingByExternalId.get(bead.id) ?? existingByTitle.get(bead.title);
        if (existingId) {
          duplicateSkips += 1;
          beadToNativeId.set(bead.id, existingId);
          continue;
        }

        const priority = normalizeImportedBeadPriority(bead);
        const createdAt = bead.created_at ?? now;
        const updatedAt = bead.updated_at ?? createdAt;
        const approvedAt = mappedStatus === "ready" ? updatedAt : null;
        const closedAt = mappedStatus === "merged" ? bead.closed_at ?? updatedAt : null;
        const record: PreparedImportRecord = {
          nativeId: randomUUID(),
          bead,
          type: normalizeImportedBeadType(bead),
          priority,
          status: mappedStatus,
          createdAt,
          updatedAt,
          approvedAt,
          closedAt,
        };

        prepared.push(record);
        beadToNativeId.set(bead.id, record.nativeId);
      }

      if (opts.dryRun) {
        summarizeImportPreview(prepared);
        console.log(
          chalk.green(
            `Would import ${prepared.length} tasks (${duplicateSkips} skipped: already exist by external_id/title${unsupportedStatusSkips > 0 ? `, ${unsupportedStatusSkips} skipped: unsupported status` : ""}).`,
          ),
        );
        return;
      }

      const insertTask = db.prepare(
        `INSERT INTO tasks
           (id, title, description, type, priority, status, external_id, created_at, updated_at, approved_at, closed_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      );
      const insertDependency = db.prepare(
        `INSERT OR IGNORE INTO task_dependencies (from_task_id, to_task_id, type)
         VALUES (?, ?, ?)`,
      );

      const transaction = db.transaction(() => {
        for (const record of prepared) {
          insertTask.run(
            record.nativeId,
            record.bead.title,
            record.bead.description ?? null,
            record.type,
            record.priority,
            record.status,
            record.bead.id,
            record.createdAt,
            record.updatedAt,
            record.approvedAt,
            record.closedAt,
          );
        }

        for (const bead of beads) {
          const fromTaskId = beadToNativeId.get(bead.id);
          if (!fromTaskId || !Array.isArray(bead.dependencies)) continue;

          for (const dependency of bead.dependencies) {
            const dependencyType = dependency.type === "parent-child" ? "parent-child" : "blocks";
            const blockerId = dependency.depends_on_id
              ? beadToNativeId.get(dependency.depends_on_id)
              : null;

            if (!blockerId) continue;
            if (taskStore.hasCyclicDependency(fromTaskId, blockerId)) {
              throw new CircularDependencyError(fromTaskId, blockerId);
            }

            insertDependency.run(fromTaskId, blockerId, dependencyType);
          }
        }
      });

      transaction();
      console.log(
        chalk.green(
          `Imported ${prepared.length} tasks (${duplicateSkips} skipped: already exist by external_id/title${unsupportedStatusSkips > 0 ? `, ${unsupportedStatusSkips} skipped: unsupported status` : ""}).`,
        ),
      );
      console.log(chalk.dim(`  Source: ${jsonlPath}`));
      store.close();
    } catch (err) {
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

// ── Parent command ────────────────────────────────────────────────────────────

export const taskCommand = new Command("task")
  .description("Manage native tasks in the Foreman SQLite store")
  .addCommand(createCommand)
  .addCommand(listCommand)
  .addCommand(showCommand)
  .addCommand(importCommand)
  .addCommand(approveCommand)
  .addCommand(updateCommand)
  .addCommand(closeCommand)
  .addCommand(depCommand);
