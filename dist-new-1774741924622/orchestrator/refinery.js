import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
// Note: removeWorktree shim removed in TRD-012; workspace removal now goes through this.vcsBackend.removeWorkspace()
import { extractBranchLabel } from "../lib/branch-label.js";
import { archiveWorktreeReports } from "../lib/archive-reports.js";
import { PIPELINE_BUFFERS, PIPELINE_TIMEOUTS } from "../lib/config.js";
import { ConflictResolver } from "./conflict-resolver.js";
import { DEFAULT_MERGE_CONFIG } from "./merge-config.js";
import { enqueueCloseSeed, enqueueResetSeedToOpen, enqueueAddNotesToBead } from "./task-backend-ops.js";
import { GitBackend } from "../lib/vcs/git-backend.js";
const execFileAsync = promisify(execFile);
// ── Helpers ──────────────────────────────────────────────────────────────
/**
 * Run git commands that are NOT covered by the VcsBackend interface:
 *   - git stash push / pop  (no stash support in VcsBackend)
 *   - git log --oneline     (no log method in VcsBackend)
 *   - git reset --hard      (no reset method in VcsBackend)
 *   - git merge --abort     (no merge-abort method in VcsBackend)
 *   - git rebase --onto     (no 3-ref rebase form in VcsBackend)
 *   - git rebase <upstream> <branch>  (2-arg form, operates on non-current branch)
 *   - git checkout --theirs <file>  (no per-file resolution in VcsBackend)
 *   - git add <specific files>  (VcsBackend.stageAll stages everything)
 *   - git commit --no-edit  (VcsBackend.commit() requires a message)
 *   - git apply --index     (no apply in VcsBackend)
 *   - git merge -X theirs   (VcsBackend.merge() doesn't support -X strategy)
 */
