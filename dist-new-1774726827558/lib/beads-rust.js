import { execFile } from "node:child_process";
import { access } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";
const execFileAsync = promisify(execFile);
const BR_PATH = join(process.env.HOME ?? "~", ".local", "bin", "br");
// ── Low-level helper ────────────────────────────────────────────────────
/**
 * Unwrap the br CLI JSON response.
 *
 * br returns objects directly (not wrapped in an envelope like sd).
 * Arrays are returned as-is.  On failure, br exits non-zero (caught in execBr).
 */
export function unwrapBrResponse(raw) {
    if (raw == null || typeof raw !== "object")
        return raw;
    // br list returns array directly
    if (Array.isArray(raw))
        return raw;
    // br create returns { id, ... } directly — check for error field
    const obj = raw;
    if (obj.success === false && typeof obj.error === "string") {
        throw new Error(obj.error);
    }
    // Unwrap known envelope keys (br may use these in some versions)
    if ("issues" in obj && Array.isArray(obj.issues))
        return obj.issues;
    if ("issue" in obj && obj.issue != null)
        return obj.issue;
    return raw;
}
export async function execBr(args, cwd) {
    const finalArgs = [...args, "--json"];
    try {
        const { stdout } = await execFileAsync(BR_PATH, finalArgs, {
            cwd,
            maxBuffer: 10 * 1024 * 1024,
        });
        const trimmed = stdout.trim();
        if (!trimmed)
            return undefined;
        return unwrapBrResponse(JSON.parse(trimmed));
    }
    catch (err) {
        const e = err;
        const stderr = e.stderr?.trim() ?? "";
        const stdout = e.stdout?.trim() ?? "";
        const detail = stderr || stdout || (e.message ?? "unknown error");
        throw new Error(`br ${finalArgs.join(" ")} failed: ${detail}`);
    }
}
// ── Client ──────────────────────────────────────────────────────────────
export class BeadsRustClient {
    projectPath;
    constructor(projectPath) {
        this.projectPath = projectPath;
    }
    /** Verify that the br binary is reachable. */
    async ensureBrInstalled() {
        try {
            await access(BR_PATH);
        }
        catch {
            throw new Error(`br (beads_rust) CLI not found at ${BR_PATH}. ` +
                `Install via: cargo install beads_rust`);
        }
    }
    /** Check whether .beads/ exists in the project. */
    async isInitialized() {
        try {
            await access(join(this.projectPath, ".beads"));
            return true;
        }
        catch {
            return false;
        }
    }
    /** Create a new issue. Returns a BrIssue. */
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
        if (opts?.estimate != null)
            args.push("--estimate", String(opts.estimate));
        const result = await execBr(args, this.projectPath);
        // br create returns the issue directly or { id }
        const obj = result;
        const id = typeof obj?.id === "string" ? obj.id : undefined;
        if (id && !obj.title) {
            return await this.show(id);
        }
        return result;
    }
    /** List issues with optional filters. */
    async list(opts) {
        await this.requireInit();
        const args = ["list"];
        if (opts?.status)
            args.push("--status", opts.status);
        if (opts?.type)
            args.push("--type", opts.type);
        if (opts?.label)
            args.push("--label", opts.label);
        if (opts?.limit != null)
            args.push("--limit", String(opts.limit));
        return (await execBr(args, this.projectPath)) ?? [];
    }
    /** Show full detail for one issue. */
    async show(id) {
        await this.requireInit();
        const result = await execBr(["show", id], this.projectPath);
        // br show returns an array with one element
        const item = Array.isArray(result) ? result[0] : result;
        return item;
    }
    /** Update fields on an issue. Satisfies ITaskClient.update(). */
    async update(id, opts) {
        await this.requireInit();
        const args = ["update", id];
        if (opts.title)
            args.push("--title", opts.title);
        if (opts.status)
            args.push("--status", opts.status);
        if (opts.description)
            args.push("--description", opts.description);
        if (opts.notes)
            args.push("--notes", opts.notes);
        if (opts.acceptance)
            args.push("--acceptance", opts.acceptance);
        if (opts.claim)
            args.push("--claim");
        if (opts.labels && opts.labels.length > 0)
            args.push("--set-labels", opts.labels.join(","));
        await execBr(args, this.projectPath);
    }
    /** Close an issue, optionally with a reason. */
    async close(id, reason) {
        await this.requireInit();
        const args = ["close", id];
        if (reason)
            args.push("--reason", reason);
        await execBr(args, this.projectPath);
    }
    /** Declare a dependency: childId depends on parentId. */
    async addDependency(childId, parentId) {
        await this.requireInit();
        await execBr(["dep", "add", childId, parentId], this.projectPath);
    }
    /** Return all open, unblocked issues (equivalent to `br ready`). Satisfies ITaskClient.ready(). */
    async ready() {
        await this.requireInit();
        // Pass --limit 0 to get all ready issues (default is 20, which truncates the list
        // and causes lower-priority beads to be silently ignored by the dispatcher).
        return (await execBr(["ready", "--limit", "0"], this.projectPath)) ?? [];
    }
    /** Search issues by query string. */
    async search(query, opts) {
        await this.requireInit();
        const args = ["search", query];
        if (opts?.status)
            args.push("--status", opts.status);
        if (opts?.label)
            args.push("--label", opts.label);
        return (await execBr(args, this.projectPath)) ?? [];
    }
    /**
     * Fetch comments for an issue and return them as a formatted markdown string.
     * Returns null if there are no comments or the fetch fails.
     */
    async comments(id) {
        await this.requireInit();
        const result = await execBr(["comments", id], this.projectPath);
        const items = (Array.isArray(result) ? result : []);
        if (items.length === 0)
            return null;
        return items
            .map((c) => `**${c.author}** (${c.created_at}):\n${c.text}`)
            .join("\n\n");
    }
    // ── Private helpers ─────────────────────────────────────────────────
    async requireInit() {
        await this.ensureBrInstalled();
        if (!(await this.isInitialized())) {
            throw new Error(`Beads not initialised in ${this.projectPath}. Run 'br init' first.`);
        }
    }
}
//# sourceMappingURL=beads-rust.js.map