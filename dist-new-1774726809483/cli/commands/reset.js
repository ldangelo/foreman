import { Command } from "commander";
import chalk from "chalk";
import { BeadsRustClient } from "../../lib/beads-rust.js";
import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { removeWorktree, deleteBranch } from "../../lib/git.js";
import { existsSync, readdirSync } from "node:fs";
import { archiveWorktreeReports } from "../../lib/archive-reports.js";
import { PIPELINE_LIMITS } from "../../lib/config.js";
import { mapRunStatusToSeedStatus } from "../../lib/run-status.js";
import { deleteWorkerConfigFile } from "../../orchestrator/dispatcher.js";
import { MergeQueue } from "../../orchestrator/merge-queue.js";
// Re-export for callers that import these from this module (backward compatibility).
export { mapRunStatusToSeedStatus } from "../../lib/run-status.js";
/**
 * Detect and fix seed/run state mismatches.
 *
 * Checks all terminal runs (completed, merged, etc.) for seeds that are still
 * stuck in "in_progress". Seeds that are already included in the `resetSeedIds`
 * set are skipped — those will be handled by the main reset loop.
 *
 * Seeds with active (pending/running) runs are skipped to avoid the race
 * condition where auto-dispatch has just marked a seed as in_progress but the
 * reset sees the old terminal run and incorrectly overwrites the status.
 *
 * For each mismatch found, the seed status is updated to the expected value
 * (unless dryRun is true).
 */
export async function detectAndFixMismatches(store, seeds, projectId, resetSeedIds, opts) {
    const dryRun = opts?.dryRun ?? false;
    // Check terminal run statuses not already handled by the reset loop
    const checkStatuses = ["completed", "merged", "pr-created", "conflict", "test-failed"];
    const terminalRuns = checkStatuses.flatMap((s) => store.getRunsByStatus(s, projectId));
    // Short-circuit: nothing to check, skip the extra DB read for active runs.
    if (terminalRuns.length === 0)
        return { mismatches: [], fixed: 0, errors: [] };
    // Build a set of seed IDs that have active (pending/running) runs.
    // We skip those to avoid clobbering seeds that were just dispatched.
    const activeRuns = store.getActiveRuns(projectId);
    const activeSeedIds = new Set(activeRuns.map((r) => r.seed_id));
    // Deduplicate by seed_id: keep the most recently created run per seed
    const latestBySeed = new Map();
    for (const run of terminalRuns) {
        // Skip seeds already being reset by the main loop
        if (resetSeedIds.has(run.seed_id))
            continue;
        // Skip seeds that have an active run — they are being dispatched right now
        if (activeSeedIds.has(run.seed_id))
            continue;
        const existing = latestBySeed.get(run.seed_id);
        if (!existing || run.created_at > existing.created_at) {
            latestBySeed.set(run.seed_id, run);
        }
    }
    const mismatches = [];
    const errors = [];
    let fixed = 0;
    for (const run of latestBySeed.values()) {
        const expectedSeedStatus = mapRunStatusToSeedStatus(run.status);
        try {
            const seedDetail = await seeds.show(run.seed_id);
            if (seedDetail.status !== expectedSeedStatus) {
                mismatches.push({
                    seedId: run.seed_id,
                    runId: run.id,
                    runStatus: run.status,
                    actualSeedStatus: seedDetail.status,
                    expectedSeedStatus,
                });
                if (!dryRun) {
                    try {
                        await seeds.update(run.seed_id, { status: expectedSeedStatus });
                        fixed++;
                    }
                    catch (err) {
                        const msg = err instanceof Error ? err.message : String(err);
                        errors.push(`Failed to fix mismatch for seed ${run.seed_id}: ${msg}`);
                    }
                }
            }
        }
        catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            if (!msg.includes("not found") && !msg.includes("Issue not found")) {
                errors.push(`Could not check seed ${run.seed_id}: ${msg}`);
            }
            // Seed not found — skip silently
        }
    }
    return { mismatches, fixed, errors };
}
/**
 * Detect stuck active runs by:
 *  1. Timeout check — if elapsed time > stuckTimeoutMinutes, the run is stuck.
 *
 * Updates the store for each newly-detected stuck run and returns the list.
 * Runs that are already in "stuck" status are not re-detected here (they will
 * be picked up by the main reset loop).
 */
