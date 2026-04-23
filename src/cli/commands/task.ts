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
import { existsSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";
import chalk from "chalk";
import { ForemanStore } from "../../lib/store.js";
import {
  NativeTaskStore,
  parsePriority,
  priorityLabel,
  formatTaskIdDisplay,
  TaskNotFoundError,
  InvalidStatusTransitionError,
  CircularDependencyError,
  type TaskRow,
  type DependencyRow,
} from "../../lib/task-store.js";
import { resolveProjectPathFromOptions } from "./project-task-support.js";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { listRegisteredProjects } from "./project-task-support.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Column widths for the task table. */
const COL_ID = 16;
const COL_TITLE = 40;
const COL_TYPE = 10;
const COL_PRI = 14;
const COL_STATUS = 14;
const COL_GAP = "  ";

// ── tRPC task helpers ─────────────────────────────────────────────────────

/** Try to resolve a projectId from the project flag, then attempt tRPC call.
 * Falls back to NativeTaskStore on daemon errors.
 */
async function withTaskTrpc<T>(
  opts: { project?: string },
  fn: (client: ReturnType<typeof createTrpcClient>, projectId: string) => Promise<T>,
  fallback: () => Promise<T>,
): Promise<T> {
  if (!opts.project) return fallback();
  try {
    const projects = await listRegisteredProjects();
    const record = projects.find((project) => project.id === opts.project || project.name === opts.project);
    if (!record) return fallback();
    const client = createTrpcClient();
    return fn(client, record.id);
  } catch {
    return fallback();
  }
}

function handleTaskDaemonError(err: unknown): void {
  const msg = err instanceof Error ? err.message : String(err);
  if (
    msg.includes("ECONNREFUSED") ||
    msg.includes("ENOENT") ||
    msg.includes("connect") ||
    msg.includes("socket")
  ) {
    console.error(
      chalk.yellow(
        "Daemon unavailable. Falling back to local task store."
      )
    );
  } else {
    console.error(
      chalk.red(`Daemon error: ${msg}`)
    );
  }
}

function pad(str: string, width: number): string {
  return str.length >= width ? str.slice(0, width - 1) + "…" : str.padEnd(width);
}

function renderColumn(
  value: string,
  width: number,
  style: (text: string) => string = (text) => text,
): string {
  return style(pad(value, width));
}

function colorPriority(text: string, priority: number): string {
  switch (priority) {
    case 0:
      return chalk.red(text);
    case 1:
      return chalk.yellow(text);
    case 2:
      return chalk.cyan(text);
    case 3:
      return chalk.dim(text);
    default:
      return chalk.dim(text);
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
      COL_GAP +
      chalk.bold(pad("TITLE", COL_TITLE)) +
      COL_GAP +
      chalk.bold(pad("TYPE", COL_TYPE)) +
      COL_GAP +
      chalk.bold(pad("PRIORITY", COL_PRI)) +
      COL_GAP +
      chalk.bold("STATUS"),
  );
  console.log("─".repeat(COL_ID + COL_TITLE + COL_TYPE + COL_PRI + COL_STATUS + (COL_GAP.length * 4)));

  for (const t of rows) {
    const shortId = formatTaskIdDisplay(t.id);
    console.log(
      renderColumn(shortId, COL_ID, chalk.dim) +
        COL_GAP +
        renderColumn(t.title, COL_TITLE) +
        COL_GAP +
        renderColumn(t.type, COL_TYPE, chalk.dim) +
        COL_GAP +
        renderColumn(priorityLabel(t.priority), COL_PRI, (text) => colorPriority(text, t.priority)) +
        COL_GAP +
        renderColumn(t.status, COL_STATUS, statusChalk),
    );
  }
}

function getTaskStore(projectPath: string): { store: ForemanStore; taskStore: NativeTaskStore } {
  const store = ForemanStore.forProject(projectPath);
  const project = store.getProjectByPath(projectPath);
  const taskStore = new NativeTaskStore(store.getDb(), {
    projectKey: project?.name ?? basename(projectPath),
  });
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

export interface TaskImportResult {
  imported: number;
  duplicateSkips: number;
  unsupportedStatusSkips: number;
  jsonlPath: string;
  preview: PreparedImportRecord[];
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
      `  ${chalk.dim(record.bead.id)} → ${formatTaskIdDisplay(record.nativeId)} ` +
        `${chalk.cyan(record.status)} ` +
        `${chalk.dim(`[${record.type}, ${priorityLabel(record.priority)}]`)} ` +
        `${record.bead.title}`,
    );
  }
  console.log();
}