async function gitSpecial(args, cwd) {
    const { stdout } = await execFileAsync("git", args, {
        cwd,
        maxBuffer: PIPELINE_BUFFERS.maxBufferBytes,
        env: { ...process.env, GIT_EDITOR: "true" },
    });
    return stdout.trim();
}
async function gh(args, cwd) {
    const { stdout } = await execFileAsync("gh", args, {
        cwd,
        maxBuffer: PIPELINE_BUFFERS.maxBufferBytes,
    });
    return stdout.trim();
}
async function runTestCommand(command, cwd) {
    const [cmd, ...args] = command.split(/\s+/);
    try {
        const { stdout, stderr } = await execFileAsync(cmd, args, {
            cwd,
            maxBuffer: PIPELINE_BUFFERS.maxBufferBytes,
            timeout: PIPELINE_TIMEOUTS.testExecutionMs,
        });
        return { ok: true, output: (stdout + "\n" + stderr).trim() };
    }
    catch (err) {
        return { ok: false, output: (err.stdout ?? "") + "\n" + (err.stderr ?? err.message) };
    }
}
// ── Refinery ─────────────────────────────────────────────────────────────
export class Refinery {
    store;
    seeds;
    projectPath;
    conflictResolver;
    vcsBackend;
    constructor(store, seeds, projectPath, vcsBackend) {
        this.store = store;
        this.seeds = seeds;
        this.projectPath = projectPath;
        // Default to GitBackend for backward compatibility with callers that don't
        // provide an explicit VcsBackend (e.g. CLI commands, existing tests).
        this.vcsBackend = vcsBackend ?? new GitBackend(projectPath);
        this.conflictResolver = new ConflictResolver(projectPath, DEFAULT_MERGE_CONFIG);
    }
    /**
     * Scan the committed diff between branchName and targetBranch for conflict markers.
     * Only looks at committed content (git diff), never at uncommitted working-tree files.
     * Uncommitted conflict markers (e.g. from a failed agent rebase) are intentionally ignored —
     * they don't exist in the branch that will be merged.
     * Returns a list of files containing markers (relative to repo root), or an empty array if clean.
     */
    async scanForConflictMarkers(branchName, targetBranch) {
        try {
            const diff = await this.vcsBackend.diff(this.projectPath, targetBranch, branchName);
            if (!diff.trim())
                return [];
            const files = new Set();
            let currentFile = "";
            for (const line of diff.split("\n")) {
                if (line.startsWith("+++ b/")) {
                    currentFile = line.slice(6); // strip "+++ b/"
                }
                else if ((line.startsWith("+<<<<<<<") || line.startsWith("+|||||||")) && currentFile) {
                    files.add(currentFile);
                }
            }
            return [...files];
        }
        catch {
            // Any error (e.g. branch not found) — return clean to avoid blocking merge
            return [];
        }
    }
    /**
     * Check if a file path is a report/non-code file that can be auto-resolved.
     * Delegates to ConflictResolver.isReportFile().
     */
    isReportFile(f) {
        return ConflictResolver.isReportFile(f);
    }
    /**
     * During a rebase conflict, check if all conflicts are report files.
     * If so, auto-resolve them and continue rebase (looping until done).
     * If real code conflicts exist, abort rebase and return false.
     * Returns true if rebase completed successfully.
     * Delegates to ConflictResolver.autoResolveRebaseConflicts().
     */
    async autoResolveRebaseConflicts(targetBranch) {
        return this.conflictResolver.autoResolveRebaseConflicts(targetBranch);
    }
    /**
     * Detect uncommitted changes in `.seeds/` and `.foreman/` and commit them
     * so that merge operations start from a clean state for state files.
     * No-op when there are no dirty state files.
     */
    async autoCommitStateFiles() {
        try {
            // Use vcsBackend.getModifiedFiles() to retrieve file paths with correct
            // per-line whitespace handling. This avoids the XY-code trimming issue
            // that occurs when using status() on the whole output string (git status
            // --porcelain lines starting with ' M' have a leading space that trim()
            // removes from the first line of the combined output).
            const modifiedFiles = await this.vcsBackend.getModifiedFiles(this.projectPath);
            if (modifiedFiles.length === 0)
                return;
            const stateFiles = modifiedFiles.filter((path) => path.startsWith(".seeds/") || path.startsWith(".foreman/"));
            if (stateFiles.length === 0)
                return;
            // Use gitSpecial for selective staging (VcsBackend.stageAll stages everything)
            await gitSpecial(["add", ...stateFiles], this.projectPath);
            await this.vcsBackend.commit(this.projectPath, "chore: auto-commit state files before merge");
        }
        catch (err) {
            // MQ-020: Auto-commit failure is non-fatal — log and continue
            const message = err instanceof Error ? err.message : String(err);
            console.error(`[MQ-020] Auto-commit state files failed (non-fatal): ${message}`);
        }
    }
    /**
     * Remove report files from the working tree before merging so they can't
     * conflict. Commits the removal if any tracked files were removed.
     * Delegates to ConflictResolver.removeReportFiles().
     */
    async removeReportFiles() {
        return this.conflictResolver.removeReportFiles();
    }
    /**
     * Archive report files after a successful merge.
     * Moves report files from the working tree into .foreman/reports/<name>-<seedId>.md
     * and creates a follow-up commit. Called after vcsBackend.merge() succeeds so we
     * don't need to checkout branches or deal with dirty working trees.
     * Delegates to ConflictResolver.archiveReportsPostMerge().
     */
    async archiveReportsPostMerge(seedId) {
        return this.conflictResolver.archiveReportsPostMerge(seedId);
    }
    /**
     * Fire-and-forget helper to send a mail message via the store.
     * Never throws — failures are silently ignored (mail is optional infrastructure).
     */
    sendMail(runId, subject, body) {
        try {
            this.store.sendMessage(runId, "refinery", "foreman", subject, JSON.stringify({
                ...body,
                timestamp: new Date().toISOString(),
            }));
        }
        catch {
            // Non-fatal — mail is optional infrastructure
        }
    }
    /**
     * Attempt to add a note to a bead explaining what went wrong.
     * Non-fatal — a failure to annotate the bead must not mask the original error.
     */
    async addFailureNote(seedId, note) {
        // Enqueue instead of calling br directly — multiple agent workers run
        // refinery concurrently, and direct calls cause SQLITE_BUSY on beads DB.
        try {
            enqueueAddNotesToBead(this.store, seedId, note.slice(0, 500), "refinery");
        }
        catch (err) {
            // Non-fatal: best-effort annotation
            const message = err instanceof Error ? err.message : String(err);
            console.warn(`[Refinery] Failed to enqueue failure note for bead ${seedId}: ${message}`);
        }
    }
    /**
     * After a successful merge of `mergedBranch` into `targetBranch`, find all
     * stacked branches (seeds whose worktree was branched from `mergedBranch`)
     * and rebase them onto `targetBranch` so they pick up the latest code.
     *
     * Non-fatal: failures are logged as warnings; they do not abort the merge.
     */
    async rebaseStackedBranches(mergedBranch, targetBranch) {
        try {
            // Query runs that were stacked on the just-merged branch
            const stackedRuns = this.store.getRunsByBaseBranch(mergedBranch);
            if (stackedRuns.length === 0)
                return;
            for (const stackedRun of stackedRuns) {
                // Only rebase active (non-terminal) runs
                const activeStatuses = ["pending", "running", "completed"];
                if (!activeStatuses.includes(stackedRun.status))
                    continue;
                const stackedBranch = `foreman/${stackedRun.seed_id}`;
                const branchExists = await this.vcsBackend.branchExists(this.projectPath, stackedBranch);
                if (!branchExists)
                    continue;
                try {
                    // Use gitSpecial for the --onto form which is not supported by VcsBackend.rebase()
                    // (VcsBackend.rebase() only supports simple "rebase onto" without --onto syntax)
                    await gitSpecial(["rebase", "--onto", targetBranch, mergedBranch, stackedBranch], this.projectPath);
                    console.error(`[Refinery] Rebased stacked branch ${stackedBranch} onto ${targetBranch} (was on ${mergedBranch})`);
                    // Update the run's base_branch to reflect it's now on targetBranch
                    this.store.updateRun(stackedRun.id, { base_branch: null });
                }
                catch (rebaseErr) {
                    const msg = rebaseErr instanceof Error ? rebaseErr.message : String(rebaseErr);
                    console.warn(`[Refinery] Warning: failed to rebase stacked branch ${stackedBranch} onto ${targetBranch}: ${msg.slice(0, 300)}`);
                    // Abort any partial rebase to leave the repo in a clean state
                    try {
                        await this.vcsBackend.abortRebase(this.projectPath);
                    }
                    catch { /* already clean */ }
                }
            }
        }
        catch (err) {
            // Non-fatal: log and continue — stacked rebase failure must not block the merge
            const msg = err instanceof Error ? err.message : String(err);
            console.warn(`[Refinery] Warning: rebaseStackedBranches failed: ${msg.slice(0, 200)}`);
        }
    }
    /**
     * Push a conflicting branch and create a PR for manual resolution.
     * Returns the CreatedPr info, or null if PR creation fails.
     */
    async createPrForConflict(run, branchName, baseBranch, conflictNote) {
        try {
            // Push branch to origin (force-push since rebase may have rewritten history)
            await this.vcsBackend.push(this.projectPath, branchName, { force: true });
            // Get seed info for PR title/body
            let seedTitle = run.seed_id;
            let seedDescription = "";
            try {
                const seedInfo = await this.seeds.show(run.seed_id);
                if (seedInfo) {
                    seedTitle = seedInfo.title ?? run.seed_id;
                    seedDescription = seedInfo.description ?? "";
                }
            }
            catch { /* use defaults */ }
            const prTitle = `${seedTitle} (${run.seed_id})`;
            const body = [
                "## Summary",
                seedDescription || `Agent work for ${run.seed_id}`,
                "",
                "## Conflicts",
                `This branch has conflicts with \`${baseBranch}\` that need manual resolution:`,
                conflictNote,
                "",
                `Foreman run: \`${run.id}\``,
            ].join("\n");
            const prUrl = await gh(["pr", "create", "--base", baseBranch, "--head", branchName, "--title", prTitle, "--body", body], this.projectPath);
            this.store.updateRun(run.id, { status: "pr-created" });
            this.store.logEvent(run.project_id, "pr-created", { seedId: run.seed_id, branchName, baseBranch, prUrl, conflictNote }, run.id);
            return { runId: run.id, seedId: run.seed_id, branchName, prUrl };
        }
        catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            this.store.updateRun(run.id, { status: "conflict" });
            this.store.logEvent(run.project_id, "fail", { seedId: run.seed_id, branchName, error: `PR creation failed: ${message}` }, run.id);
            return null;
        }
    }
    /**
     * Get all completed runs that are ready to merge, optionally filtered to a single seed.
     *
     * When a seedId filter is active (i.e. `foreman merge --seed <id>`), we also
     * include runs in terminal failure states ("test-failed", "conflict", "failed")
     * so that a previously-failed merge can be retried without the user having to
     * manually reset the run's status back to "completed".
     *
     * Without a seedId filter we only return "completed" runs to avoid accidentally
     * re-attempting bulk merges of runs that failed for unrelated reasons.
     */
    getCompletedRuns(projectId, seedId) {
        if (seedId) {
            // For targeted retries, look in completed AND terminal failure states.
            const retryStatuses = [
                "completed",
                "test-failed",
                "conflict",
                "failed",
            ];
            const runs = this.store.getRunsByStatuses(retryStatuses, projectId);
            const matching = runs.filter((r) => r.seed_id === seedId);
            // Prefer a completed run over newer stuck/failed runs for the same seed.
            // SQLite returns rows ordered by created_at DESC so stuck/failed may appear
            // first even though a completed run exists from an earlier attempt.
            const completedRun = matching.find((r) => r.status === "completed");
            return completedRun ? [completedRun] : matching.slice(0, 1);
        }
        return this.store.getRunsByStatus("completed", projectId);
    }
    /**
     * Order runs by seed dependency graph so that dependencies merge before dependents.
     * Falls back to insertion order if dependency info is unavailable.
     */
    async orderByDependencies(runs) {
        if (runs.length <= 1)
            return runs;
        try {
            if (!this.seeds.getGraph)
                return runs; // br backend has no getGraph
            const graph = await this.seeds.getGraph();
            // Build a map of seed_id → set of dependency seed_ids
            const depMap = new Map();
            for (const edge of graph.edges) {
                if (!depMap.has(edge.from))
                    depMap.set(edge.from, new Set());
                depMap.get(edge.from).add(edge.to);
            }
            // Topological sort (Kahn's algorithm)
            const runMap = new Map(runs.map((r) => [r.seed_id, r]));
            const seedIds = new Set(runs.map((r) => r.seed_id));
            // Only consider deps within our run set
            const inDegree = new Map();
            const adj = new Map();
            for (const id of seedIds) {
                inDegree.set(id, 0);
                adj.set(id, []);
            }
            for (const id of seedIds) {
                const deps = depMap.get(id);
                if (!deps)
                    continue;
                for (const dep of deps) {
                    if (seedIds.has(dep)) {
                        adj.get(dep).push(id);
                        inDegree.set(id, (inDegree.get(id) ?? 0) + 1);
                    }
                }
            }
            const queue = [];
            for (const [id, deg] of inDegree) {
                if (deg === 0)
                    queue.push(id);
            }
            const sorted = [];
            while (queue.length > 0) {
                const id = queue.shift();
                const run = runMap.get(id);
                if (run)
                    sorted.push(run);
                for (const next of adj.get(id) ?? []) {
                    const newDeg = (inDegree.get(next) ?? 1) - 1;
                    inDegree.set(next, newDeg);
                    if (newDeg === 0)
                        queue.push(next);
                }
            }
            // Append any runs not in the graph (shouldn't happen, but safe)
            for (const run of runs) {
                if (!sorted.includes(run))
                    sorted.push(run);
            }
            return sorted;
        }
        catch {
            // Graph unavailable — fall back to original order
            return runs;
        }
    }
    /**
     * Find all completed (unmerged) runs and attempt to merge them into the target branch.
     * Optionally run tests after each merge. Merges in dependency order.
     *
     * Report files (QA_REPORT.md, REVIEW.md, TASK.md, AGENTS.md, etc.) are removed
     * before each merge to prevent conflicts, then archived to .foreman/reports/ after.
     * Only real code conflicts are reported as failures.
     */
    async mergeCompleted(opts) {
        const defaultTargetBranch = opts?.targetBranch ?? await this.vcsBackend.detectDefaultBranch(this.projectPath);
        const runTests = opts?.runTests ?? true;
        const testCommand = opts?.testCommand ?? "npm test";
        const rawRuns = this.getCompletedRuns(opts?.projectId, opts?.seedId);
        const completedRuns = await this.orderByDependencies(rawRuns);
        const merged = [];
        const conflicts = [];
        const testFailures = [];
        const prsCreated = [];
        for (const run of completedRuns) {
            const branchName = `foreman/${run.seed_id}`;
            // Resolve per-seed target branch: prefer branch: label on the bead,
            // fall back to the caller-supplied or auto-detected default.
            let targetBranch = defaultTargetBranch;
            try {
                const seedDetail = await this.seeds.show(run.seed_id);
                const branchLabel = extractBranchLabel(seedDetail.labels);
                if (branchLabel) {
                    targetBranch = branchLabel;
                }
            }
            catch {
                // Non-fatal — if label lookup fails, use default target
            }
            try {
                // Early guard: if the branch has no unique commits vs target, the agent committed
                // nothing. Creating a PR would fail ("no commits between ..."). Don't reset to open
                // (that would cause infinite redispatch to the same broken worktree). Mark as a
                // conflict so the user can investigate.
                const branchCommits = await gitSpecial(["log", "--oneline", `${targetBranch}..${branchName}`], this.projectPath).catch(() => "");
                if (!branchCommits.trim()) {
                    console.warn(`[Refinery] Branch ${branchName} has no commits beyond ${targetBranch} — agent may not have committed work`);
                    await this.addFailureNote(run.seed_id, `Branch ${branchName} has no unique commits beyond ${targetBranch}. The agent may not have committed its work. Manual intervention required — do not auto-reset.`);
                    this.sendMail(run.id, "merge-failed", {
                        seedId: run.seed_id,
                        branchName,
                        reason: "no-commits",
                        detail: `Branch ${branchName} has no unique commits beyond ${targetBranch}`,
                    });
                    conflicts.push({ runId: run.id, seedId: run.seed_id, branchName, conflictFiles: [] });
                    continue;
                }
                // Scan for conflict markers in COMMITTED branch content (not working tree).
                // Working-tree conflict markers (e.g. leftover from a failed agent rebase) are
                // intentionally ignored — they don't exist in the commits that will be merged.
                {
                    const markedFiles = await this.scanForConflictMarkers(branchName, targetBranch);
                    if (markedFiles.length > 0) {
                        enqueueResetSeedToOpen(this.store, run.seed_id, "refinery");
                        this.sendMail(run.id, "merge-failed", {
                            seedId: run.seed_id,
                            branchName,
                            reason: "conflict-markers",
                            conflictFiles: markedFiles,
                        });
                        const pr = await this.createPrForConflict(run, branchName, targetBranch, `Unresolved conflict markers in: ${markedFiles.join(", ")}`);
                        if (pr) {
                            prsCreated.push(pr);
                        }
                        else {
                            await this.addFailureNote(run.seed_id, `Merge skipped: unresolved conflict markers in ${markedFiles.join(", ")}. PR creation also failed — manual intervention required.`);
                            conflicts.push({ runId: run.id, seedId: run.seed_id, branchName, conflictFiles: markedFiles });
                        }
                        continue;
                    }
                }
                // Commit any dirty state files (.seeds/, .foreman/) before merge
                await this.autoCommitStateFiles();
                // Remove report files so they can't cause merge conflicts
                await this.removeReportFiles();
                // Ensure branch is in local refs — sentinel/remote branches may only exist
                // on origin and not be fetched yet. Silently skip if the fetch fails (the
                // reconcile step already validates the branch exists).
                try {
                    await this.vcsBackend.fetch(this.projectPath);
                }
                catch {
                    // Fetch failure is non-fatal: branch may already be local, or the remote
                    // may be unreachable. The subsequent rebase/merge will surface any real error.
                }
                // Ensure working directory is clean before rebase — a previous partial rebase
                // may have left patches applied but not committed. Stash any uncommitted changes
                // so git rebase doesn't refuse to run.
                let stashedBeforeRebase = false;
                try {
                    const dirty = await this.vcsBackend.status(this.projectPath);
                    if (dirty.trim()) {
                        await gitSpecial(["stash", "push", "--include-untracked", "-m", "foreman-rebase-pre-stash"], this.projectPath);
                        stashedBeforeRebase = true;
                    }
                }
                catch {
                    // stash failure is non-fatal — rebase will fail with a clear message if still dirty
                }
                // Rebase branch onto current target so it picks up all prior merges.
                // Auto-resolves report-file conflicts during rebase; aborts on real code conflicts.
                {
                    let rebaseOk = true;
                    try {
                        // Use gitSpecial for the 2-arg rebase form (rebase <upstream> <branch>) which
                        // operates on a non-current branch and is not supported by VcsBackend.rebase().
                        await gitSpecial(["rebase", targetBranch, branchName], this.projectPath);
                    }
                    catch (err) {
                        const errMsg = err instanceof Error ? err.message : String(err);
                        if (errMsg.includes("already used by worktree") || errMsg.includes("is already checked out")) {
                            // Branch is checked out in an active worktree — git refuses to rebase it from
                            // the main repo. Skip rebase and fall back to direct merge.
                            console.warn(`[Refinery] Skipping rebase for ${branchName} (active worktree) — falling back to direct merge`);
                            rebaseOk = true;
                        }
                        else {
                            // Rebase hit conflicts — try to auto-resolve report files and continue
                            rebaseOk = await this.autoResolveRebaseConflicts(targetBranch);
                        }
                    }
                    // Return to target branch regardless
                    try {
                        await this.vcsBackend.checkoutBranch(this.projectPath, targetBranch);
                    }
                    catch { /* best effort */ }
                    if (!rebaseOk) {
                        // Restore stash before bailing out so working directory stays clean
                        if (stashedBeforeRebase) {
                            try {
                                await gitSpecial(["stash", "pop"], this.projectPath);
                            }
                            catch { /* best effort */ }
                        }
                        // Add failure note before resetting so the bead records why it was reset
                        await this.addFailureNote(run.seed_id, `Merge failed: conflict on ${new Date().toISOString().slice(0, 10)} — branch reset to open for retry. Rebase conflicts detected.`);
                        // Rebase failed — reset seed to open so it can be retried, then create a PR for manual conflict resolution
                        enqueueResetSeedToOpen(this.store, run.seed_id, "refinery");
                        this.sendMail(run.id, "merge-failed", {
                            seedId: run.seed_id,
                            branchName,
                            reason: "rebase-conflict",
                        });
                        const pr = await this.createPrForConflict(run, branchName, targetBranch, "Rebase conflicts");
                        if (pr) {
                            prsCreated.push(pr);
                        }
                        else {
                            conflicts.push({ runId: run.id, seedId: run.seed_id, branchName, conflictFiles: [] });
                        }
                        continue;
                    }
                }
                // Restore any stash we created before the rebase (working dir should be clean after
                // a successful rebase, but pop defensively to avoid losing the stash entry)
                if (stashedBeforeRebase) {
                    try {
                        await gitSpecial(["stash", "pop"], this.projectPath);
                    }
                    catch { /* best effort — may be empty */ }
                }
                // Save pre-merge HEAD so we can revert merge + archive if tests fail
                const preMergeHead = await this.vcsBackend.getHeadId(this.projectPath);
                const result = await this.vcsBackend.merge(this.projectPath, branchName, targetBranch);
                if (!result.success) {
                    const allConflicts = result.conflicts ?? [];
                    const reportConflicts = allConflicts.filter((f) => this.isReportFile(f));
                    const codeConflicts = allConflicts.filter((f) => !this.isReportFile(f));
                    if (codeConflicts.length > 0) {
                        // Real code conflicts — abort merge and create PR instead
                        try {
                            await gitSpecial(["merge", "--abort"], this.projectPath);
                        }
                        catch {
                            // merge --abort may fail if already clean
                        }
                        // Add failure note before resetting so the bead records why it was reset
                        await this.addFailureNote(run.seed_id, `Merge failed: conflict on ${new Date().toISOString().slice(0, 10)} — branch reset to open for retry. Conflicting files: ${codeConflicts.join(", ")}`);
                        // Reset seed to open so it can be retried after manual conflict resolution
                        enqueueResetSeedToOpen(this.store, run.seed_id, "refinery");
                        this.sendMail(run.id, "merge-failed", {
                            seedId: run.seed_id,
                            branchName,
                            reason: "merge-conflict",
                            conflictFiles: codeConflicts,
                        });
                        const pr = await this.createPrForConflict(run, branchName, targetBranch, `Conflicts in: ${codeConflicts.join(", ")}`);
                        if (pr) {
                            prsCreated.push(pr);
                        }
                        else {
                            conflicts.push({ runId: run.id, seedId: run.seed_id, branchName, conflictFiles: codeConflicts });
                        }
                        continue;
                    }
                    // Only report-file conflicts — auto-resolve by accepting the branch version
                    for (const f of reportConflicts) {
                        await gitSpecial(["checkout", "--theirs", f], this.projectPath);
                        await gitSpecial(["add", "-f", f], this.projectPath);
                    }
                    await gitSpecial(["commit", "--no-edit"], this.projectPath);
                }
                // Merge succeeded — archive report files so they don't conflict with next merge
                await this.archiveReportsPostMerge(run.seed_id);
                // Optionally run tests
                if (runTests) {
                    const testResult = await runTestCommand(testCommand, this.projectPath);
                    if (!testResult.ok) {
                        // Revert the merge + archive commits
                        await gitSpecial(["reset", "--hard", preMergeHead], this.projectPath);
                        // Add failure note before resetting so the bead records why it was reset
                        await this.addFailureNote(run.seed_id, `Merge failed: post-merge tests failed on ${new Date().toISOString().slice(0, 10)} — branch reset for retry. ${testResult.output.slice(0, 300)}`);
                        // Reset seed to open so it can be retried
                        enqueueResetSeedToOpen(this.store, run.seed_id, "refinery");
                        this.store.updateRun(run.id, { status: "test-failed" });
                        this.store.logEvent(run.project_id, "test-fail", { seedId: run.seed_id, branchName, output: testResult.output.slice(0, 2000) }, run.id);
                        this.sendMail(run.id, "merge-failed", {
                            seedId: run.seed_id,
                            branchName,
                            reason: "test-failure",
                            output: testResult.output.slice(0, 500),
                        });
                        testFailures.push({
                            runId: run.id,
                            seedId: run.seed_id,
                            branchName,
                            error: testResult.output.slice(0, 500),
                        });
                        continue;
                    }
                }
                // All good — clean up worktree and mark as merged
                if (run.worktree_path) {
                    try {
                        await archiveWorktreeReports(this.projectPath, run.worktree_path, run.seed_id);
                    }
                    catch {
                        // Archive is best-effort — don't block worktree removal
                    }
                    try {
                        await this.vcsBackend.removeWorkspace(this.projectPath, run.worktree_path);
                    }
                    catch {
                        // Non-fatal — worktree may already be gone
                    }
                }
                this.store.updateRun(run.id, {
                    status: "merged",
                    completed_at: new Date().toISOString(),
                });
                this.store.logEvent(run.project_id, "merge", { seedId: run.seed_id, branchName, targetBranch }, run.id);
                // Send merge-complete mail so inbox shows a successful merge event
                this.sendMail(run.id, "merge-complete", {
                    seedId: run.seed_id,
                    branchName,
                    targetBranch,
                });
                // Close the bead NOW — after the code has actually landed in main.
                // projectPath (repo root) is where .beads/ lives; not the worktree dir.
                enqueueCloseSeed(this.store, run.seed_id, "refinery");
                // Send bead-closed mail so inbox shows bead lifecycle completion
                this.sendMail(run.id, "bead-closed", {
                    seedId: run.seed_id,
                    branchName,
                    targetBranch,
                });
                // Rebase any stacked branches (seeds that branched from this one) onto target.
                await this.rebaseStackedBranches(branchName, targetBranch);
                merged.push({
                    runId: run.id,
                    seedId: run.seed_id,
                    branchName,
                });
            }
            catch (err) {
                const message = err instanceof Error ? err.message : String(err);
                // Update run status to "failed" so subsequent bead status sync has a
                // terminal status to map from (fixes the exception gap).
                this.store.updateRun(run.id, { status: "failed" });
                this.store.logEvent(run.project_id, "fail", { seedId: run.seed_id, branchName, error: message }, run.id);
                this.sendMail(run.id, "merge-failed", {
                    seedId: run.seed_id,
                    branchName,
                    reason: "unexpected-error",
                    error: message.slice(0, 400),
                });
                await this.addFailureNote(run.seed_id, `Merge failed: ${message.slice(0, 400)}`);
                testFailures.push({
                    runId: run.id,
                    seedId: run.seed_id,
                    branchName,
                    error: message,
                });
            }
        }
        return { merged, conflicts, testFailures, prsCreated };
    }
    /**
     * Resolve a conflicting run.
     * - 'theirs': re-attempt merge with -X theirs strategy
     * - 'abort': abandon the merge, mark run as failed
     */
    async resolveConflict(runId, strategy, opts) {
        const run = this.store.getRun(runId);
        if (!run)
            throw new Error(`Run ${runId} not found`);
        const branchName = `foreman/${run.seed_id}`;
        if (strategy === "abort") {
            this.store.updateRun(run.id, {
                status: "failed",
                completed_at: new Date().toISOString(),
            });
            this.store.logEvent(run.project_id, "fail", { seedId: run.seed_id, reason: "Conflict resolution aborted by user" }, run.id);
            await this.addFailureNote(run.seed_id, "Merge conflict resolution aborted by user.");
            return false;
        }
        // strategy === 'theirs' — attempt merge with -X theirs
        const targetBranch = opts?.targetBranch ?? await this.vcsBackend.detectDefaultBranch(this.projectPath);
        const runTests = opts?.runTests ?? true;
        const testCommand = opts?.testCommand ?? "npm test";
        try {
            await this.vcsBackend.checkoutBranch(this.projectPath, targetBranch);
            // Use gitSpecial for -X theirs merge strategy (not supported by VcsBackend.merge())
            await gitSpecial(["merge", branchName, "--no-ff", "-X", "theirs"], this.projectPath);
        }
        catch (err) {
            // Merge failed — abort to leave repo in a clean state
            try {
                await gitSpecial(["merge", "--abort"], this.projectPath);
            }
            catch {
                // merge --abort may fail if there is nothing to abort
            }
            // Reset seed to open so it can be retried
            enqueueResetSeedToOpen(this.store, run.seed_id, "refinery");
            const message = err instanceof Error ? err.message : String(err);
            this.store.updateRun(run.id, {
                status: "failed",
                completed_at: new Date().toISOString(),
            });
            this.store.logEvent(run.project_id, "fail", { seedId: run.seed_id, error: message }, run.id);
            await this.addFailureNote(run.seed_id, `Merge failed (theirs strategy): ${message.slice(0, 400)}`);
            return false;
        }
        // Merge succeeded — optionally run tests (Tier 2 safety gate)
        if (runTests) {
            const testResult = await runTestCommand(testCommand, this.projectPath);
            if (!testResult.ok) {
                // Revert the merge
                await gitSpecial(["reset", "--hard", "HEAD~1"], this.projectPath);
                // Reset seed to open so it can be retried
                enqueueResetSeedToOpen(this.store, run.seed_id, "refinery");
                this.store.updateRun(run.id, {
                    status: "test-failed",
                    completed_at: new Date().toISOString(),
                });
                this.store.logEvent(run.project_id, "test-fail", { seedId: run.seed_id, branchName, output: testResult.output.slice(0, 2000) }, run.id);
                await this.addFailureNote(run.seed_id, `Merge failed: tests failed after conflict resolution. ${testResult.output.slice(0, 300)}`);
                return false;
            }
        }
        if (run.worktree_path) {
            try {
                await archiveWorktreeReports(this.projectPath, run.worktree_path, run.seed_id);
            }
            catch {
                // Archive is best-effort — don't block worktree removal
            }
            try {
                await this.vcsBackend.removeWorkspace(this.projectPath, run.worktree_path);
            }
            catch {
                // Non-fatal
            }
        }
        this.store.updateRun(run.id, {
            status: "merged",
            completed_at: new Date().toISOString(),
        });
        this.store.logEvent(run.project_id, "merge", { seedId: run.seed_id, branchName, strategy: "theirs", targetBranch }, run.id);
        // Close the bead after successful conflict-resolution merge.
        enqueueCloseSeed(this.store, run.seed_id, "refinery");
        return true;
    }
    /**
     * Find all completed runs and create PRs for their branches.
     * Pushes branches to origin and uses `gh pr create`.
     *
     * MQ-T058d Investigation: Why `gh pr create` instead of `git town propose`
     * -------------------------------------------------------------------------
     * git town propose (v22.6.0) was investigated for PR creation. Findings:
     *   1. It DOES support --title and --body flags.
     *   2. However, it opens a browser window (`open https://github.com/...`)
     *      rather than creating the PR via the GitHub API.
     *   3. No PR URL is returned in stdout -- only a GitHub compare URL is
     *      opened in the system browser.
     *   4. It also runs `git fetch`, `git stash`, and `git push` as side-effects,
     *      which conflicts with our explicit push step above.
     *
     * Since Foreman agents run non-interactively (see CLAUDE.md critical
     * constraints: "agents hang on interactive prompts"), and we need the PR URL
     * returned for event logging, `gh pr create` remains the correct choice for
     * both normal-flow and conflict PRs.
     *
     * Conflict PRs (ConflictResolver.handleFallback) also use `gh pr create`
     * because they require structured titles with "[Conflict]" prefix and
     * detailed resolution metadata in the body.
     */
    async createPRs(opts) {
        const baseBranch = opts?.baseBranch ?? await this.vcsBackend.detectDefaultBranch(this.projectPath);
        const draft = opts?.draft ?? false;
        const completedRuns = this.store.getRunsByStatus("completed", opts?.projectId);
        const created = [];
        const failed = [];
        for (const run of completedRuns) {
            const branchName = `foreman/${run.seed_id}`;
            try {
                // Push branch to origin
                await this.vcsBackend.push(this.projectPath, branchName);
                // Build PR title and body
                const title = `${run.seed_id}: ${branchName.replace("foreman/", "")}`;
                // Try to get seed info for a better title/body
                let seedTitle = run.seed_id;
                let seedDescription = "";
                try {
                    const seedInfo = await this.seeds.show(run.seed_id);
                    if (seedInfo) {
                        seedTitle = seedInfo.title ?? run.seed_id;
                        seedDescription = seedInfo.description ?? "";
                    }
                }
                catch {
                    // Non-fatal — use defaults
                }
                // Get commit log for the PR body
                let commitLog = "";
                try {
                    commitLog = await gitSpecial(["log", `${baseBranch}..${branchName}`, "--oneline"], this.projectPath);
                }
                catch {
                    // Non-fatal
                }
                const prTitle = `${seedTitle} (${run.seed_id})`;
                const body = [
                    "## Summary",
                    seedDescription || `Agent work for ${run.seed_id}`,
                    "",
                    "## Commits",
                    commitLog ? `\`\`\`\n${commitLog}\n\`\`\`` : "(no commits)",
                    "",
                    `Foreman run: \`${run.id}\``,
                ].join("\n");
                // Create PR via gh CLI
                const ghArgs = [
                    "pr", "create",
                    "--base", baseBranch,
                    "--head", branchName,
                    "--title", prTitle,
                    "--body", body,
                ];
                if (draft)
                    ghArgs.push("--draft");
                const prUrl = await gh(ghArgs, this.projectPath);
                this.store.updateRun(run.id, { status: "pr-created" });
                this.store.logEvent(run.project_id, "pr-created", { seedId: run.seed_id, branchName, baseBranch, prUrl, draft }, run.id);
                created.push({
                    runId: run.id,
                    seedId: run.seed_id,
                    branchName,
                    prUrl,
                });
                // Suppress unused variable warning for `title`
                void title;
            }
            catch (err) {
                const message = err instanceof Error ? err.message : String(err);
                this.store.logEvent(run.project_id, "fail", { seedId: run.seed_id, branchName, error: message }, run.id);
                failed.push({
                    runId: run.id,
                    seedId: run.seed_id,
                    branchName,
                    error: message,
                });
            }
        }
        return { created, failed };
    }
}
/**
 * Preview what merging branches into the target would look like.
 * Reads `git diff --stat` and detects conflicts via `git merge-tree`.
 * No git state is modified.
 *
 * @param projectPath   Repository root
 * @param targetBranch  Branch to merge into (e.g. "main")
 * @param branches      List of branches to check
 * @param filterSeedId  If set, only process this seed
 * @param conflictPatterns  Optional map of file -> resolution tier for estimated tier column
 */
