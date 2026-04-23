import { execFile } from "node:child_process";
import { access } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";
import type { ITaskClient, Issue, UpdateOptions } from "./task-client.js";

const execFileAsync = promisify(execFile);

const BR_PATH = join(
  process.env.HOME ?? "~",
  ".local",
  "bin",
  "br",
);

// ── Interfaces ──────────────────────────────────────────────────────────

/**
 * @deprecated BeadsRustClient is deprecated — use NativeTaskStore via
 * `createTaskClient()` instead. The native task store requires no external binary
 * and uses the Postgres backing store managed by the Foreman daemon.
 * All native task operations are available via `src/lib/task-client.ts`.
 */
export interface BrIssue {
  id: string;
  title: string;
  type: string;
  priority: string;
  status: string;
  assignee: string | null;
  parent: string | null;
  created_at: string;
  updated_at: string;
}

/**
 * @deprecated BeadsRustClient is deprecated — use NativeTaskStore instead.
 * See deprecation note on `BrIssue`.
 */
export interface BrDepRef {
  id: string;
  title: string;
  status: string;
  priority: number;
  dependency_type: string;
}

/**
 * @deprecated BeadsRustClient is deprecated — use NativeTaskStore instead.
 * See deprecation note on `BrIssue`.
 */
export interface BrIssueDetail extends BrIssue {
  description: string | null;
  labels: string[];
  estimate_minutes: number | null;
  /** Beads this issue blocks (downstream dependents). Returned by `br show --json`. */
  dependents: BrDepRef[];
  /** Beads this issue depends on (upstream blockers). Returned by `br show --json`. */
  dependencies: BrDepRef[];
  /** @deprecated br show --json does not return a children field; use dependents instead */
  children?: string[];
  notes?: string | null;
}

/**
 * @deprecated BeadsRustClient is deprecated — use NativeTaskStore instead.
 * See deprecation note on `BrIssue`.
 */
export interface BrComment {
  id: number;
  issue_id: string;
  author: string;
  text: string;
  created_at: string;
}

// ── Low-level helper ────────────────────────────────────────────────────

/**
 * Normalize a single bead object: remap `issue_type` → `type` so all
 * downstream code can use the stable `BrIssue.type` field regardless of
 * which br command produced the object.
 */
function normalizeBead(item: unknown): unknown {
  if (item == null || typeof item !== "object" || Array.isArray(item)) return item;
  const obj = item as Record<string, unknown>;
  if ("issue_type" in obj && !("type" in obj)) {
    obj.type = obj.issue_type;
  }
  return obj;
}

/**
 * @deprecated BeadsRustClient is deprecated — use NativeTaskStore instead.
 * See deprecation note on `BrIssue`.
 */
export function unwrapBrResponse(raw: unknown): unknown {
  if (raw == null || typeof raw !== "object") return raw;

  // br list/ready return { issues: [...] } envelope
  if (!Array.isArray(raw)) {
    const obj = raw as Record<string, unknown>;
    if (obj.success === false && typeof obj.error === "string") {
      throw new Error(obj.error);
    }
    if ("issues" in obj && Array.isArray(obj.issues)) {
      return (obj.issues as unknown[]).map(normalizeBead);
    }
    if ("issue" in obj && obj.issue != null) return normalizeBead(obj.issue);
    // Single object (e.g. br create result) — normalize in place
    return normalizeBead(raw);
  }

  // Plain array (e.g. br show returns [{...}])
  return (raw as unknown[]).map(normalizeBead);
}

/**
 * @deprecated BeadsRustClient is deprecated — use NativeTaskStore instead.
 * See deprecation note on `BrIssue`.
 */
export async function execBr(
  args: string[],
  cwd?: string,
): Promise<unknown> {
  // --lock-timeout: wait up to 10s for SQLite lock instead of failing with SQLITE_BUSY
  // when concurrent agents hold read locks on .beads/beads.db.
  const finalArgs = [...args, "--json", "--lock-timeout", "10000"];
  try {
    const { stdout } = await execFileAsync(BR_PATH, finalArgs, {
      cwd,
      maxBuffer: 10 * 1024 * 1024,
    });
    const trimmed = stdout.trim();
    if (!trimmed) return undefined;
    return unwrapBrResponse(JSON.parse(trimmed));
  } catch (err: unknown) {
    const e = err as { stderr?: string; stdout?: string; message?: string };
    const stderr = e.stderr?.trim() ?? "";
    const stdout = e.stdout?.trim() ?? "";
    const detail = stderr || stdout || (e.message ?? "unknown error");
    throw new Error(`br ${finalArgs.join(" ")} failed: ${detail}`);
  }
}

// ── Client ──────────────────────────────────────────────────────────────

/**
 * @deprecated BeadsRustClient is deprecated — use NativeTaskStore via
 * `createTaskClient()` instead. The native task store requires no external binary,
 * uses the Postgres backing store managed by the Foreman daemon, and supports
 * concurrent agents without SQLite lock contention.
 *
 * Migration guide:
 *   Before: const client = new BeadsRustClient(projectPath);
 *   After:  const { taskClient } = await createTaskClient(projectPath);
 *
 * The `taskClient` returned by `createTaskClient()` implements `ITaskClient`
 * and uses the NativeTaskStore backed by the Foreman daemon's Postgres pool.
 */
export class BeadsRustClient implements ITaskClient {
  private projectPath: string;

