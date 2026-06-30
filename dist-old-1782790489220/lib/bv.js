import { execFile } from "node:child_process";
import { join } from "node:path";
import { promisify } from "node:util";
const execFileAsync = promisify(execFile);
const HOME = process.env.HOME ?? "~";
const BV_PATH = join(HOME, ".local", "bin", "bv");
const BR_PATH = join(HOME, ".local", "bin", "br");
// bv timeout: 10s to handle large projects (400+ issues) and concurrent DB access
const DEFAULT_TIMEOUT_MS = 10_000;
// ── BvClient ─────────────────────────────────────────────────────────────────
/**
 * ADR-002: BvClient exposes ONLY typed robot-* methods.
 * There is NO public exec/run/execBv method — this enforces at the TypeScript
 * level that bare `bv` invocations (which open an interactive TUI) can never
 * happen from application code.
 *
 * ADR-003: Every method returns null on ANY failure (binary missing, timeout,
 * non-zero exit, parse error).  It never throws.
 */
export class BvClient {
    projectPath;
    timeoutMs;
    errorLogged = false;
    constructor(projectPath, opts) {
        this.projectPath = projectPath;
        this.timeoutMs = opts?.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    }
    /** Returns the single highest-priority actionable task. */
    async robotNext() {
        const raw = await this._execBv("next");
        if (raw === null)
            return null;
        try {
            const parsed = JSON.parse(raw);
            if (typeof parsed.id !== "string")
                return null;
            return parsed;
        }
        catch {
            return null;
        }
    }
    /** Returns full triage output with recommendations and quick_ref. */
    async robotTriage() {
        const raw = await this._execBv("triage");
        if (raw === null)
            return null;
        try {
            const parsed = JSON.parse(raw);
            if (!Array.isArray(parsed.recommendations))
                return null;
            return parsed;
        }
        catch {
            return null;
        }
    }
    /** Returns parallel execution plan tracks. */
    async robotPlan() {
        const raw = await this._execBv("plan");
        if (raw === null)
            return null;
        try {
            return JSON.parse(raw);
        }
        catch {
            return null;
        }
    }
    /** Returns full graph metrics (PageRank, betweenness, HITS, etc.). */
    async robotInsights() {
        const raw = await this._execBv("insights");
        if (raw === null)
            return null;
        try {
            return JSON.parse(raw);
        }
        catch {
            return null;
        }
    }
    /** Returns stale issues, blocking cascades, and priority mismatches. */
    async robotAlerts() {
        const raw = await this._execBv("alerts");
        if (raw === null)
            return null;
        try {
            return JSON.parse(raw);
        }
        catch {
            return null;
        }
    }
    // ── Private (prefixed with _ per project convention) ─────────────────────
    /**
     * Core execution method.  Prefixed `_execBv` so it is easily identifiable
     * as private-by-convention (ADR-002: no public execBv surface).
     *
     * Steps:
     *   1. Run `br sync --flush-only` to ensure bv reads fresh data.
     *   2. Run `bv --robot-{flag} --format toon [extraArgs]` with timeout.
     *   3. Return raw stdout string, or null on any error.
     */
    async _execBv(robotFlag, extraArgs) {
        // Step 1: sync br before every bv call
        await this._runBrSync();
        // Step 2: invoke bv — always use --format toon (ADR-003: no override path)
        const args = [
            `--robot-${robotFlag}`,
            "--format",
            "toon",
            ...(extraArgs ?? []),
        ];
        try {
            const { stdout } = await execFileAsync(BV_PATH, args, {
                cwd: this.projectPath,
                timeout: this.timeoutMs,
                maxBuffer: 10 * 1024 * 1024,
            });
            return stdout.trim() || null;
        }
        catch (err) {
            if (!this.errorLogged) {
                const msg = err instanceof Error ? err.message : String(err);
                const isTimeout = msg.includes("ETIMEDOUT") || msg.includes("killed");
                console.error(`[bv] ${robotFlag} failed${isTimeout ? " (timeout)" : ""}: ${msg.slice(0, 200)}`);
                this.errorLogged = true;
            }
            return null;
        }
    }
    /** Runs `br sync --flush-only` silently; failure is ignored. */
    async _runBrSync() {
        try {
            await execFileAsync(BR_PATH, ["sync", "--flush-only"], {
                cwd: this.projectPath,
                timeout: this.timeoutMs,
                maxBuffer: 1024 * 1024,
            });
        }
        catch {
            // Ignore — bv may still work even if sync fails
        }
    }
}
//# sourceMappingURL=bv.js.map