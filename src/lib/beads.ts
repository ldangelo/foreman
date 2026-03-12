import { execFile } from "node:child_process";
import { access } from "node:fs/promises";
import { promisify } from "node:util";
import { join } from "node:path";

const execFileAsync = promisify(execFile);

const SD_PATH = join(
  process.env.HOME ?? "~",
  ".bun",
  "bin",
  "sd",
);

// ── Interfaces ──────────────────────────────────────────────────────────

export interface Bead {
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

export interface BeadDetail extends Bead {
  description: string | null;
  notes: string | null;
  acceptance: string | null;
  design: string | null;
  dependencies: string[];
  children: string[];
}

export interface BeadGraph {
  nodes: Bead[];
  edges: { from: string; to: string; type: string }[];
}

// ── Low-level helper ────────────────────────────────────────────────────

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
    return JSON.parse(trimmed);
  } catch (err: any) {
    // execFile rejects with code, stderr on non-zero exit
    const stderr = err.stderr?.trim() ?? "";
    const stdout = err.stdout?.trim() ?? "";
    const detail = stderr || stdout || err.message;
    throw new Error(`sd ${finalArgs.join(" ")} failed: ${detail}`);
  }
}

/** @deprecated Use execSd instead */
export const execBd = execSd;

// ── Client ──────────────────────────────────────────────────────────────

export class BeadsClient {
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

  /** Create a new bead (task/epic/bug). */
  async create(
    title: string,
    opts?: {
      type?: string;
      priority?: string;
      parent?: string;
      description?: string;
      labels?: string[];
    },
  ): Promise<Bead> {
    await this.requireInit();
    const args = ["create", "--title", title];
    if (opts?.type) args.push("--type", opts.type);
    if (opts?.priority) args.push("--priority", opts.priority);
    if (opts?.description) args.push("--description", opts.description);
    if (opts?.labels) args.push("--labels", opts.labels.join(","));
    return (await execSd(args, this.projectPath)) as Bead;
  }

  /** List beads with optional filters. */
  async list(opts?: {
    status?: string;
    assignee?: string;
    type?: string;
  }): Promise<Bead[]> {
    await this.requireInit();
    const args = ["list"];
    if (opts?.status) args.push("--status", opts.status);
    if (opts?.assignee) args.push("--assignee", opts.assignee);
    if (opts?.type) args.push("--type", opts.type);
    return ((await execSd(args, this.projectPath)) as Bead[]) ?? [];
  }

  /** Return tasks whose blockers are all resolved. */
  async ready(): Promise<Bead[]> {
    await this.requireInit();
    return ((await execSd(["ready"], this.projectPath)) as Bead[]) ?? [];
  }

  /** Show full detail for one bead. */
  async show(id: string): Promise<BeadDetail> {
    await this.requireInit();
    return (await execSd(["show", id], this.projectPath)) as BeadDetail;
  }

  /** Update fields on a bead. */
  async update(
    id: string,
    opts: {
      claim?: boolean;
      title?: string;
      status?: string;
      assignee?: string;
      description?: string;
      notes?: string;
    },
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

  /** Close a bead, optionally with a reason. */
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
  async getGraph(epicId?: string): Promise<BeadGraph> {
    await this.requireInit();
    const args = ["graph"];
    if (epicId) args.push(epicId);
    return (await execSd(args, this.projectPath)) as BeadGraph;
  }

  /** Trigger bead compaction. */
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