  constructor(projectPath: string) {
    this.projectPath = projectPath;
  }

  /** Verify that the br binary is reachable. */
  async ensureBrInstalled(): Promise<void> {
    try {
      await access(BR_PATH);
    } catch {
      throw new Error(
        `br (beads_rust) CLI not found at ${BR_PATH}. ` +
          `Install via: cargo install beads_rust`,
      );
    }
  }

  /** Check whether .beads/ exists in the project. */
  async isInitialized(): Promise<boolean> {
    try {
      await access(join(this.projectPath, ".beads"));
      return true;
    } catch {
      return false;
    }
  }

  /** Create a new issue. Returns a BrIssue. */
  async create(
    title: string,
    opts?: {
      type?: string;
      priority?: string;
      parent?: string;
      description?: string;
      labels?: string[];
      estimate?: number;
    },
  ): Promise<BrIssue> {
    await this.requireInit();
    const args = ["create", "--title", title];
    if (opts?.type) args.push("--type", opts.type);
    if (opts?.priority) args.push("--priority", opts.priority);
    if (opts?.parent) args.push("--parent", opts.parent);
    if (opts?.description) args.push("--description", opts.description);
    if (opts?.labels) args.push("--labels", opts.labels.join(","));
    if (opts?.estimate != null) args.push("--estimate", String(opts.estimate));
    const result = await execBr(args, this.projectPath);
    // br create returns the issue directly or { id }
    const obj = result as Record<string, unknown>;
    const id = typeof obj?.id === "string" ? obj.id : undefined;
    if (id && !obj.title) {
      return await this.show(id) as unknown as BrIssue;
    }
    return result as BrIssue;
  }

  /** List issues with optional filters. */
  async list(opts?: {
    status?: string;
    type?: string;
    label?: string;
    limit?: number;
  }): Promise<BrIssue[]> {
    await this.requireInit();
    const args = ["list"];
    if (opts?.status) args.push("--status", opts.status);
    if (opts?.type) args.push("--type", opts.type);
    if (opts?.label) args.push("--label", opts.label);
    if (opts?.limit != null) args.push("--limit", String(opts.limit));
    return ((await execBr(args, this.projectPath)) as BrIssue[]) ?? [];
  }

  /** Show full detail for one issue. */
  async show(id: string): Promise<BrIssueDetail> {
    await this.requireInit();
    const result = await execBr(["show", id], this.projectPath);
    // br show returns an array with one element
    const item = Array.isArray(result) ? result[0] : result;
    return item as BrIssueDetail;
  }

  /** Update fields on an issue. Satisfies ITaskClient.update(). */
  async update(
    id: string,
    opts: UpdateOptions,
  ): Promise<void> {
    await this.requireInit();
    const args = ["update", id];
    if (opts.title) args.push("--title", opts.title);
    if (opts.status) args.push("--status", opts.status);
    if (opts.description) args.push("--description", opts.description);
    if (opts.notes) args.push("--notes", opts.notes);
    if (opts.acceptance) args.push("--acceptance", opts.acceptance);
    if (opts.claim) args.push("--claim");
    if (opts.labels && opts.labels.length > 0) args.push("--set-labels", opts.labels.join(","));
    await execBr(args, this.projectPath);
  }

  /** Close an issue, optionally with a reason. */
  async close(id: string, reason?: string): Promise<void> {
    await this.requireInit();
    const args = ["close", id];
    if (reason) args.push("--reason", reason);
    await execBr(args, this.projectPath);
  }

  /** Declare a dependency: childId depends on parentId. */
  async addDependency(childId: string, parentId: string): Promise<void> {
    await this.requireInit();
    await execBr(["dep", "add", childId, parentId], this.projectPath);
  }

  /** Return all open, unblocked issues (equivalent to `br ready`). Satisfies ITaskClient.ready(). */
  async ready(): Promise<Issue[]> {
    await this.requireInit();
    // Pass --limit 0 to get all ready issues (default is 20, which truncates the list
    // and causes lower-priority beads to be silently ignored by the dispatcher).
    return ((await execBr(["ready", "--limit", "0"], this.projectPath)) as BrIssue[]) ?? [];
  }

  /** Search issues by query string. */
  async search(query: string, opts?: {
    status?: string;
    label?: string;
  }): Promise<BrIssue[]> {
    await this.requireInit();
    const args = ["search", query];
    if (opts?.status) args.push("--status", opts.status);
    if (opts?.label) args.push("--label", opts.label);
    return ((await execBr(args, this.projectPath)) as BrIssue[]) ?? [];
  }

  /**
   * Fetch comments for an issue and return them as a formatted markdown string.
   * Returns null if there are no comments or the fetch fails.
   */
  async comments(id: string): Promise<string | null> {
    await this.requireInit();
    const result = await execBr(["comments", id], this.projectPath);
    const items = (Array.isArray(result) ? result : []) as BrComment[];
    if (items.length === 0) return null;
    return items
      .map((c) => `**${c.author}** (${c.created_at}):\n${c.text}`)
      .join("\n\n");
  }

  // ── Private helpers ─────────────────────────────────────────────────

  private async requireInit(): Promise<void> {
    await this.ensureBrInstalled();
    if (!(await this.isInitialized())) {
      throw new Error(
        `Beads not initialised in ${this.projectPath}. Run 'br init' first.`,
      );
    }
  }
}
