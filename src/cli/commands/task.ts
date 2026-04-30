/**
 * `foreman task` CLI commands — manage daemon-backed tasks in the Foreman task store.
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
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import chalk from "chalk";
import type { TaskDependencyRow as DependencyRow, TaskRow } from "../../lib/db/postgres-adapter.js";
import { resolveProjectPathFromOptions } from "./project-task-support.js";
import { createTrpcClient, type TrpcClient } from "../../lib/trpc-client.js";
import { listRegisteredProjects, type RegisteredProjectSummary } from "./project-task-support.js";
import type { PrState } from "../../lib/pr-state.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Column widths for the task table. */
const COL_ID = 14;
const COL_TITLE = 36;
const COL_TYPE = 10;
const COL_PRI = 12;
const COL_STATUS = 14;
const COL_PR = 10; // PR state: none/draft/open/merged/closed/mismatch
const COL_GAP = "  ";
const COMPACT_TASK_ID_SUFFIX_HEX_LENGTH = 5;

const TASK_STATUS_ORDER: Record<string, number> = {
  backlog: 0,
  blocked: 0,
  ready: 1,
  "in-progress": 2,
  explorer: 3,
  developer: 3,
  qa: 3,
  reviewer: 3,
  finalize: 4,
  merged: 5,
  closed: 5,
  conflict: -1,
  failed: -1,
  stuck: -1,
};

const ALL_TASK_STATUSES = Object.keys(TASK_STATUS_ORDER);
const VALID_TASK_TYPES = ["task", "bug", "feature", "epic", "chore", "docs", "question"];

interface TaskProjectContext {
  projectId: string;
  projectName: string;
  projectPath: string;
  client: TrpcClient;
}