export async function dryRunMerge(projectPath, targetBranch, branches, filterSeedId, conflictPatterns) {
    const results = [];
    const filtered = filterSeedId
        ? branches.filter((b) => b.seedId === filterSeedId)
        : branches;
    for (const { branchName, seedId } of filtered) {
        try {
            // Get merge base
            const mergeBase = await gitReadOnly(["merge-base", targetBranch, branchName], projectPath);
            // Get diff stat (read-only)
            const diffStat = await gitReadOnly(["diff", "--stat", `${targetBranch}...${branchName}`], projectPath);
            // Detect conflicts via merge-tree (read-only, no state change)
            const mergeTreeOutput = await gitReadOnly(["merge-tree", mergeBase, targetBranch, branchName], projectPath);
            const hasConflicts = mergeTreeOutput.includes("changed in both");
            // Estimate resolution tier from conflict patterns
            let estimatedTier;
            if (hasConflicts && conflictPatterns && conflictPatterns.size > 0) {
                // Find the highest (worst) tier among conflicting files
                const conflictFileMatches = Array.from(conflictPatterns.entries())
                    .filter(([file]) => mergeTreeOutput.includes(file));
                if (conflictFileMatches.length > 0) {
                    estimatedTier = Math.max(...conflictFileMatches.map(([, tier]) => tier));
                }
            }
            results.push({ seedId, branchName, diffStat, hasConflicts, estimatedTier });
        }
        catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            results.push({
                seedId,
                branchName,
                diffStat: "",
                hasConflicts: false,
                error: message,
            });
        }
    }
    return results;
}
/** Read-only git command — guaranteed not to modify state. */
async function gitReadOnly(args, cwd) {
    const { stdout } = await execFileAsync("git", args, {
        cwd,
        maxBuffer: PIPELINE_BUFFERS.maxBufferBytes,
    });
    return stdout.trim();
}
/**
 * Preserve `.seeds/` changes from a branch before it is deleted.
 * Extracts `.seeds/` changes via `git diff`, writes a temp patch file,
 * applies it to the current index, and commits with a descriptive message.
 *
 * Error code MQ-019 on patch failure.
 *
 * @param projectPath   Repository root
 * @param branchName    Source branch containing seed changes
 * @param targetBranch  Target branch to apply changes to
 */