export function performBeadsImport(
  projectPath: string,
  opts: { dryRun?: boolean } = {},
): TaskImportResult {
  const jsonlPath = resolveBeadsImportPath(projectPath);
  const beads = parseBeadsJsonl(jsonlPath);
  const { store, taskStore } = getTaskStore(projectPath);

  try {
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
        nativeId: taskStore.allocateTaskId(),
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

    if (!opts.dryRun) {
      const insertTask = db.prepare(
        `INSERT INTO tasks
           (id, title, description, type, priority, status, external_id, created_at, updated_at, approved_at, closed_at)
         VALUES (?, ?, ?, ?, ?, 'backlog', ?, ?, ?, NULL, NULL)`,
      );
      const updateImportedTask = db.prepare(
        `UPDATE tasks
            SET status = ?,
                created_at = ?,
                updated_at = ?,
                approved_at = ?,
                closed_at = ?
          WHERE id = ?`,
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
            record.bead.id,
            record.createdAt,
            record.updatedAt,
          );

          updateImportedTask.run(
            record.status,
            record.createdAt,
            record.updatedAt,
            record.approvedAt,
            record.closedAt,
            record.nativeId,
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
    }

    return {
      imported: prepared.length,
      duplicateSkips,
      unsupportedStatusSkips,
      jsonlPath,
      preview: prepared,
    };
  } finally {
    store.close();
  }
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
    async (opts: {
      title: string;
      description?: string;
      type: string;
      priority: string;
      project?: string;
      projectPath?: string;
    }) => {
      const projectPath = await resolveProjectPathFromOptions(opts);

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
          chalk.green(`✓ Task created`) + chalk.dim(` [${task.id}]`),
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
  .option("--type <type>", "Filter by type (e.g. epic, bug, feature, task)")
  .option("--all", "Include closed and merged tasks (excluded by default)")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (opts: { status?: string; type?: string; all?: boolean; project?: string; projectPath?: string }) => {
    const projectPath = await resolveProjectPathFromOptions(opts);

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

      if (opts.type) {
        conditions.push("type = ?");
        params.push(opts.type);
      }

      if (conditions.length > 0) {
        sql += " WHERE " + conditions.join(" AND ");
      }
      sql += " ORDER BY priority ASC, created_at ASC";

      const rows = (
        params.length > 0 ? db.prepare(sql).all(...params) : db.prepare(sql).all()
      ) as TaskRow[];

      if (rows.length === 0) {
        if (opts.status && opts.type) {
          console.log(chalk.dim(`No tasks with status '${opts.status}' and type '${opts.type}'.`));
        } else if (opts.status) {
          console.log(chalk.dim(`No tasks with status '${opts.status}'.`));
        } else if (opts.type) {
          console.log(chalk.dim(`No tasks with type '${opts.type}'.`));
        } else {
          console.log(
            chalk.dim("No tasks found. Use 'foreman task create' to add tasks."),
          );
        }
        return;
      }

      const label = opts.status
        ? opts.type
          ? `Tasks (status: ${opts.status}, type: ${opts.type})`
          : `Tasks (status: ${opts.status})`
        : opts.type
          ? `Tasks (type: ${opts.type})`
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
  .action(async (id: string, opts: { project?: string; projectPath?: string }) => {
    const projectPath = await resolveProjectPathFromOptions(opts);

    try {
      const { taskStore } = getTaskStore(projectPath);
      const resolvedId = taskStore.resolveTaskId(id);
      const task = taskStore.get(resolvedId);
      if (!task) {
        console.error(chalk.red(`Error: Task '${id}' not found.`));
        process.exit(1);
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
          console.log(chalk.yellow(`    [${dep.type}] ← ${formatTaskIdDisplay(dep.from_task_id)}`));
        }
      }

      if (outgoing.length > 0) {
        console.log(chalk.bold("\n  Blocking:"));
        for (const dep of outgoing) {
          console.log(chalk.dim(`    [${dep.type}] → ${formatTaskIdDisplay(dep.to_task_id)}`));
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
  .action(async (id: string, opts: { project?: string; projectPath?: string }) => {
    const projectPath = await resolveProjectPathFromOptions(opts);

    try {
      const { taskStore } = getTaskStore(projectPath);
      const resolvedId = taskStore.resolveTaskId(id);
      taskStore.approve(resolvedId);

      // Check what status it transitioned to
      const task = taskStore.get(resolvedId);
      if (task?.status === "ready") {
        console.log(
          chalk.green(`✓ Task '${formatTaskIdDisplay(resolvedId)}' approved and ready for dispatch.`),
        );
      } else {
        console.log(chalk.green(`✓ Task '${formatTaskIdDisplay(resolvedId)}' approved.`));
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
            `Error: Task '${formatTaskIdDisplay(err.taskId)}' cannot be approved — it is currently '${err.fromStatus}'.`,
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
    async (id: string, opts: {
      title?: string;
      description?: string;
      noDescription?: boolean;
      priority?: string;
      status?: string;
      force?: boolean;
      project?: string;
      projectPath?: string;
    }) => {
      const projectPath = await resolveProjectPathFromOptions(opts);

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
        const resolvedId = taskStore.resolveTaskId(id);
        const task = taskStore.update(resolvedId, updateOpts);

        console.log(chalk.green(`✓ Task '${formatTaskIdDisplay(resolvedId)}' updated.`));
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
              `Error: Task '${formatTaskIdDisplay(err.taskId)}' cannot transition from '${err.fromStatus}' to '${err.toStatus}'.`,
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
  .action(async (id: string, opts: { project?: string; projectPath?: string }) => {
    const projectPath = await resolveProjectPathFromOptions(opts);

    try {
      const { taskStore } = getTaskStore(projectPath);
      const resolvedId = taskStore.resolveTaskId(id);
      taskStore.close(resolvedId);

      console.log(chalk.green(`✓ Task '${formatTaskIdDisplay(resolvedId)}' closed.`));
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
  .action(async (opts: { fromBeads: boolean; dryRun?: boolean; project?: string; projectPath?: string }) => {
    const projectPath = await resolveProjectPathFromOptions(opts);

    try {
      const result = performBeadsImport(projectPath, { dryRun: opts.dryRun });
      if (opts.dryRun) {
        summarizeImportPreview(result.preview);
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
    async (fromId: string, toId: string, opts: { type: string; project?: string; projectPath?: string }) => {
      const projectPath = await resolveProjectPathFromOptions(opts);

      if (opts.type !== "blocks" && opts.type !== "parent-child") {
        console.error(
          chalk.red(`Error: Invalid type '${opts.type}'. Use 'blocks' or 'parent-child'.`),
        );
        process.exit(1);
      }

      try {
        const { taskStore } = getTaskStore(projectPath);
        const resolvedFromId = taskStore.resolveTaskId(fromId);
        const resolvedToId = taskStore.resolveTaskId(toId);
        taskStore.addDependency(resolvedFromId, resolvedToId, opts.type as "blocks" | "parent-child");
        const verb = opts.type === "blocks" ? "blocks" : "is parent of";
        console.log(
          chalk.green(
            `✓ Dependency added: '${formatTaskIdDisplay(resolvedFromId)}' ${verb} '${formatTaskIdDisplay(resolvedToId)}'.`,
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
  .action(async (id: string, opts: { project?: string; projectPath?: string }) => {
    const projectPath = await resolveProjectPathFromOptions(opts);

    try {
      const { taskStore } = getTaskStore(projectPath);
      const resolvedId = taskStore.resolveTaskId(id);

      const blockedBy = taskStore.getDependencies(resolvedId, "incoming") as DependencyRow[];
      const blocking = taskStore.getDependencies(resolvedId, "outgoing") as DependencyRow[];

      if (blockedBy.length === 0 && blocking.length === 0) {
        console.log(chalk.dim(`Task '${formatTaskIdDisplay(resolvedId)}' has no dependencies.`));
        return;
      }

      if (blockedBy.length > 0) {
        console.log(chalk.bold("\n  Blocked by:"));
        for (const dep of blockedBy) {
          console.log(chalk.yellow(`    [${dep.type}] ← ${formatTaskIdDisplay(dep.from_task_id)}`));
        }
      }

      if (blocking.length > 0) {
        console.log(chalk.bold("\n  Blocking:"));
        for (const dep of blocking) {
          console.log(chalk.dim(`    [${dep.type}] → ${formatTaskIdDisplay(dep.to_task_id)}`));
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
    async (fromId: string, toId: string, opts: { type: string; project?: string; projectPath?: string }) => {
      const projectPath = await resolveProjectPathFromOptions(opts);

      try {
        const { taskStore } = getTaskStore(projectPath);
        const resolvedFromId = taskStore.resolveTaskId(fromId);
        const resolvedToId = taskStore.resolveTaskId(toId);
        taskStore.removeDependency(resolvedFromId, resolvedToId, opts.type as "blocks" | "parent-child");
        console.log(
          chalk.green(
            `✓ Dependency removed: '${formatTaskIdDisplay(resolvedFromId)}' → '${formatTaskIdDisplay(resolvedToId)}'.`,
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