function normalizeTaskIdPrefix(raw: string | null | undefined): string {
  const normalized = (raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return normalized.length > 0 ? normalized : "task";
}

function allocateTaskId(projectKey: string, existingIds: Set<string>): string {
  const prefix = normalizeTaskIdPrefix(projectKey);
  for (let attempt = 0; attempt < 64; attempt += 1) {
    const candidate = `${prefix}-${randomBytes(3).toString("hex").slice(0, COMPACT_TASK_ID_SUFFIX_HEX_LENGTH)}`;
    if (!existingIds.has(candidate)) {
      existingIds.add(candidate);
      return candidate;
    }
  }
  throw new Error(`Unable to allocate a unique task ID for prefix '${prefix}'.`);
}

function parsePriority(input: string): number {
  const normalized = input.trim().toLowerCase();
  if (/^[0-4]$/.test(normalized)) return Number(normalized);
  switch (normalized) {
    case "critical":
    case "p0":
      return 0;
    case "high":
    case "p1":
      return 1;
    case "medium":
    case "p2":
      return 2;
    case "low":
    case "p3":
      return 3;
    case "backlog":
    case "p4":
      return 4;
    default:
      throw new RangeError(`Invalid priority '${input}'.`);
  }
}

function priorityLabel(priority: number): string {
  switch (priority) {
    case 0:
      return "critical";
    case 1:
      return "high";
    case 2:
      return "medium";
    case 3:
      return "low";
    case 4:
      return "backlog";
    default:
      return String(priority);
  }
}

function formatTaskIdDisplay(taskId: string): string {
  return taskId.length <= 16 ? taskId : `${taskId.slice(0, 8)}…`;
}

async function resolveTaskProjectContext(
  opts: { project?: string; projectPath?: string },
): Promise<TaskProjectContext> {
  const projectPath = resolve(await resolveProjectPathFromOptions(opts));
  const projects = await listRegisteredProjects();
  const record = projects.find((project) => resolve(project.path) === projectPath);
  if (!record) {
    throw new Error(
      `Project at '${projectPath}' is not registered with the daemon. Run 'foreman project list' to see registered projects.`,
    );
  }

  return {
    projectId: record.id,
    projectName: record.name,
    projectPath,
    client: createTrpcClient(),
  };
}

async function listAllTasks(client: TrpcClient, projectId: string): Promise<TaskRow[]> {
  return await client.tasks.list({ projectId, limit: 1000 }) as TaskRow[];
}

function resolveTaskId(rows: TaskRow[], taskIdOrPrefix: string): string {
  const exact = rows.find((row) => row.id === taskIdOrPrefix);
  if (exact) {
    return exact.id;
  }
  const matches = rows.filter((row) => row.id.startsWith(taskIdOrPrefix));
  if (matches.length === 0) {
    throw new Error(`Task '${taskIdOrPrefix}' not found.`);
  }
  if (matches.length > 1) {
    throw new Error(`Ambiguous task ID prefix '${taskIdOrPrefix}'.`);
  }
  return matches[0].id;
}

function isBackwardStatusTransition(fromStatus: string, toStatus: string): boolean {
  const fromOrder = TASK_STATUS_ORDER[fromStatus] ?? 0;
  const toOrder = TASK_STATUS_ORDER[toStatus] ?? 0;
  return toOrder >= 0 && fromOrder > toOrder;
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

/**
 * Render a PR state badge for display in task list.
 */
function renderPrBadge(prState: PrState | undefined): string {
  if (!prState) return chalk.dim("—");
  switch (prState.status) {
    case "none":
      return chalk.dim("no PR");
    case "open":
      return chalk.green(`#${prState.number}`);
    case "merged":
      if (prState.isStale) {
        return chalk.yellow(`#${prState.number} (stale)`);
      }
      return chalk.cyan(`#${prState.number}`);
    case "closed":
      return chalk.dim(`#${prState.number} (closed)`);
    case "error":
      return chalk.red("?");
    default:
      return chalk.dim("—");
  }
}

function printTaskTable(rows: TaskRow[], prStates?: Map<string, PrState>): void {
  if (rows.length === 0) {
    console.log(chalk.dim("No tasks found."));
    return;
  }

  const idWidth = Math.max(COL_ID, ...rows.map((row) => row.id.length));
  const showPr = prStates !== undefined;

  // Header
  const prHeader = showPr ? COL_GAP + chalk.bold(pad("PR", 12)) : "";
  console.log(
    chalk.bold(pad("ID", idWidth)) +
      COL_GAP +
      chalk.bold(pad("TITLE", COL_TITLE)) +
      COL_GAP +
      chalk.bold(pad("TYPE", COL_TYPE)) +
      COL_GAP +
      chalk.bold(pad("PRIORITY", COL_PRI)) +
      COL_GAP +
      chalk.bold("STATUS") +
      prHeader,
  );

  const prColWidth = 12;
  const separatorLen = idWidth + COL_TITLE + COL_TYPE + COL_PRI + COL_STATUS + (COL_GAP.length * 4) + (showPr ? prColWidth + COL_GAP.length : 0);
  console.log("─".repeat(separatorLen));

  for (const t of rows) {
    const prState = prStates?.get(t.id);
    const prBadge = renderPrBadge(prState);
    const prCell = showPr ? COL_GAP + pad(prBadge, prColWidth) : "";
    console.log(
      chalk.dim(t.id.padEnd(idWidth)) +
        COL_GAP +
        renderColumn(t.title, COL_TITLE) +
        COL_GAP +
        renderColumn(t.type, COL_TYPE, chalk.dim) +
        COL_GAP +
        renderColumn(priorityLabel(t.priority), COL_PRI, (text) => colorPriority(text, t.priority)) +
        COL_GAP +
        renderColumn(t.status, COL_STATUS, statusChalk) +
        prCell,
    );
  }
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

export async function performBeadsImport(
  projectPath: string,
  opts: { dryRun?: boolean } = {},
): Promise<TaskImportResult> {
  const jsonlPath = resolveBeadsImportPath(projectPath);
  const beads = parseBeadsJsonl(jsonlPath);
  const { client, projectId, projectName } = await resolveTaskProjectContext({ projectPath });
  const now = new Date().toISOString();
  const existingRows = await listAllTasks(client, projectId);
  const existingIds = new Set(existingRows.map((row) => row.id));

  const existingByExternalId = new Map<string, string>();
  for (const row of existingRows) {
    if (row.external_id) {
      existingByExternalId.set(row.external_id, row.id);
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

    const existingId = existingByExternalId.get(bead.id);
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
      nativeId: allocateTaskId(projectName, existingIds),
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
    for (const record of prepared) {
      await client.tasks.create({
        projectId,
        id: record.nativeId,
        title: record.bead.title,
        description: record.bead.description ?? undefined,
        type: record.type,
        priority: record.priority,
        status: record.status,
        externalId: record.bead.id,
        createdAt: record.createdAt,
        updatedAt: record.updatedAt,
        approvedAt: record.approvedAt ?? undefined,
        closedAt: record.closedAt ?? undefined,
      });
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
        await client.tasks.addDependency({
          projectId,
          fromTaskId: blockerId,
          toTaskId: fromTaskId,
          type: dependencyType,
        });
      }
    }
  }

  return {
    imported: prepared.length,
    duplicateSkips,
    unsupportedStatusSkips,
    jsonlPath,
    preview: prepared,
  };
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

      if (!VALID_TASK_TYPES.includes(opts.type)) {
        console.error(
          chalk.red(
            `Error: Invalid type '${opts.type}'. Valid types: ${VALID_TASK_TYPES.join(", ")}`,
          ),
        );
        process.exit(1);
      }

      try {
        const { client, projectId, projectName } = await resolveTaskProjectContext(opts);
        const existingIds = new Set((await listAllTasks(client, projectId)).map((task) => task.id));
        const taskId = allocateTaskId(projectName, existingIds);
        const task = await client.tasks.create({
          projectId,
          id: taskId,
          title: opts.title,
          description: opts.description,
          type: opts.type,
          priority,
        });
        const createdTask = task as TaskRow;

        console.log(
          chalk.green(`✓ Task created`) + chalk.dim(` [${createdTask.id}]`),
        );
        console.log(`  Title:    ${createdTask.title}`);
        console.log(`  Type:     ${createdTask.type}`);
        console.log(`  Priority: ${priorityLabel(createdTask.priority)}`);
        console.log(`  Status:   ${createdTask.status}`);
        console.log(
          chalk.dim(`\n  Run 'foreman task approve ${createdTask.id}' to make it ready for dispatch.`),
        );
      } catch (err) {
        console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
        process.exit(1);
      }
    },
  );

// ── foreman task list ─────────────────────────────────────────────────────────

const listCommand = new Command("list")
  .description("List tasks from the daemon-backed task store")
  .option("--status <status>", "Filter by status (e.g. ready, backlog, in-progress)")
  .option("--type <type>", "Filter by type (e.g. epic, bug, feature, task)")
  .option("--all", "Include closed and merged tasks (excluded by default)")
  .option("--show-pr", "Show GitHub PR state for each task")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (opts: { status?: string; type?: string; all?: boolean; showPr?: boolean; project?: string; projectPath?: string }) => {
    try {
      const { client, projectId } = await resolveTaskProjectContext(opts);
      let rows = await listAllTasks(client, projectId);

      if (opts.status) {
        rows = rows.filter((row) => row.status === opts.status);
      } else if (!opts.all) {
        rows = rows.filter((row) => row.status !== "closed" && row.status !== "merged");
      }

      if (opts.type) {
        rows = rows.filter((row) => row.type === opts.type);
      }

      rows = [...rows].sort(
        (a, b) => a.priority - b.priority || a.created_at.localeCompare(b.created_at),
      );

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

      // Fetch PR states if --show-pr is specified
      let prStates: Map<string, PrState> | undefined;
      if (opts.showPr) {
        prStates = new Map<string, PrState>();
        await Promise.all(
          rows.map(async (task) => {
            try {
              const prState = await client.tasks.getPrState({ projectId, taskId: task.id }) as PrState;
              prStates!.set(task.id, prState);
            } catch {
              // PR state fetch failed - leave as undefined
            }
          })
        );
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
      printTaskTable(rows, prStates);
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
    try {
      const { client, projectId } = await resolveTaskProjectContext(opts);
      const rows = await listAllTasks(client, projectId);
      const resolvedId = resolveTaskId(rows, id);
      const task = await client.tasks.get({ projectId, taskId: resolvedId }) as TaskRow | null;
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

      // Show PR state
      try {
        const prState = await client.tasks.getPrState({ projectId, taskId: task.id }) as PrState;
        if (prState) {
          console.log(chalk.bold("\n  Pull Request:"));
          console.log(`    Status:     ${renderPrBadge(prState)}`);
          if (prState.url) {
            console.log(`    URL:        ${prState.url}`);
          }
          if (prState.number) {
            console.log(`    Number:     #${prState.number}`);
          }
          if (prState.headSha) {
            console.log(`    PR Head:    ${chalk.dim(prState.headSha.slice(0, 12))}`);
          }
          if (prState.currentHeadSha) {
            console.log(`    Branch Head: ${chalk.dim(prState.currentHeadSha.slice(0, 12))}`);
          }
          if (prState.isStale) {
            console.log(chalk.yellow(`    ⚠ Stale:    PR merged but branch has been updated since`));
          }
          if (prState.error) {
            console.log(chalk.red(`    Error:      ${prState.error}`));
          }
        }
      } catch {
        // PR state fetch failed - don't show anything
      }

      // Show dependencies
      const outgoing = await client.tasks.listDependencies({
        projectId,
        taskId: task.id,
        direction: "outgoing",
      }) as DependencyRow[];
      const incoming = await client.tasks.listDependencies({
        projectId,
        taskId: task.id,
        direction: "incoming",
      }) as DependencyRow[];

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
    try {
      const { client, projectId } = await resolveTaskProjectContext(opts);
      const rows = await listAllTasks(client, projectId);
      const resolvedId = resolveTaskId(rows, id);
      const task = await client.tasks.approve({ projectId, taskId: resolvedId }) as TaskRow | null;
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
        const { client, projectId } = await resolveTaskProjectContext(opts);
        const rows = await listAllTasks(client, projectId);
        const resolvedId = resolveTaskId(rows, id);

        if (updateOpts.status !== undefined && !updateOpts.force) {
          const current = rows.find((row) => row.id === resolvedId);
          if (current && isBackwardStatusTransition(current.status, updateOpts.status)) {
            console.error(
              chalk.red(
                `Error: Task '${formatTaskIdDisplay(resolvedId)}' cannot transition from '${current.status}' to '${updateOpts.status}'.`,
              ),
            );
            console.error(chalk.dim("  Use --force to override this check."));
            process.exit(1);
          }
        }

        const task = await client.tasks.update({
          projectId,
          taskId: resolvedId,
          updates: {
            title: updateOpts.title,
            description: updateOpts.description ?? undefined,
            priority: updateOpts.priority,
            status: updateOpts.status,
          },
        }) as TaskRow | null;
        if (!task) {
          throw new Error(`Task '${resolvedId}' not found.`);
        }

        console.log(chalk.green(`✓ Task '${formatTaskIdDisplay(resolvedId)}' updated.`));
        console.log(`  Title:    ${task.title}`);
        console.log(`  Type:     ${task.type}`);
        console.log(`  Priority: ${priorityLabel(task.priority)}`);
        console.log(`  Status:   ${statusChalk(task.status)}`);
        if (task.description) {
          console.log(`  Description: ${task.description}`);
        }
      } catch (err) {
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
    try {
      const { client, projectId } = await resolveTaskProjectContext(opts);
      const rows = await listAllTasks(client, projectId);
      const resolvedId = resolveTaskId(rows, id);
      await client.tasks.close({ projectId, taskId: resolvedId });

      console.log(chalk.green(`✓ Task '${formatTaskIdDisplay(resolvedId)}' closed.`));
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

// ── foreman task import ───────────────────────────────────────────────────────

const importCommand = new Command("import")
  .description("Import legacy beads JSONL data into the daemon-backed task store")
  .requiredOption("--from-beads", "Import tasks from .beads/issues.jsonl or .beads/beads.jsonl")
  .option("--dry-run", "Preview the first 5 mappings without writing to the database")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (opts: { fromBeads: boolean; dryRun?: boolean; project?: string; projectPath?: string }) => {
    const projectPath = await resolveProjectPathFromOptions(opts);

    try {
      const result = await performBeadsImport(projectPath, { dryRun: opts.dryRun });
      if (opts.dryRun) {
        summarizeImportPreview(result.preview);
        console.log(
          chalk.green(
            `Would import ${result.imported} tasks (${result.duplicateSkips} skipped: already exist by external_id${result.unsupportedStatusSkips > 0 ? `, ${result.unsupportedStatusSkips} skipped: unsupported status` : ""}).`,
          ),
        );
        return;
      }
      console.log(
        chalk.green(
            `Imported ${result.imported} tasks (${result.duplicateSkips} skipped: already exist by external_id${result.unsupportedStatusSkips > 0 ? `, ${result.unsupportedStatusSkips} skipped: unsupported status` : ""}).`,
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
      if (opts.type !== "blocks" && opts.type !== "parent-child") {
        console.error(
          chalk.red(`Error: Invalid type '${opts.type}'. Use 'blocks' or 'parent-child'.`),
        );
        process.exit(1);
      }

      try {
        const { client, projectId } = await resolveTaskProjectContext(opts);
        const rows = await listAllTasks(client, projectId);
        const resolvedFromId = resolveTaskId(rows, fromId);
        const resolvedToId = resolveTaskId(rows, toId);
        await client.tasks.addDependency({
          projectId,
          fromTaskId: resolvedFromId,
          toTaskId: resolvedToId,
          type: opts.type as "blocks" | "parent-child",
        });
        const verb = opts.type === "blocks" ? "blocks" : "is parent of";
        console.log(
          chalk.green(
            `✓ Dependency added: '${formatTaskIdDisplay(resolvedFromId)}' ${verb} '${formatTaskIdDisplay(resolvedToId)}'.`,
          ),
        );
      } catch (err) {
        if (err instanceof Error && err.message.includes("circular dependency")) {
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
    try {
      const { client, projectId } = await resolveTaskProjectContext(opts);
      const rows = await listAllTasks(client, projectId);
      const resolvedId = resolveTaskId(rows, id);

      const blockedBy = await client.tasks.listDependencies({
        projectId,
        taskId: resolvedId,
        direction: "incoming",
      }) as DependencyRow[];
      const blocking = await client.tasks.listDependencies({
        projectId,
        taskId: resolvedId,
        direction: "outgoing",
      }) as DependencyRow[];

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
      try {
        const { client, projectId } = await resolveTaskProjectContext(opts);
        const rows = await listAllTasks(client, projectId);
        const resolvedFromId = resolveTaskId(rows, fromId);
        const resolvedToId = resolveTaskId(rows, toId);
        await client.tasks.removeDependency({
          projectId,
          fromTaskId: resolvedFromId,
          toTaskId: resolvedToId,
          type: opts.type as "blocks" | "parent-child",
        });
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
  .description("Manage daemon-backed tasks in Foreman")
  .addCommand(createCommand)
  .addCommand(listCommand)
  .addCommand(showCommand)
  .addCommand(importCommand)
  .addCommand(approveCommand)
  .addCommand(updateCommand)
  .addCommand(closeCommand)
  .addCommand(depCommand);