export async function detectStuckRuns(store, projectId, opts) {
    const stuckTimeout = opts?.stuckTimeoutMinutes ?? PIPELINE_LIMITS.stuckDetectionMinutes;
    const dryRun = opts?.dryRun ?? false;
    // Only look at "running" (not pending/failed/stuck — those are handled elsewhere)
    const activeRuns = store.getActiveRuns(projectId).filter((r) => r.status === "running");
    const stuck = [];
    const errors = [];
    const now = Date.now();
    for (const run of activeRuns) {
        try {
            // Timeout check — if elapsed time exceeds stuckTimeout
            if (run.started_at) {
                const startedAt = new Date(run.started_at).getTime();
                const elapsedMinutes = (now - startedAt) / (1000 * 60);
                if (elapsedMinutes > stuckTimeout) {
                    if (!dryRun) {
                        store.updateRun(run.id, { status: "stuck" });
                        store.logEvent(run.project_id, "stuck", { seedId: run.seed_id, elapsedMinutes: Math.round(elapsedMinutes), detectedBy: "timeout" }, run.id);
                    }
                    stuck.push({ ...run, status: "stuck" });
                    continue;
                }
            }
        }
        catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            errors.push(`Could not check run ${run.seed_id}: ${msg}`);
        }
    }
    return { stuck, errors };
}
/**
 * Reset a single seed back to "open" status.
 *
 * - ALL non-open seeds are re-opened, including "closed" ones — this ensures
 *   that `foreman reset` always makes a seed retryable regardless of its
 *   previous state.
 * - If the seed is already "open", the update is skipped (idempotent).
 * - If the seed is not found, returns "not-found" without throwing.
 * - In dry-run mode, the `show()` check still runs (read-only) but `update()`
 *   is skipped — the returned `action` accurately reflects what would happen.
 *
 * Note: The `force` parameter is retained for API compatibility but no longer
 * changes behaviour (closed seeds are always reopened).
 */
