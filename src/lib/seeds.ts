import { execFile } from "node:child_process";
import { access } from "node:fs/promises";
import { promisify } from "node:util";
import { join } from "node:path";
import type { ITaskClient, Issue, UpdateOptions } from "./task-client.js";

const execFileAsync = promisify(execFile);

const SD_PATH = join(
  process.env.HOME ?? "~",
  ".bun",
  "bin",
  "sd",
);

// ── Interfaces ──────────────────────────────────────────────────────────

export interface Seed {
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

export interface SeedDetail extends Seed {
  description: string | null;
  notes: string | null;
  acceptance: string | null;
  design: string | null;
  dependencies: string[];
  children: string[];
}

export interface SeedGraph {
  nodes: Seed[];
  edges: { from: string; to: string; type: string }[];
}

// ── Low-level helper ────────────────────────────────────────────────────

/**
 * Unwrap the sd CLI JSON envelope.
 *
 * sd wraps responses in `{ success, command, issues/issue/... }`.
 * This extracts the inner data so callers get arrays/objects directly:
 *   - `{ issues: [...] }` → returns the array
 *   - `{ issue: {...} }`  → returns the object
 *   - `{ success: false, error: "..." }` → throws
 *   - Everything else (primitives, bare arrays, no envelope) → pass-through
 */
export function unwrapSdResponse(raw: any): any {
  if (raw == null || typeof raw !== "object" || Array.isArray(raw)) return raw;

  // Check for failure envelope
  if (raw.success === false && raw.error) {
    throw new Error(raw.error);
  }

  // Unwrap known envelope keys
  if ("issues" in raw) return raw.issues;
  if ("issue" in raw) return raw.issue;

  // No known inner key — return the full envelope (e.g. create response)
  return raw;
}

export async function execSd(
  args: string[],
  cwd?: string,
): Promise<any> {
  const finalArgs = [...args, "--json"];
  try {
    const { stdout } = await execFileAsync(SD_PATH, finalArgs, {
      cwd,
      maxBuffer: 10 * 1024 * 1024,
    });
    const trimmed = stdout.trim();
    if (!trimmed) return undefined;
    return unwrapSdResponse(JSON.parse(trimmed));
  } catch (err: any) {
    // execFile rejects with code, stderr on non-zero exit
    const stderr = err.stderr?.trim() ?? "";
    const stdout = err.stdout?.trim() ?? "";
    const detail = stderr || stdout || err.message;
    throw new Error(`sd ${finalArgs.join(" ")} failed: ${detail}`);
  }
}



// ── Client ──────────────────────────────────────────────────────────────

export class SeedsClient implements ITaskClient {
  private projectPath: string;

  constructor(projectPath: string) {
    this.projectPath = projectPath;
  }

  /** Verify that the sd binary is reachable. */
  async ensureSdInstalled(): Promise<void> {
    try {
      await access(SD_PATH);
    } catch {
      throw new Error(
        `sd (seeds) CLI not found at ${SD_PATH}. ` +
          `Install via: bun install -g @os-eco/seeds-cli`,
      );
    }
  }

  /** Check whether .seeds/ exists in the project. */
  async isInitialized(): Promise<boolean> {
    try {
      await access(join(this.projectPath, ".seeds"));
      return true;
    } catch {
      return false;
    }
  }

  /** Run `sd init`. */
  async init(): Promise<void> {
    await this.ensureSdInstalled();
    await execSd(["init"], this.projectPath);
  }

  /** Create a new seed (task/epic/bug). Returns a Seed by fetching after create. */
  async create(
    title: string,
    opts?: {
      type?: string;
      priority?: string;
      parent?: string;
      description?: string;
      labels?: string[];
    },
  ): Promise<Seed> {
    await this.requireInit();
    const args = ["create", "--title", title];
    if (opts?.type) args.push("--type", opts.type);
    if (opts?.priority) args.push("--priority", opts.priority);
    if (opts?.parent) args.push("--parent", opts.parent);
    if (opts?.description) args.push("--description", opts.description);
    if (opts?.labels) args.push("--labels", opts.labels.join(","));
    const result = await execSd(args, this.projectPath);
    // sd create returns { success, command, id } — fetch full object
    const id = result?.id ?? result;
    if (typeof id === "string") {
      return await this.show(id) as unknown as Seed;
    }
    return result as Seed;
  }

  /** List seeds with optional filters. */
  async list(opts?: {
    status?: string;
    assignee?: string;
    type?: string;
  }): Promise<Seed[]> {
    await this.requireInit();
    const args = ["list"];
    if (opts?.status) args.push("--status", opts.status);
    if (opts?.assignee) args.push("--assignee", opts.assignee);
    if (opts?.type) args.push("--type", opts.type);
    return ((await execSd(args, this.projectPath)) as Seed[]) ?? [];
  }

  /** Return tasks whose blockers are all resolved. Satisfies ITaskClient.ready(). */
  async ready(): Promise<Issue[]> {
    await this.requireInit();
    return ((await execSd(["ready"], this.projectPath)) as Seed[]) ?? [];
  }

  /** Show full detail for one seed. */
  async show(id: string): Promise<SeedDetail> {
    await this.requireInit();
    return (await execSd(["show", id], this.projectPath)) as SeedDetail;
  }

  /** Update fields on a seed. Satisfies ITaskClient.update(). */
  async update(
    id: string,
    opts: UpdateOptions,
  ): Promise<void> {
    await this.requireInit();
    const args = ["update", id];
    if (opts.claim) args.push("--claim");
    if (opts.title) args.push("--title", opts.title);
    if (opts.status) args.push("--status", opts.status);
    if (opts.assignee) args.push("--assignee", opts.assignee);
    if (opts.description) args.push("--description", opts.description);
    if (opts.notes) args.push("--notes", opts.notes);
    await execSd(args, this.projectPath);
  }

  /** Close a seed, optionally with a reason. */
  async close(id: string, reason?: string): Promise<void> {
    await this.requireInit();
    const args = ["close", id];
    if (reason) args.push("--reason", reason);
    await execSd(args, this.projectPath);
  }

  /** Declare a dependency: childId depends on parentId. */
  async addDependency(childId: string, parentId: string): Promise<void> {
    await this.requireInit();
    await execSd(["dep", "add", childId, parentId], this.projectPath);
  }

  /** Get the dependency graph, optionally scoped to an epic. */
  async getGraph(epicId?: string): Promise<SeedGraph> {
    await this.requireInit();
    const args = ["graph"];
    if (epicId) args.push(epicId);
    return (await execSd(args, this.projectPath)) as SeedGraph;
  }

  /** Trigger seed compaction. */
  async compact(): Promise<void> {
    await this.requireInit();
    await execSd(["compact"], this.projectPath);
  }

  // ── Private helpers ─────────────────────────────────────────────────

  private async requireInit(): Promise<void> {
    await this.ensureSdInstalled();
    if (!(await this.isInitialized())) {
      throw new Error(
        `Seeds not initialised in ${this.projectPath}. Run 'foreman init' first.`,
      );
    }
  }
}

// TRD-025: deprecated aliases removed (BeadsClient, Bead, BeadDetail, BeadGraph, execBd)
