import { Command } from "commander";
import chalk from "chalk";
import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot, listWorktrees, removeWorktree, deleteBranch } from "../../lib/git.js";
import { archiveWorktreeReports } from "../../lib/archive-reports.js";
// ── Helpers ───────────────────────────────────────────────────────────────────
/** Statuses considered terminal/cleanable without --all. */
const CLEANABLE_STATUSES = new Set([
    "completed",
    "merged",
    "failed",
    "test-failed",
    "conflict",
    "pr-created",
]);
/**
 * Extract seed ID from a foreman branch name.
 * "foreman/seed-abc" -> "seed-abc"
 */
function seedIdFromBranch(branch) {
    return branch.replace(/^foreman\//, "");
}
// ── Core logic (exported for testing) ─────────────────────────────────────────
/**
 * List all foreman/* worktrees with metadata from the store.
 */
export async function listForemanWorktrees(projectPath, store) {
    const worktrees = await listWorktrees(projectPath);
    const foremanWorktrees = worktrees.filter((wt) => wt.branch.startsWith("foreman/"));
    return foremanWorktrees.map((wt) => {
        const seedId = seedIdFromBranch(wt.branch);
        const runs = store.getRunsForSeed(seedId);
        const latestRun = runs.length > 0 ? runs[0] : null;
        return {
            path: wt.path,
            branch: wt.branch,
            head: wt.head,
            seedId,
            runStatus: latestRun?.status ?? null,
            runId: latestRun?.id ?? null,
            createdAt: latestRun?.created_at ?? null,
        };
    });
}
/**
 * Clean worktrees based on their run status.
 * - Default: only remove worktrees for completed/merged/failed runs.
 * - `all: true`: remove all foreman worktrees.
 * - `force: true`: use force branch deletion.
 * - `dryRun: true`: show what would be removed without making changes.
 */
export async function cleanWorktrees(projectPath, worktrees, opts) {
    let removed = 0;
    const errors = [];
    const wouldRemove = [];
    for (const wt of worktrees) {
        const shouldClean = opts.all ||
            wt.runStatus === null ||
            CLEANABLE_STATUSES.has(wt.runStatus);
        if (!shouldClean)
            continue;
        if (opts.dryRun) {
            removed++;
            wouldRemove.push(wt);
            continue;
        }
        try {
            await archiveWorktreeReports(projectPath, wt.path, wt.seedId);
            await removeWorktree(projectPath, wt.path);
            await deleteBranch(projectPath, wt.branch, {
                force: opts.force,
            });
            removed++;
        }
        catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            errors.push(`${wt.seedId}: ${msg}`);
        }
    }
    return { removed, errors, ...(opts.dryRun ? { wouldRemove } : {}) };
}
// ── CLI command ───────────────────────────────────────────────────────────────
const listSubcommand = new Command("list")
    .description("List all foreman worktrees")
    .option("--json", "Output as JSON")
    .action(async (opts) => {
    try {
        const projectPath = await getRepoRoot(process.cwd());
        const store = ForemanStore.forProject(projectPath);
        const worktrees = await listForemanWorktrees(projectPath, store);
        if (opts.json) {
            console.log(JSON.stringify(worktrees, null, 2));
            store.close();
            return;
        }
        if (worktrees.length === 0) {
            console.log(chalk.yellow("No foreman worktrees found."));
            store.close();
            return;
        }
        console.log(chalk.bold(`Foreman worktrees (${worktrees.length}):\n`));
        for (const wt of worktrees) {
            const age = wt.createdAt
                ? `${Math.round((Date.now() - new Date(wt.createdAt).getTime()) / 60000)}m ago`
                : "unknown";
            const status = wt.runStatus
                ? formatStatus(wt.runStatus)
                : chalk.dim("no run");
            console.log(`  ${chalk.cyan(wt.seedId)} ${status} ${chalk.dim(wt.path)} ${chalk.dim(`(${age})`)}`);
        }
        store.close();
    }
    catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        console.error(chalk.red(`Error: ${message}`));
        process.exit(1);
    }
});
const cleanSubcommand = new Command("clean")
    .description("Remove worktrees for completed/merged/failed runs")
    .option("--all", "Remove all foreman worktrees including active ones")
    .option("--force", "Force-delete branches even if not fully merged")
    .option("--dry-run", "Show what would be removed without making changes")
    .action(async (opts) => {
    try {
        const projectPath = await getRepoRoot(process.cwd());
        const store = ForemanStore.forProject(projectPath);
        const dryRun = opts.dryRun ?? false;
        const worktrees = await listForemanWorktrees(projectPath, store);
        if (worktrees.length === 0) {
            console.log(chalk.yellow("No foreman worktrees to clean."));
            store.close();
            return;
        }
        if (dryRun) {
            console.log(chalk.dim("(dry-run mode — no changes will be made)\n"));
        }
        console.log(chalk.bold("Cleaning foreman worktrees...\n"));
        const result = await cleanWorktrees(projectPath, worktrees, {
            all: Boolean(opts.all),
            force: Boolean(opts.force),
            dryRun,
        });
        if (dryRun && result.wouldRemove && result.wouldRemove.length > 0) {
            console.log(chalk.dim("Worktrees that would be removed:"));
            for (const wt of result.wouldRemove) {
                console.log(`  ${chalk.cyan(wt.seedId)}  ${chalk.dim(wt.path)}`);
            }
        }
        const action = dryRun ? "Would remove" : "Removed";
        console.log(chalk.green.bold(`\n${action} ${result.removed} worktree(s).`));
        if (result.errors.length > 0) {
            console.log(chalk.red(`\nErrors (${result.errors.length}):`));
            for (const err of result.errors) {
                console.log(chalk.red(`  ${err}`));
            }
        }
        store.close();
    }
    catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        console.error(chalk.red(`Error: ${message}`));
        process.exit(1);
    }
});
export const worktreeCommand = new Command("worktree")
    .description("Manage foreman worktrees")
    .addCommand(listSubcommand)
    .addCommand(cleanSubcommand);
// ── Format helpers ────────────────────────────────────────────────────────────
function formatStatus(status) {
    switch (status) {
        case "running":
        case "pending":
            return chalk.blue(status);
        case "completed":
            return chalk.green(status);
        case "merged":
            return chalk.green(status);
        case "failed":
        case "stuck":
        case "test-failed":
        case "conflict":
            return chalk.red(status);
        case "pr-created":
            return chalk.cyan(status);
        default:
            return chalk.dim(status);
    }
}
//# sourceMappingURL=worktree.js.map