export async function resetSeedToOpen(seedId, seeds, opts) {
    const dryRun = opts?.dryRun ?? false;
    try {
        const seedDetail = await seeds.show(seedId);
        if (seedDetail.status === "open") {
            return { action: "already-open", seedId, previousStatus: seedDetail.status };
        }
        if (!dryRun) {
            await seeds.update(seedId, { status: "open" });
        }
        return { action: "reset", seedId, previousStatus: seedDetail.status };
    }
    catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        if (msg.includes("not found")) {
            return { action: "not-found", seedId };
        }
        return { action: "error", seedId, error: msg };
    }
}
export const resetCommand = new Command("reset")
    .description("Reset failed/stuck runs: kill agents, remove worktrees, reset beads to open")
    .option("--bead <id>", "Reset a specific bead by ID (clears all runs for that bead, including stale pending ones)")
    .option("--all", "Reset ALL active runs, not just failed/stuck ones")
    .option("--detect-stuck", "Run stuck detection first, adding newly-detected stuck runs to the reset list")
    .option("--timeout <minutes>", "Stuck detection timeout in minutes (used with --detect-stuck)", String(PIPELINE_LIMITS.stuckDetectionMinutes))
    .option("--dry-run", "Show what would be reset without doing it")
    .action(async (opts, cmd) => {
    const dryRun = opts.dryRun;
    const all = opts.all;
    const detectStuck = opts.detectStuck;
    const beadFilter = opts.bead;
    const timeoutMinutes = parseInt(opts.timeout, 10);
    if (isNaN(timeoutMinutes)) {
        console.error(chalk.red(`Error: --timeout must be a positive integer, got "${opts.timeout}"`));
        process.exit(1);
    }
    // Warn if --timeout is explicitly set but --detect-stuck is not (it would be a no-op)
    if (!detectStuck && cmd.getOptionValueSource("timeout") === "user") {
        console.warn(chalk.yellow("Warning: --timeout has no effect without --detect-stuck\n"));
    }
    try {
        const projectPath = await getRepoRoot(process.cwd());
        const seeds = new BeadsRustClient(projectPath);
        const store = ForemanStore.forProject(projectPath);
        const project = store.getProjectByPath(projectPath);
        if (!project) {
            console.error(chalk.red("No project registered for this path. Run 'foreman init' first."));
            process.exit(1);
        }
        const mergeQueue = new MergeQueue(store.getDb());
        // Optional: run stuck detection first, mark newly-stuck runs in the store
        if (detectStuck) {
            console.log(chalk.bold("Detecting stuck runs...\n"));
            const detectionResult = await detectStuckRuns(store, project.id, {
                stuckTimeoutMinutes: timeoutMinutes,
                dryRun,
            });
            if (detectionResult.stuck.length > 0) {
                console.log(chalk.yellow.bold(`Found ${detectionResult.stuck.length} newly stuck run(s):`));
                for (const run of detectionResult.stuck) {
                    const elapsed = run.started_at
                        ? Math.round((Date.now() - new Date(run.started_at).getTime()) / 60000)
                        : 0;
                    console.log(`  ${chalk.yellow(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)} ${elapsed}m`);
                }
                console.log();
            }
            else {
                console.log(chalk.dim("  No newly stuck runs detected.\n"));
            }
            if (detectionResult.errors.length > 0) {
                for (const err of detectionResult.errors) {
                    console.log(chalk.red(`  Warning: ${err}`));
                }
                console.log();
            }
        }
        // Find runs to reset
        let runs;
        if (beadFilter) {
            // --seed: get ALL runs for this seed regardless of status, so stale pending/running are included
            runs = store.getRunsForSeed(beadFilter, project.id);
            if (runs.length === 0) {
                console.log(chalk.yellow(`No runs found for bead ${beadFilter}.\n`));
            }
            else {
                console.log(chalk.bold(`Resetting all ${runs.length} run(s) for bead ${beadFilter}:\n`));
            }
        }
        else {
            const statuses = all
                ? ["pending", "running", "failed", "stuck"]
                : ["failed", "stuck"];
            runs = statuses.flatMap((s) => store.getRunsByStatus(s, project.id));
        }
        if (dryRun) {
            console.log(chalk.yellow("(dry run — no changes will be made)\n"));
        }
        if (!beadFilter && runs.length === 0) {
            console.log(chalk.yellow("No active runs to reset.\n"));
        }
        else if (!beadFilter) {
            console.log(chalk.bold(`Resetting ${runs.length} run(s):\n`));
        }
        // Collect unique seed IDs to reset
        const seedIds = new Set();
        let killed = 0;
        let worktreesRemoved = 0;
        let branchesDeleted = 0;
        let runsMarkedFailed = 0;
        let mqEntriesRemoved = 0;
        let seedsReset = 0;
        const errors = [];
        for (const run of runs) {
            const pid = extractPid(run.session_key);
            const branchName = `foreman/${run.seed_id}`;
            console.log(`  ${chalk.cyan(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)} status=${run.status}`);
            // 1. Kill the agent process if alive
            if (pid && isAlive(pid)) {
                console.log(`    ${chalk.yellow("kill")} pid ${pid}`);
                if (!dryRun) {
                    try {
                        process.kill(pid, "SIGTERM");
                        killed++;
                    }
                    catch (err) {
                        const msg = err instanceof Error ? err.message : String(err);
                        errors.push(`Failed to kill pid ${pid} for ${run.seed_id}: ${msg}`);
                        console.log(`    ${chalk.red("error")} killing pid ${pid}: ${msg}`);
                    }
                }
            }
            // 2. Remove the worktree
            if (run.worktree_path) {
                console.log(`    ${chalk.yellow("remove")} worktree ${run.worktree_path}`);
                if (!dryRun) {
                    try {
                        await archiveWorktreeReports(projectPath, run.worktree_path, run.seed_id).catch(() => { });
                        await removeWorktree(projectPath, run.worktree_path);
                        worktreesRemoved++;
                    }
                    catch (err) {
                        const msg = err instanceof Error ? err.message : String(err);
                        // Worktree may already be gone
                        if (!msg.includes("is not a working tree")) {
                            errors.push(`Failed to remove worktree for ${run.seed_id}: ${msg}`);
                            console.log(`    ${chalk.red("error")} removing worktree: ${msg}`);
                        }
                        else {
                            worktreesRemoved++;
                        }
                    }
                }
            }
            // 3. Delete the branch — switch to main first if it is currently checked out
            console.log(`    ${chalk.yellow("delete")} branch ${branchName}`);
            if (!dryRun) {
                const { execFile } = await import("node:child_process");
                const { promisify } = await import("node:util");
                try {
                    const delResult = await deleteBranch(projectPath, branchName, { force: true });
                    if (delResult.deleted)
                        branchesDeleted++;
                }
                catch (err) {
                    const msg = err instanceof Error ? err.message : String(err);
                    if (msg.includes("used by worktree")) {
                        // Branch is HEAD of the main worktree — switch to main then retry
                        try {
                            console.log(`    ${chalk.dim("checkout")} main (branch is current HEAD)`);
                            await promisify(execFile)("git", ["checkout", "-f", "main"], { cwd: projectPath });
                            const retryResult = await deleteBranch(projectPath, branchName, { force: true });
                            if (retryResult.deleted)
                                branchesDeleted++;
                        }
                        catch (retryErr) {
                            const retryMsg = retryErr instanceof Error ? retryErr.message : String(retryErr);
                            errors.push(`Failed to delete branch ${branchName}: ${retryMsg}`);
                            console.log(`    ${chalk.red("error")} deleting branch: ${retryMsg}`);
                        }
                    }
                    else {
                        errors.push(`Failed to delete branch ${branchName}: ${msg}`);
                        console.log(`    ${chalk.red("error")} deleting branch: ${msg}`);
                    }
                }
                // 3b. Delete the remote branch to prevent stale remote tracking refs.
                // reconcile() checks refs/remotes/origin/foreman/<seedId> to recover
                // runs that crashed after pushing but before updating their status.
                // If the local branch is deleted but the remote ref persists, reconcile()
                // will falsely mark the newly re-dispatched (empty) run as "completed"
                // and insert a merge queue entry that immediately fails with "no-commits".
                console.log(`    ${chalk.yellow("delete")} remote branch origin/${branchName}`);
                try {
                    await promisify(execFile)("git", ["push", "origin", "--delete", branchName], { cwd: projectPath });
                }
                catch {
                    // Non-fatal: remote branch may not exist (never pushed, or already deleted)
                }
            }
            // 4. Mark run as "reset" — keeps history/events intact but signals to
            //    doctor that this run was intentionally cleared (not an active failure).
            console.log(`    ${chalk.yellow("mark")} run as reset`);
            if (!dryRun) {
                store.updateRun(run.id, {
                    status: "reset",
                    completed_at: new Date().toISOString(),
                });
                runsMarkedFailed++;
            }
            // 5. Clean up orphaned worker config file (if it still exists)
            if (!dryRun) {
                await deleteWorkerConfigFile(run.id);
            }
            // 5b. Remove merge queue entries for this seed
            const mqEntries = mergeQueue.list().filter((e) => e.seed_id === run.seed_id);
            if (mqEntries.length > 0) {
                console.log(`    ${chalk.yellow("remove")} ${mqEntries.length} merge queue entry(ies)`);
                if (!dryRun) {
                    for (const entry of mqEntries) {
                        mergeQueue.remove(entry.id);
                        mqEntriesRemoved++;
                    }
                }
            }
            seedIds.add(run.seed_id);
            console.log();
        }
        // 5. Reset seeds to open (force-reopen if --seed was explicitly provided)
        for (const seedId of seedIds) {
            const result = await resetSeedToOpen(seedId, seeds, { dryRun, force: !!beadFilter });
            switch (result.action) {
                case "skipped-closed":
                    // This case is no longer reachable — resetSeedToOpen now always reopens
                    // closed seeds. Kept to satisfy the exhaustive switch type check.
                    console.log(`  ${chalk.dim("skip")} seed ${chalk.cyan(seedId)} is already closed — not reopening`);
                    break;
                case "already-open":
                    // Bead was already open — no update was made (or would be made).
                    console.log(`  ${chalk.dim("skip")} bead ${chalk.cyan(seedId)} is already open`);
                    break;
                case "reset":
                    console.log(`  ${chalk.yellow("reset")} bead ${chalk.cyan(seedId)} → open`);
                    seedsReset++;
                    break;
                case "not-found":
                    console.log(`    ${chalk.dim("skip")} bead ${seedId} no longer exists`);
                    break;
                case "error":
                    errors.push(`Failed to reset bead ${seedId}: ${result.error ?? "unknown error"}`);
                    console.log(`    ${chalk.red("error")} resetting bead: ${result.error ?? "unknown error"}`);
                    break;
            }
        }
        // 5c. Mark all completed runs with no MQ entry as "reset" — their branches
        //     have been removed or were never queued, so they can never be merged.
        //     Leaving them as "completed" triggers the MQ-011 doctor warning.
        if (!dryRun) {
            const unqueuedCompleted = mergeQueue.missingFromQueue();
            for (const entry of unqueuedCompleted) {
                store.updateRun(entry.run_id, { status: "reset", completed_at: new Date().toISOString() });
                runsMarkedFailed++;
            }
            if (unqueuedCompleted.length > 0) {
                console.log(`  ${chalk.yellow("reset")} ${unqueuedCompleted.length} completed run(s) with no merge queue entry`);
            }
        }
        // 6. Prune stale worktree entries and remote tracking refs
        if (!dryRun) {
            try {
                const { execFile } = await import("node:child_process");
                const { promisify } = await import("node:util");
                await promisify(execFile)("git", ["worktree", "prune"], { cwd: projectPath });
                // Prune stale remote tracking refs so reconcile() doesn't see deleted
                // remote branches and falsely recover newly-dispatched empty runs.
                await promisify(execFile)("git", ["fetch", "--prune"], { cwd: projectPath });
            }
            catch {
                // Non-critical
            }
        }
        // 6b. Clean up orphaned worktrees — directories in .foreman-worktrees/ that either have
        //     no SQLite run record OR only have completed/merged runs (finalize should remove them
        //     but sometimes fails to do so)
        if (!dryRun) {
            const worktreesDir = `${projectPath}/.foreman-worktrees`;
            if (existsSync(worktreesDir)) {
                // Paths that still have truly active runs (pending or running) — keep these.
                // "failed" and "stuck" are terminal states: their agents have stopped, so
                // their worktrees are safe to remove during cleanup. Including them in the
                // "active" set was the bug: it prevented orphaned worktrees from being
                // cleaned up when a run had no worktree_path recorded in the DB.
                const activeStatuses = ["pending", "running"];
                const activeRuns = activeStatuses.flatMap((s) => store.getRunsByStatus(s, project.id));
                const activeWorktreePaths = new Set(activeRuns.map((r) => r.worktree_path).filter(Boolean));
                let entries = [];
                try {
                    entries = readdirSync(worktreesDir);
                }
                catch {
                    // Directory may have been removed already
                }
                for (const entry of entries) {
                    const fullPath = `${worktreesDir}/${entry}`;
                    // Skip if this worktree belongs to an active run (may still be in use)
                    if (activeWorktreePaths.has(fullPath))
                        continue;
                    console.log(`  ${chalk.yellow("orphan")} worktree ${fullPath}`);
                    try {
                        await removeWorktree(projectPath, fullPath);
                        worktreesRemoved++;
                    }
                    catch (err) {
                        const msg = err instanceof Error ? err.message : String(err);
                        if (!msg.includes("is not a working tree")) {
                            console.log(`    ${chalk.red("error")} removing orphaned worktree: ${msg}`);
                        }
                    }
                    // Delete the corresponding branch if it exists
                    const orphanBranch = `foreman/${entry}`;
                    try {
                        const delResult = await deleteBranch(projectPath, orphanBranch, { force: true });
                        if (delResult.deleted) {
                            branchesDeleted++;
                            console.log(`    ${chalk.yellow("delete")} orphan branch ${orphanBranch}`);
                        }
                    }
                    catch {
                        // Branch may not exist — skip silently
                    }
                }
            }
        }
        // 6c. Purge all remaining conflict/failed merge queue entries (catches seeds not
        //     in this reset batch that are still clogging the queue)
        if (!dryRun) {
            const staleEntries = mergeQueue.list().filter((e) => e.status === "conflict" || e.status === "failed");
            for (const entry of staleEntries) {
                mergeQueue.remove(entry.id);
                mqEntriesRemoved++;
            }
            if (staleEntries.length > 0) {
                console.log(`  ${chalk.yellow("purged")} ${staleEntries.length} stale merge queue entry(ies)`);
            }
        }
        // 7. Detect and fix seed/run state mismatches for terminal runs
        console.log(chalk.bold("\nChecking for bead/run state mismatches..."));
        const mismatchResult = await detectAndFixMismatches(store, seeds, project.id, seedIds, { dryRun });
        if (mismatchResult.mismatches.length > 0) {
            for (const m of mismatchResult.mismatches) {
                const action = dryRun
                    ? chalk.yellow("(would fix)")
                    : chalk.green("fixed");
                console.log(`  ${chalk.yellow("mismatch")} ${chalk.cyan(m.seedId)}: ` +
                    `run=${m.runStatus}, bead=${m.actualSeedStatus} → ${m.expectedSeedStatus} ${action}`);
            }
        }
        else {
            console.log(chalk.dim("  No mismatches found."));
        }
        // Summary
        console.log(chalk.bold("\nSummary:"));
        if (dryRun) {
            console.log(chalk.yellow(`  Would reset ${runs.length} runs across ${seedIds.size} beads`));
            if (mismatchResult.mismatches.length > 0) {
                console.log(chalk.yellow(`  Would fix ${mismatchResult.mismatches.length} mismatch(es)`));
            }
        }
        else {
            console.log(`  Processes killed:   ${killed}`);
            console.log(`  Worktrees removed:  ${worktreesRemoved}`);
            console.log(`  Branches deleted:   ${branchesDeleted}`);
            console.log(`  Runs marked reset:   ${runsMarkedFailed}`);
            console.log(`  MQ entries removed:  ${mqEntriesRemoved}`);
            console.log(`  Beads reset:        ${seedsReset}`);
            console.log(`  Mismatches fixed:   ${mismatchResult.fixed}`);
        }
        const allErrors = [...errors, ...mismatchResult.errors];
        if (allErrors.length > 0) {
            console.log(chalk.red(`\n  Errors (${allErrors.length}):`));
            for (const err of allErrors) {
                console.log(chalk.red(`    ${err}`));
            }
        }
        console.log(chalk.dim("\nRe-run with: foreman run"));
        store.close();
    }
    catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        console.error(chalk.red(`Error: ${message}`));
        process.exit(1);
    }
});
function extractPid(sessionKey) {
    if (!sessionKey)
        return null;
    const m = sessionKey.match(/pid-(\d+)/);
    return m ? parseInt(m[1], 10) : null;
}
function isAlive(pid) {
    try {
        process.kill(pid, 0);
        return true;
    }
    catch {
        return false;
    }
}
//# sourceMappingURL=reset.js.map