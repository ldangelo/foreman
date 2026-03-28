import { execFile } from "node:child_process";
import { access } from "node:fs/promises";
import { promisify } from "node:util";
import { join } from "node:path";
const execFileAsync = promisify(execFile);
const SD_PATH = join(process.env.HOME ?? "~", ".bun", "bin", "sd");
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
export function unwrapBdResponse(raw) {
    if (raw == null || typeof raw !== "object" || Array.isArray(raw))
        return raw;
    // Check for failure envelope
    if (raw.success === false && raw.error) {
        throw new Error(raw.error);
    }
    // Unwrap known envelope keys
    if ("issues" in raw)
        return raw.issues;
    if ("issue" in raw)
        return raw.issue;
    // No known inner key — return the full envelope (e.g. create response)
    return raw;
}
export async function execBd(args, cwd) {
    const finalArgs = [...args, "--json"];
    try {
        const { stdout } = await execFileAsync(SD_PATH, finalArgs, {
            cwd,
            maxBuffer: 10 * 1024 * 1024,
        });
        const trimmed = stdout.trim();
        if (!trimmed)
            return undefined;
        return unwrapBdResponse(JSON.parse(trimmed));
    }
    catch (err) {
        // execFile rejects with code, stderr on non-zero exit
        const stderr = err.stderr?.trim() ?? "";
        const stdout = err.stdout?.trim() ?? "";
        const detail = stderr || stdout || err.message;
        throw new Error(`sd ${finalArgs.join(" ")} failed: ${detail}`);
    }
}
// ── Client ──────────────────────────────────────────────────────────────
export class BeadsClient {
    projectPath;
    constructor(projectPath) {
        this.projectPath = projectPath;
    }
    /** Verify that the sd binary is reachable. */
    async ensureSdInstalled() {
        try {
            await access(SD_PATH);
        }
        catch {
            throw new Error(`sd (beads) CLI not found at ${SD_PATH}. ` +
                `Install via: bun install -g @os-eco/seeds-cli`);
        }
    }
    /** Check whether .seeds/ exists in the project. */
    async isInitialized() {
        try {
            await access(join(this.projectPath, ".seeds"));
            return true;
        }
        catch {
            return false;
        }
    }
    /** Run `sd init`. */
    async init() {
        await this.ensureSdInstalled();
        await execBd(["init"], this.projectPath);
    }
    /** Create a new bead (task/epic/bug). Returns a Bead by fetching after create. */
    async create(title, opts) {
        await this.requireInit();
        const args = ["create", "--title", title];
        if (opts?.type)
            args.push("--type", opts.type);
        if (opts?.priority)
            args.push("--priority", opts.priority);
        if (opts?.parent)
            args.push("--parent", opts.parent);
        if (opts?.description)
            args.push("--description", opts.description);
        if (opts?.labels)
            args.push("--labels", opts.labels.join(","));
        const result = await execBd(args, this.projectPath);
        // sd create returns { success, command, id } — fetch full object
        const id = result?.id ?? result;
        if (typeof id === "string") {
            return await this.show(id);
        }
        return result;
    }
    /** List beads with optional filters. */
    async list(opts) {
        await this.requireInit();
        const args = ["list"];
        if (opts?.status)
            args.push("--status", opts.status);
        if (opts?.assignee)
            args.push("--assignee", opts.assignee);
        if (opts?.type)
            args.push("--type", opts.type);
        return (await execBd(args, this.projectPath)) ?? [];
    }
    /** Return tasks whose blockers are all resolved. Satisfies ITaskClient.ready(). */
    async ready() {
        await this.requireInit();
        return (await execBd(["ready"], this.projectPath)) ?? [];
    }
    /** Show full detail for one bead. */
    async show(id) {
        await this.requireInit();
        return (await execBd(["show", id], this.projectPath));
    }
    /** Update fields on a bead. Satisfies ITaskClient.update(). */
    async update(id, opts) {
        await this.requireInit();
        const args = ["update", id];
        if (opts.claim)
            args.push("--claim");
        if (opts.title)
            args.push("--title", opts.title);
        if (opts.status)
            args.push("--status", opts.status);
        if (opts.assignee)
            args.push("--assignee", opts.assignee);
        if (opts.description)
            args.push("--description", opts.description);
        if (opts.notes)
            args.push("--notes", opts.notes);
        await execBd(args, this.projectPath);
    }
    /** Close a bead, optionally with a reason. */
    async close(id, reason) {
        await this.requireInit();
        const args = ["close", id];
        if (reason)
            args.push("--reason", reason);
        await execBd(args, this.projectPath);
    }
    /** Declare a dependency: childId depends on parentId. */
    async addDependency(childId, parentId) {
        await this.requireInit();
        await execBd(["dep", "add", childId, parentId], this.projectPath);
    }
    /** Get the dependency graph, optionally scoped to an epic. */
    async getGraph(epicId) {
        await this.requireInit();
        const args = ["graph"];
        if (epicId)
            args.push(epicId);
        return (await execBd(args, this.projectPath));
    }
    /** Trigger bead compaction. */
    async compact() {
        await this.requireInit();
        await execBd(["compact"], this.projectPath);
    }
    // ── Private helpers ─────────────────────────────────────────────────
    async requireInit() {
        await this.ensureSdInstalled();
        if (!(await this.isInitialized())) {
            throw new Error(`Beads not initialised in ${this.projectPath}. Run 'foreman init' first.`);
        }
    }
}
//# sourceMappingURL=beads.js.map