import { execFile } from "node:child_process";
import { access } from "node:fs/promises";
import { promisify } from "node:util";
import { join } from "node:path";

const execFileAsync = promisify(execFile);

const BD_PATH = join(
  process.env.HOME ?? "~",
  ".local",
  "bin",
  "bd",
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

export async function execBd(
  args: string[],
  cwd?: string,
): Promise<any> {
  const finalArgs = [...args, "--json"];
  try {
    const { stdout } = await execFileAsync(BD_PATH, finalArgs, {
      cwd,
      maxBuffer: 10 * 1024 * 1024,
    });
    const trimmed = stdout.trim();
    if (!trimmed) return undefined;
    return JSON.parse(trimmed);
  } catch (err: any) {
    // execFile rejects with code, stderr on non-zero exit
    const stderr = err.stderr?.trim() ?? err.message;
    throw new Error(`bd ${args[0]} failed: ${stderr}`);
  }
}

// ── Client ──────────────────────────────────────────────────────────────

export class BeadsClient {
  private projectPath: string;

  constructor(projectPath: string) {
    this.projectPath = projectPath;
  }

  /** Verify that the bd binary is reachable. */
  async ensureBdInstalled(): Promise<void> {
    try {
      await access(BD_PATH);
    } catch {
      throw new Error(
        `bd (beads) CLI not found at ${BD_PATH}. ` +
          `Install it or set a symlink so foreman can manage beads.`,
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

  /** Run `bd init`, optionally with a prefix. */
  async init(prefix?: string): Promise<void> {
    await this.ensureBdInstalled();
    const args = ["init"];
    if (prefix) args.push("--prefix", prefix);
    await execBd(args, this.projectPath);
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
    const args = ["create", title];
    if (opts?.type) args.push("--type", opts.type);
    if (opts?.priority) args.push("--priority", opts.priority);
    if (opts?.parent) args.push("--parent", opts.parent);
    if (opts?.description) args.push("--description", opts.description);
    if (opts?.labels) {
      for (const label of opts.labels) {
        args.push("--label", label);
      }
    }
    return (await execBd(args, this.projectPath)) as Bead;
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
    return ((await execBd(args, this.projectPath)) as Bead[]) ?? [];
  }

  /** Return tasks whose blockers are all resolved. */
  async ready(): Promise<Bead[]> {
    await this.requireInit();
    return ((await execBd(["ready"], this.projectPath)) as Bead[]) ?? [];
  }

  /** Show full detail for one bead. */
  async show(id: string): Promise<BeadDetail> {
    await this.requireInit();
    return (await execBd(["show", id], this.projectPath)) as BeadDetail;
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
    await execBd(args, this.projectPath);
  }

  /** Close a bead, optionally with a reason. */
  async close(id: string, reason?: string): Promise<void> {
    await this.requireInit();
    const args = ["close", id];
    if (reason) args.push("--reason", reason);
    await execBd(args, this.projectPath);
  }

  /** Declare a dependency: childId depends on parentId. */
  async addDependency(childId: string, parentId: string): Promise<void> {
    await this.requireInit();
    await execBd(["dep", "add", childId, parentId], this.projectPath);
  }

  /** Get the dependency graph, optionally scoped to an epic. */
  async getGraph(epicId?: string): Promise<BeadGraph> {
    await this.requireInit();
    const args = ["graph"];
    if (epicId) args.push(epicId);
    return (await execBd(args, this.projectPath)) as BeadGraph;
  }

  /** Trigger bead compaction. */
  async compact(): Promise<void> {
    await this.requireInit();
    await execBd(["compact"], this.projectPath);
  }

  // ── Private helpers ─────────────────────────────────────────────────

  private async requireInit(): Promise<void> {
    await this.ensureBdInstalled();
    if (!(await this.isInitialized())) {
      throw new Error(
        `Beads not initialised in ${this.projectPath}. Run 'foreman init' first.`,
      );
    }
  }
}