export async function preserveBeadChanges(projectPath, branchName, targetBranch) {
    const tmpPatchPath = join(projectPath, `.foreman-seed-patch-${Date.now()}.patch`);
    try {
        // Extract .seeds/ changes
        const patchContent = await gitReadOnly(["diff", `${targetBranch}...${branchName}`, "--", ".seeds/"], projectPath);
        if (!patchContent.trim()) {
            return { preserved: false };
        }
        // Write temp patch
        writeFileSync(tmpPatchPath, patchContent);
        // Apply the patch to the index (gitSpecial: git apply not in VcsBackend)
        try {
            await gitSpecial(["apply", "--index", tmpPatchPath], projectPath);
        }
        catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            return { preserved: false, error: `MQ-019: ${message}` };
        }
        // Commit the seed changes (gitSpecial: need specific message format)
        const seedId = branchName.replace(/^foreman\//, "");
        await gitSpecial(["commit", "-m", `chore: preserve seed changes from ${seedId}`], projectPath);
        return { preserved: true };
    }
    catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return { preserved: false, error: message };
    }
    finally {
        // Always clean up temp file
        try {
            unlinkSync(tmpPatchPath);
        }
        catch {
            // File may not have been created — ignore
        }
    }
}
//# sourceMappingURL=refinery.js.map