/**
 * SentinelAgent — continuous testing agent for main/master branch.
 *
 * Runs the test suite on the specified branch on a configurable schedule.
 * Records results in Postgres and creates br bug tasks on repeated failures.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { randomUUID } from "node:crypto";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";
const execFileAsync = promisify(execFile);
/**
 * Continuous testing agent that monitors a branch on a schedule.
 *
 * Usage:
 *   const agent = new SentinelAgent(store, seeds, projectId, projectPath);
 *   agent.start(opts, (result) => console.log(result));
 *   // later...
 *   agent.stop();
 */
export class SentinelAgent {
    store;
    seeds;
    projectId;
    projectPath;
    vcsBackend;
    running = false;
    timer = null;
    consecutiveFailures = 0;
    constructor(store, seeds, projectId, projectPath, vcsBackend) {
        this.store = store;
        this.seeds = seeds;
        this.projectId = projectId;
        this.projectPath = projectPath;
        this.vcsBackend = vcsBackend;
    }
    /**
     * Execute one sentinel run: fetch HEAD commit, run tests, record results.
     */
    async runOnce(opts) {
        const runId = randomUUID();
        const startedAt = new Date().toISOString();
        const startMs = Date.now();
        // Insert a running record so status is visible immediately. Sentinel events
        // reference sentinel_runs(id), so the run row must exist before logging.
        await this.store.recordSentinelRun({
            id: runId,
            project_id: this.projectId,
            branch: opts.branch,
            commit_hash: null,
            status: "running",
            test_command: opts.testCommand,
            output: null,
            started_at: startedAt,
            completed_at: null,
        });
        // Log start event
        await this.store.logEvent(this.projectId, "sentinel-start", {
            runId,
            branch: opts.branch,
            testCommand: opts.testCommand,
        });
        let commitHash = null;
        let output = "";
        let status = "error";
        try {
            if (!opts.dryRun) {
                // Resolve HEAD commit for the branch
                commitHash = await this.resolveCommit(opts.branch);
                // Run the test suite
                const testResult = await this.runTestCommand(opts.testCommand);
                output = testResult.output;
                status = testResult.status;
            }
            else {
                output = `[dry-run] Would run: ${opts.testCommand} on branch ${opts.branch}`;
                status = "passed";
            }
        }
        catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            output = `Unexpected sentinel error: ${msg}`;
            status = "error";
        }
        const durationMs = Date.now() - startMs;
        const completedAt = new Date().toISOString();
        // Update the sentinel run record. Skip if the store has been closed (e.g. foreman
        // run exited while runOnce was in-flight — the run record is lost but that's
        // acceptable since the process is shutting down anyway).
        if (this.store.isOpen()) {
            await this.store.updateSentinelRun(runId, {
                status,
                output: output.slice(0, 50_000), // cap at 50 KB
                completed_at: completedAt,
                failure_count: this.consecutiveFailures,
            });
        }
        // Store has been closed (foreman run exiting) — skip the rest of post-result
        // processing. The in-flight runOnce() completes but the result record is dropped.
        if (!this.store.isOpen()) {
            return {
                id: runId,
                status: "error",
                commitHash: null,
                output: "Sentinel store closed — skipping result record",
                durationMs: Date.now() - startMs,
            };
        }
        // Log result event
        const eventType = status === "passed" ? "sentinel-pass" : "sentinel-fail";
        await this.store.logEvent(this.projectId, eventType, {
            runId,
            branch: opts.branch,
            commitHash,
            durationMs,
            status,
        });
        // Failure tracking
        if (status === "failed" || status === "error") {
            this.consecutiveFailures++;
            if (this.consecutiveFailures >= opts.failureThreshold && !opts.dryRun) {
                await this.createBugTask(opts.branch, commitHash, output);
                this.consecutiveFailures = 0; // reset after filing bug
            }
        }
        else {
            this.consecutiveFailures = 0;
        }
        return { id: runId, status, commitHash, output, durationMs };
    }
    /**
     * Start the sentinel loop.  Runs immediately, then on each interval.
     * Skips a run if the previous run is still active (queue protection).
     */
    start(opts, onResult) {
        if (this.running) {
            throw new Error("Sentinel is already running");
        }
        this.running = true;
        this.consecutiveFailures = 0;
        const intervalMs = opts.intervalMinutes * 60 * 1000;
        let activeRun = false;
        const loop = async () => {
            if (!this.running)
                return;
            if (activeRun) {
                // Previous run still in progress — skip this tick
                this.timer = setTimeout(() => void loop(), intervalMs);
                return;
            }
            activeRun = true;
            try {
                const result = await this.runOnce(opts);
                onResult?.(result);
            }
            catch (err) {
                console.error("[sentinel] Unexpected error in loop:", err);
            }
            finally {
                activeRun = false;
            }
            if (this.running) {
                this.timer = setTimeout(() => void loop(), intervalMs);
            }
        };
        void loop();
    }
    /** Stop the sentinel loop (in-flight run completes normally). */
    stop() {
        this.running = false;
        if (this.timer !== null) {
            clearTimeout(this.timer);
            this.timer = null;
        }
    }
    isRunning() {
        return this.running;
    }
    // ── Private helpers ──────────────────────────────────────────────────
    async resolveCommit(branch) {
        const backend = this.vcsBackend
            ?? await VcsBackendFactory.create({ backend: "auto" }, this.projectPath);
        for (const ref of [`origin/${branch}`, branch]) {
            try {
                return await backend.resolveRef(this.projectPath, ref);
            }
            catch {
                // Try next ref
            }
        }
        return null;
    }
    async runTestCommand(testCommand) {
        const timeoutMs = PIPELINE_TIMEOUTS.sentinelTestMs;
        const [cmd, ...args] = testCommand.split(/\s+/);
        try {
            const { stdout, stderr } = await execFileAsync(cmd, args, {
                cwd: this.projectPath,
                timeout: timeoutMs,
                env: { ...process.env },
                maxBuffer: 10 * 1024 * 1024,
            });
            const output = [stdout, stderr ? `STDERR:\n${stderr}` : ""]
                .filter(Boolean)
                .join("\n");
            return { status: "passed", output };
        }
        catch (err) {
            const e = err;
            const output = [
                e.stdout ?? "",
                e.stderr ? `STDERR:\n${e.stderr}` : "",
            ]
                .filter(Boolean)
                .join("\n");
            if (e.killed) {
                return {
                    status: "error",
                    output: `Test command timed out after ${timeoutMs / 1000}s\n${output}`,
                };
            }
            return { status: "failed", output };
        }
    }
    async createBugTask(branch, commitHash, output) {
        const shortHash = commitHash ? commitHash.slice(0, 8) : "unknown";
        const title = `[Sentinel] Test failures on ${branch} @ ${shortHash}`;
        const description = `Automated sentinel detected ${this.consecutiveFailures} consecutive test failure(s) ` +
            `on branch \`${branch}\`.\n\n` +
            `**Commit:** ${commitHash ?? "unknown"}\n\n` +
            `**Test output (truncated):**\n\`\`\`\n${output.slice(0, 2_000)}\n\`\`\``;
        try {
            // Check for an existing open issue with the same title to avoid duplicates.
            // Filter by label to narrow the search to sentinel-created issues only.
            const existingIssues = await this.seeds.list({
                status: "open",
                label: "kind:sentinel",
            });
            const duplicate = existingIssues.find((b) => b.title === title);
            if (duplicate) {
                console.log(`[sentinel] Found existing issue ${duplicate.id} for "${title}"`);
                // If the task client supports claim(), transition it to in-progress
                if ("claim" in this.seeds && typeof this.seeds.claim === "function") {
                    try {
                        const claimed = await this.seeds.claim(duplicate.id);
                        console.log(`[sentinel] Claimed issue — now status: ${claimed.status}`);
                    }
                    catch (err) {
                        console.log(`[sentinel] Could not claim issue (may already be in-progress): ${err}`);
                    }
                }
                return;
            }
            await this.seeds.create(title, {
                type: "bug",
                priority: "P0",
                description,
                labels: ["kind:sentinel"],
            });
        }
        catch (err) {
            // Non-fatal — log but don't abort the sentinel
            console.error("[sentinel] Failed to create bug task:", err);
        }
    }
}
//# sourceMappingURL=sentinel.js.map