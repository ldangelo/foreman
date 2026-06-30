/**
 * WorktreeManager — manages git worktrees at ~/.foreman/worktrees/<project-id>/<bead-id>.
 *
 * Path hierarchy:
 *   ~/.foreman/worktrees/<projectId>/<beadId>
 *
 * Each worktree is a git worktree of the project's repository, checked out
 * on a branch named `foreman/<beadId>`. This keeps per-bead workspaces isolated
 * from the main checkout without polluting the project directory.
 *
 * @module src/lib/worktree-manager
 */
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
// ── Constants ────────────────────────────────────────────────────────────────
function getDefaultWorktreesRoot() {
    return join(homedir(), ".foreman", "worktrees");
}
// ── WorktreeManager ──────────────────────────────────────────────────────────
export class WorktreeManager {
    /**
     * The root directory for all Foreman worktrees.
     * Defaults to ~/.foreman/worktrees.
     */
    root;
    constructor(options = {}) {
        this.root = options.root ?? getDefaultWorktreesRoot();
    }
    /**
     * Find the git repository root by searching:
     * 1. Up from the given path
     * 2. In sibling directories with the project name
     *
     * Returns null if no .git directory is found.
     */
    #findGitRepo(startPath) {
        // 1. Search upward from the given path
        let dir = startPath;
        for (let i = 0; i < 20; i++) {
            if (existsSync(join(dir, ".git"))) {
                return dir;
            }
            const parent = dirname(dir);
            if (parent === dir)
                break;
            dir = parent;
        }
        // 2. Search sibling directories that might contain the git repo
        // Common pattern: ~/.foreman/projects/<store>/ -> ~/Development/Fortium/<repo>
        // Extract project name from the store path (e.g., "foreman-849f2" -> "foreman")
        const storeName = startPath.match(/[^\\/]+$/)?.[0];
        if (storeName) {
            // Extract the base project name (e.g., "foreman-849f2" -> "foreman", "ensemble-42e5a" -> "ensemble")
            const projectName = storeName.replace(/-\w+$/, "");
            // Go up from the store path to find the home directory, stopping at root
            const homeDir = homedir();
            let checkDir = dirname(startPath);
            while (checkDir !== "/" && checkDir !== dirname(homeDir)) {
                const parent = dirname(checkDir);
                if (parent === checkDir)
                    break;
                checkDir = parent;
                // Stop when we reach home or above
                if (checkDir === homeDir || checkDir === dirname(homeDir)) {
                    break;
                }
            }
            // First, look for a directory with the project name at the checkDir level
            const candidate = join(checkDir, projectName);
            if (existsSync(join(candidate, ".git"))) {
                return candidate;
            }
            // If not found, look in sibling directories of checkDir (e.g., ~/Development/Fortium/foreman)
            const checkDirContents = readdirSync(checkDir).filter(d => !d.startsWith("."));
            for (const sibling of checkDirContents) {
                const siblingPath = join(checkDir, sibling);
                // Check if the sibling has a subdirectory with the project name
                if (existsSync(join(siblingPath, projectName, ".git"))) {
                    return join(siblingPath, projectName);
                }
            }
        }
        return null;
    }
    #resolveStartPoint(repoPath, baseBranch) {
        if (!baseBranch)
            return "HEAD";
        try {
            execFileSync("git", ["fetch", "origin", baseBranch, "--prune"], {
                cwd: repoPath,
                stdio: "pipe",
            });
        }
        catch {
            try {
                execFileSync("git", ["fetch", "origin", "--prune"], {
                    cwd: repoPath,
                    stdio: "pipe",
                });
            }
            catch {
                // Offline/local-only repos are valid in tests and development. Fall back
                // to local refs; worktree creation will report a clear error if missing.
            }
        }
        const remoteRef = `origin/${baseBranch}`;
        try {
            execFileSync("git", ["rev-parse", "--verify", remoteRef], {
                cwd: repoPath,
                stdio: "pipe",
            });
            this.#refreshLocalBaseBranch(repoPath, baseBranch, remoteRef);
            return remoteRef;
        }
        catch {
            return baseBranch;
        }
    }
    #refreshLocalBaseBranch(repoPath, baseBranch, remoteRef) {
        try {
            execFileSync("git", ["rev-parse", "--verify", remoteRef], { cwd: repoPath, stdio: "pipe" });
        }
        catch {
            return;
        }
        let currentBranch;
        try {
            currentBranch = execFileSync("git", ["symbolic-ref", "--quiet", "--short", "HEAD"], {
                cwd: repoPath,
                encoding: "utf8",
                stdio: ["ignore", "pipe", "pipe"],
            }).trim();
        }
        catch {
            currentBranch = undefined;
        }
        try {
            if (currentBranch === baseBranch) {
                if (!this.#hasTrackedChanges(repoPath)) {
                    execFileSync("git", ["reset", "--hard", remoteRef], { cwd: repoPath, stdio: "pipe" });
                }
            }
            else {
                execFileSync("git", ["branch", "-f", baseBranch, remoteRef], { cwd: repoPath, stdio: "pipe" });
            }
        }
        catch {
            // Best-effort only. Worktree creation still uses origin/<baseBranch>, so
            // a locked/dirty local branch cannot make new worktrees stale.
        }
    }
    #hasTrackedChanges(repoPath) {
        try {
            execFileSync("git", ["diff", "--quiet"], { cwd: repoPath, stdio: "pipe" });
            execFileSync("git", ["diff", "--cached", "--quiet"], { cwd: repoPath, stdio: "pipe" });
            return false;
        }
        catch {
            return true;
        }
    }
    #pruneWorktrees(repoPath) {
        try {
            execFileSync("git", ["worktree", "prune"], { cwd: repoPath, stdio: "pipe" });
        }
        catch {
            // Best-effort cleanup only. Worktree creation below will surface any
            // remaining git errors with task-specific context.
        }
    }
    /**
     * Get the worktree directory for a specific project+bead.
     */
    getWorktreePath(projectId, beadId) {
        return join(this.root, projectId, beadId);
    }
    /**
     * Get the worktrees directory for a project.
     */
    getProjectRoot(projectId) {
        return join(this.root, projectId);
    }
    /**
     * Create a git worktree for a bead.
     *
     * Branch: foreman/<beadId>
     * Path: ~/.foreman/worktrees/<projectId>/<beadId>
     *
     * If the worktree already exists, rebases onto the base branch.
     * If the branch already exists but has no worktree, attaches a new worktree.
     *
     * @throws Error if creation/rebase fails after cleanup
     */
    async createWorktree(options) {
        const { projectId, beadId, repoPath, baseBranch } = options;
        const branchName = `foreman/${beadId}`;
        const worktreePath = this.getWorktreePath(projectId, beadId);
        // Resolve the actual git repo path. The provided repoPath may be a store
        // directory rather than the git repo root. Search up the tree for .git.
        const resolvedRepoPath = this.#findGitRepo(repoPath) ?? repoPath;
        const startPoint = this.#resolveStartPoint(resolvedRepoPath, baseBranch);
        // Ensure parent directory exists
        mkdirSync(this.getProjectRoot(projectId), { recursive: true, mode: 0o700 });
        // Remove stale worktree registrations before creating/attaching. A reset can
        // delete the workspace directory while git still believes the branch is
        // checked out at the old path; without pruning, `git branch -f` refuses to
        // reset that branch and daemon dispatch silently skips the task.
        this.#pruneWorktrees(resolvedRepoPath);
        // If worktree already exists — reuse it with rebase
        if (existsSync(worktreePath)) {
            await this._rebaseWorktree(worktreePath, startPoint);
            return { projectId, beadId, branchName, path: worktreePath, exists: true, created: false };
        }
        // Branch may exist without a worktree — reset it to the clean start point
        // before attaching. A stale leftover branch must not inherit old internal
        // state when dispatch is intended to start fresh.
        try {
            execFileSync("git", ["worktree", "add", "-b", branchName, worktreePath, startPoint], {
                cwd: resolvedRepoPath,
                stdio: "pipe",
            });
        }
        catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            if (msg.includes("already exists")) {
                execFileSync("git", ["branch", "-f", branchName, startPoint], {
                    cwd: resolvedRepoPath,
                    stdio: "pipe",
                });
                execFileSync("git", ["worktree", "add", worktreePath, branchName], {
                    cwd: resolvedRepoPath,
                    stdio: "pipe",
                });
            }
            else if (msg.includes("fatal")) {
                throw new Error(`Failed to create worktree at ${worktreePath}: ${msg}`);
            }
            else {
                throw err;
            }
        }
        return { projectId, beadId, branchName, path: worktreePath, exists: true, created: true };
    }
    /**
     * Remove a worktree and its branch.
     */
    async removeWorktree(projectId, beadId, repoPath) {
        const worktreePath = this.getWorktreePath(projectId, beadId);
        if (!existsSync(worktreePath))
            return;
        try {
            execFileSync("git", ["worktree", "remove", worktreePath, "--force"], {
                cwd: repoPath,
                stdio: "pipe",
            });
        }
        catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            if (!msg.includes("is not a working tree")) {
                // Not a registered worktree — just remove the directory
                try {
                    rmSync(worktreePath, { recursive: true, force: true });
                }
                catch { /* ignore */ }
            }
        }
    }
    /**
     * List all worktrees for a project.
     */
    listWorktrees(projectId) {
        const projectRoot = this.getProjectRoot(projectId);
        if (!existsSync(projectRoot))
            return [];
        const worktrees = [];
        try {
            for (const entry of readdirSync(projectRoot, { withFileTypes: true })) {
                if (!entry.isDirectory())
                    continue;
                const beadId = entry.name;
                const worktreePath = join(projectRoot, beadId);
                const branchName = `foreman/${beadId}`;
                worktrees.push({
                    projectId,
                    beadId,
                    branchName,
                    path: worktreePath,
                    exists: existsSync(worktreePath),
                });
            }
        }
        catch { /* empty or inaccessible directory */ }
        return worktrees;
    }
    /**
     * List all worktrees across all projects.
     */
    listAllWorktrees() {
        if (!existsSync(this.root))
            return [];
        const results = [];
        try {
            for (const entry of readdirSync(this.root, { withFileTypes: true })) {
                if (!entry.isDirectory())
                    continue;
                const projectId = entry.name;
                results.push({
                    projectId,
                    worktrees: this.listWorktrees(projectId),
                });
            }
        }
        catch { /* empty or inaccessible */ }
        return results;
    }
    /**
     * Clean up stale worktree directories that are no longer valid git worktrees.
     * Returns the number of directories removed.
     */
    cleanStaleWorktrees(projectId) {
        const worktrees = this.listWorktrees(projectId);
        let removed = 0;
        for (const wt of worktrees) {
            if (!existsSync(wt.path))
                continue;
            // Check if it's a valid git worktree by looking for .git file
            const gitFile = join(wt.path, ".git");
            const isValidWorktree = existsSync(gitFile) || existsSync(join(wt.path, ".git"));
            if (!isValidWorktree) {
                try {
                    rmSync(wt.path, { recursive: true, force: true });
                    removed++;
                }
                catch { /* ignore */ }
            }
        }
        return removed;
    }
    // ── Private helpers ──────────────────────────────────────────────────────
    async _rebaseWorktree(worktreePath, baseBranch) {
        try {
            execFileSync("git", ["rebase", baseBranch], {
                cwd: worktreePath,
                stdio: "pipe",
            });
        }
        catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            const hasUnstaged = msg.includes("unstaged") || msg.includes("uncommitted");
            if (hasUnstaged) {
                // Discard changes and rebase
                try {
                    execFileSync("git", ["checkout", "--", "."], { cwd: worktreePath, stdio: "pipe" });
                    execFileSync("git", ["clean", "-fd"], { cwd: worktreePath, stdio: "pipe" });
                    execFileSync("git", ["rebase", baseBranch], { cwd: worktreePath, stdio: "pipe" });
                }
                catch (retryErr) {
                    const retryMsg = retryErr instanceof Error ? retryErr.message : String(retryErr);
                    try {
                        execFileSync("git", ["rebase", "--abort"], { cwd: worktreePath, stdio: "pipe" });
                    }
                    catch { /* ok */ }
                    throw new Error(`Rebase failed after cleanup: ${retryMsg}`);
                }
            }
            else {
                try {
                    execFileSync("git", ["rebase", "--abort"], { cwd: worktreePath, stdio: "pipe" });
                }
                catch { /* ok */ }
                throw new Error(`Rebase failed: ${msg.slice(0, 300)}`);
            }
        }
    }
}
//# sourceMappingURL=worktree-manager.js.map