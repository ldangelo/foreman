import { access, stat, rm, readFile, readdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import { ForemanStore } from "../lib/store.js";
import type { Run } from "../lib/store.js";
import { listWorktrees, removeWorktree, branchExistsOnOrigin, detectDefaultBranch } from "../lib/git.js";
import { archiveWorktreeReports } from "../lib/archive-reports.js";
import type { CheckResult, DoctorReport } from "./types.js";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";
import type { MergeQueue, MergeQueueEntry, ExecFileAsyncFn } from "./merge-queue.js";
import type { ITaskClient } from "../lib/task-client.js";
import { findMissingPrompts, installBundledPrompts, findMissingSkills, installBundledSkills } from "../lib/prompt-loader.js";
import { findMissingWorkflows, installBundledWorkflows } from "../lib/workflow-loader.js";
import { syncBeadStatusOnStartup } from "./task-backend-ops.js";

const execFileAsync = promisify(execFile);

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function extractPid(sessionKey: string | null): number | null {
  if (!sessionKey) return null;
  const m = sessionKey.match(/pid-(\d+)/);
  return m ? parseInt(m[1], 10) : null;
}

/**
 * Returns true if the run was spawned as a Pi-based agent worker.
 * Pi workers use session_key format: "foreman:sdk:<model>:<runId>[:<suffix>]"
 * These workers do not have a PID in the session_key, so PID-based liveness
 * checks do not apply — liveness is detected by stale timeouts.
 */
function isSDKBasedRun(sessionKey: string | null): boolean {
  return sessionKey?.startsWith("foreman:sdk:") ?? false;
}

// ── Doctor class ─────────────────────────────────────────────────────────

export class Doctor {
  private mergeQueue?: MergeQueue;
  private taskClient?: ITaskClient;
  /**
   * Injected execFile-like function used only by `isBranchMerged`.
   * Defaults to the real `execFileAsync`; can be overridden in tests to avoid
   * spawning real git processes.
   */
  private execFn: ExecFileAsyncFn;

  constructor(
    private store: ForemanStore,
    private projectPath: string,
    mergeQueue?: MergeQueue,
    taskClient?: ITaskClient,
    execFn?: ExecFileAsyncFn,
  ) {
    this.mergeQueue = mergeQueue;
    this.taskClient = taskClient;
    this.execFn = execFn ?? (execFileAsync as ExecFileAsyncFn);
  }

  // ── System checks ──────────────────────────────────────────────────

  async checkBrBinary(): Promise<CheckResult> {
    const brPath = join(homedir(), ".local", "bin", "br");
    try {
      await access(brPath);
      return {
        name: "br (beads_rust) CLI binary",
        status: "pass",
        message: `Found at ${brPath}`,
      };
    } catch {
      return {
        name: "br (beads_rust) CLI binary",
        status: "fail",
        message: `Not found at ${brPath}. Install via: cargo install beads_rust`,
      };
    }
  }

  async checkBvBinary(): Promise<CheckResult> {
    const bvPath = join(homedir(), ".local", "bin", "bv");
    try {
      await access(bvPath);
      return {
        name: "bv (beads_viewer) CLI binary",
        status: "pass",
        message: `Found at ${bvPath}`,
      };
    } catch {
      return {
        name: "bv (beads_viewer) CLI binary",
        status: "fail",
        message: `Not found at ${bvPath}. Install via: cargo install beads_viewer`,
      };
    }
  }

  async checkGitBinary(): Promise<CheckResult> {
    try {
      await execFileAsync("git", ["--version"]);
      return {
        name: "git binary",
        status: "pass",
        message: "git is available",
      };
    } catch {
      return {
        name: "git binary",
        status: "fail",
        message: "git not found in PATH",
      };
    }
  }

  async checkGitTownInstalled(): Promise<CheckResult> {
    try {
      await execFileAsync("git", ["town", "--version"]);
      return {
        name: "git town installed",
        status: "pass",
        message: "git town is installed",
      };
    } catch {
      return {
        name: "git town installed",
        status: "fail",
        message: "git town not found",
        details: "Install with: brew install git-town",
      };
    }
  }

  async checkGitTownMainBranch(): Promise<CheckResult> {
    // Skip if git town is not installed
    const installed = await this.checkGitTownInstalled();
    if (installed.status !== "pass") {
      return {
        name: "git town main branch configured",
        status: "skip",
        message: "Skipped: git town not installed",
      };
    }

    let configuredBranch: string;
    try {
      const { stdout } = await execFileAsync("git", ["config", "--get", "git-town.main-branch"], {
        cwd: this.projectPath,
      });
      configuredBranch = stdout.trim();
    } catch {
      return {
        name: "git town main branch configured",
        status: "warn",
        message: "git town not configured",
        details: "Run: git town setup",
      };
    }

    if (!configuredBranch) {
      return {
        name: "git town main branch configured",
        status: "warn",
        message: "git town not configured",
        details: "Run: git town setup",
      };
    }

    let defaultBranch: string;
    try {
      defaultBranch = await detectDefaultBranch(this.projectPath);
    } catch {
      return {
        name: "git town main branch configured",
        status: "warn",
        message: "Could not detect repo default branch (skipping comparison)",
      };
    }

    if (configuredBranch === defaultBranch) {
      return {
        name: "git town main branch configured",
        status: "pass",
        message: "git town main branch matches repo default",
      };
    }

    return {
      name: "git town main branch configured",
      status: "warn",
      message: "git town main-branch does not match repo default branch",
      details: `git town main-branch="${configuredBranch}", repo default="${defaultBranch}". Fix with: git town config set main-branch ${defaultBranch}`,
    };
  }

  // ── Jujutsu (jj) checks — TRD-028 ────────────────────────────────────

  /**
   * Check whether the `jj` CLI binary is available in PATH.
   *
   * Returns:
   * - pass  — jj found and responds to `jj --version`
   * - warn  — jj not found but VCS config is 'auto' (jj not required unless detected)
   * - fail  — jj not found and VCS config explicitly requires jujutsu
   *
   * @param vcsBackend - Current VCS backend setting: 'git' | 'jujutsu' | 'auto' | undefined
   */
  async checkJjBinary(vcsBackend?: 'git' | 'jujutsu' | 'auto'): Promise<CheckResult> {
    let version: string | null = null;
    try {
      const { stdout } = await execFileAsync("jj", ["--version"]);
      version = stdout.trim();
    } catch {
      // jj not in PATH
    }

    if (version !== null) {
      return {
        name: "jj (Jujutsu) binary",
        status: "pass",
        message: `jj found: ${version}`,
      };
    }

    // jj not found — severity depends on configured backend
    if (vcsBackend === 'jujutsu') {
      return {
        name: "jj (Jujutsu) binary",
        status: "fail",
        message: "jj not found in PATH",
        details: "Foreman is configured with vcs.backend=jujutsu but jj is not installed.\n" +
          "Install jj: https://martinvonz.github.io/jj/latest/install-and-setup/\n" +
          "  macOS:  brew install jj\n" +
          "  cargo:  cargo install --locked jj-cli",
      };
    }

    if (vcsBackend === 'auto') {
      return {
        name: "jj (Jujutsu) binary",
        status: "warn",
        message: "jj not found in PATH (vcs.backend=auto)",
        details: "If your project uses Jujutsu, install jj: https://martinvonz.github.io/jj/latest/install-and-setup/\n" +
          "  macOS: brew install jj\n" +
          "Git-only projects are unaffected.",
      };
    }

    // vcsBackend = 'git' or undefined — jj is not needed
    return {
      name: "jj (Jujutsu) binary",
      status: "skip",
      message: "jj not required (vcs.backend=git)",
    };
  }

  /**
   * Check that the project repository is a colocated Jujutsu+Git repo.
   *
   * Colocated repos have both `.jj/` and `.git/` directories and the
   * `.jj/repo/store/git` symlink pointing at the git repo's objects.
   *
   * Returns:
   * - pass  — colocated repo structure confirmed
   * - warn  — .jj exists but .jj/repo/store/git missing (may not be colocated)
   * - fail  — .jj exists but .git is missing (bare jj repo — Foreman unsupported)
   * - skip  — .jj directory absent (not a jj repo)
   */
  async checkJjColocatedRepo(): Promise<CheckResult> {
    const jjDir = join(this.projectPath, ".jj");
    const gitDir = join(this.projectPath, ".git");
    const storeGit = join(jjDir, "repo", "store", "git");

    // Check if this is a jj repository at all
    const jjExists = existsSync(jjDir);
    if (!jjExists) {
      return {
        name: "jj colocated repository",
        status: "skip",
        message: "Not a Jujutsu repository (.jj not found)",
      };
    }

    // jj repo found — check for .git (colocated requirement)
    const gitExists = existsSync(gitDir);
    if (!gitExists) {
      return {
        name: "jj colocated repository",
        status: "fail",
        message: "Non-colocated Jujutsu repository detected",
        details: ".jj exists but .git is missing. Foreman requires a colocated Jujutsu+Git\n" +
          "repository. Initialize with: jj git init --colocate",
      };
    }

    // Check colocated structure — .jj/repo/store/git should exist
    const storeGitExists = existsSync(storeGit);
    if (!storeGitExists) {
      return {
        name: "jj colocated repository",
        status: "warn",
        message: "jj repository may not be in colocated mode",
        details: `.jj/repo/store/git not found at ${storeGit}.\n` +
          "Foreman requires colocated Jujutsu+Git mode. If this is a new repo,\n" +
          "reinitialize with: jj git init --colocate",
      };
    }

    return {
      name: "jj colocated repository",
      status: "pass",
      message: "Colocated Jujutsu+Git repository confirmed",
    };
  }

  /**
   * Check the installed jj version against a minimum requirement.
   *
   * @param minVersion - Minimum required version string (e.g. "0.16.0").
   *                     If not provided, any version is acceptable.
   */
  async checkJjVersion(minVersion?: string): Promise<CheckResult> {
    let versionStr: string;
    try {
      const { stdout } = await execFileAsync("jj", ["--version"]);
      versionStr = stdout.trim();
    } catch {
      return {
        name: "jj version",
        status: "skip",
        message: "jj not found — skipping version check",
      };
    }

    if (!minVersion) {
      return {
        name: "jj version",
        status: "pass",
        message: `jj version: ${versionStr} (no minimum required)`,
      };
    }

    // Parse semver-like version from output (e.g. "jj 0.18.0" → "0.18.0")
    const versionMatch = versionStr.match(/(\d+)\.(\d+)\.(\d+)/);
    const minMatch = minVersion.match(/(\d+)\.(\d+)\.(\d+)/);

    if (!versionMatch || !minMatch) {
      return {
        name: "jj version",
        status: "warn",
        message: `Could not parse jj version: ${versionStr}`,
        details: `Expected format: x.y.z. Minimum required: ${minVersion}`,
      };
    }

    const [, maj, min, patch] = versionMatch.map(Number);
    const [, minMaj, minMin, minPatch] = minMatch.map(Number);

    const isOk =
      maj > minMaj ||
      (maj === minMaj && min > minMin) ||
      (maj === minMaj && min === minMin && patch >= minPatch);

    if (isOk) {
      return {
        name: "jj version",
        status: "pass",
        message: `jj version ${maj}.${min}.${patch} meets minimum ${minVersion}`,
      };
    }

    return {
      name: "jj version",
      status: "fail",
      message: `jj version ${maj}.${min}.${patch} is below minimum ${minVersion}`,
      details: `Upgrade jj: https://martinvonz.github.io/jj/latest/install-and-setup/\n` +
        `  macOS: brew upgrade jj`,
    };
  }

  async checkSystem(): Promise<CheckResult[]> {
    // TRD-024: sd backend removed. Always check br and bv binaries.
    const [brResult, bvResult, gitResult, gitTownInstalled, gitTownMainBranch, oldLogsResult] = await Promise.all([
      this.checkBrBinary(),
      this.checkBvBinary(),
      this.checkGitBinary(),
      this.checkGitTownInstalled(),
      this.checkGitTownMainBranch(),
      this.checkOldLogs(),
    ]);
    return [brResult, bvResult, gitResult, gitTownInstalled, gitTownMainBranch, oldLogsResult];
  }

  /**
   * Check for stale agent log files in ~/.foreman/logs/.
   * Warns when there are many log groups older than 7 days,
   * encouraging the user to run `foreman purge-logs` or `foreman doctor --clean-logs`.
   */
  async checkOldLogs(thresholdDays = 7, warnThreshold = 10): Promise<CheckResult> {
    const logsDir = join(homedir(), ".foreman", "logs");
    const uuidPattern =
      /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.[a-z]+$/i;

    let entries: { name: string; mtimeMs: number }[];
    try {
      const dirents = await readdir(logsDir, { withFileTypes: true });
      const statResults = await Promise.allSettled(
        dirents
          .filter((d) => d.isFile())
          .map(async (d) => {
            const s = await stat(join(logsDir, d.name));
            return { name: d.name, mtimeMs: s.mtimeMs };
          }),
      );
      entries = statResults
        .filter((r): r is PromiseFulfilledResult<{ name: string; mtimeMs: number }> =>
          r.status === "fulfilled",
        )
        .map((r) => r.value);
    } catch (err: unknown) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") {
        return {
          name: "old agent log files",
          status: "pass",
          message: "No logs directory — nothing to clean up",
        };
      }
      const msg = err instanceof Error ? err.message : String(err);
      return {
        name: "old agent log files",
        status: "warn",
        message: `Could not scan logs directory: ${msg}`,
      };
    }

    const cutoffMs = Date.now() - thresholdDays * 24 * 60 * 60 * 1000;
    const oldRunIds = new Set<string>();

    for (const entry of entries) {
      const match = uuidPattern.exec(entry.name);
      if (!match) continue;
      if (entry.mtimeMs < cutoffMs) {
        oldRunIds.add(match[1]);
      }
    }

    const totalRunIds = new Set<string>(
      entries
        .map((e) => uuidPattern.exec(e.name)?.[1])
        .filter((id): id is string => id !== undefined),
    );

    if (oldRunIds.size === 0) {
      return {
        name: "old agent log files",
        status: "pass",
        message: `${totalRunIds.size} log group(s) found, none older than ${thresholdDays} days`,
      };
    }

    if (oldRunIds.size < warnThreshold) {
      return {
        name: "old agent log files",
        status: "pass",
        message: `${oldRunIds.size} log group(s) older than ${thresholdDays} days (${totalRunIds.size} total) — run 'foreman purge-logs' to clean up`,
      };
    }

    return {
      name: "old agent log files",
      status: "warn",
      message: `${oldRunIds.size} log group(s) older than ${thresholdDays} days (${totalRunIds.size} total)`,
      details: "Run 'foreman purge-logs' or 'foreman doctor --clean-logs' to reclaim disk space",
    };
  }

  // ── Repository checks ──────────────────────────────────────────────

  async checkDatabaseFile(): Promise<CheckResult> {
    const dbPath = join(this.projectPath, ".foreman", "foreman.db");
    try {
      await stat(dbPath);
      return {
        name: "foreman database",
        status: "pass",
        message: `Found at ${dbPath}`,
      };
    } catch {
      return {
        name: "foreman database",
        status: "warn",
        message: `Database not yet created at ${dbPath}. It will be created on first use.`,
      };
    }
  }

  async checkProjectRegistered(): Promise<CheckResult> {
    const project = this.store.getProjectByPath(this.projectPath);
    if (project) {
      return {
        name: "project registered in foreman",
        status: "pass",
        message: `Project "${project.name}" (${project.status})`,
      };
    }
    return {
      name: "project registered in foreman",
      status: "fail",
      message: `No project registered for ${this.projectPath}. Run 'foreman init' first.`,
    };
  }

  async checkBeadsInitialized(): Promise<CheckResult> {
    const beadsDir = join(this.projectPath, ".beads");
    if (existsSync(beadsDir)) {
      return {
        name: "beads (.beads/) initialized",
        status: "pass",
        message: ".beads directory found",
      };
    }
    return {
      name: "beads (.beads/) initialized",
      status: "fail",
      message: `No .beads directory at ${beadsDir}. Run 'foreman init' first.`,
    };
  }

  /**
   * Check that all required prompt files are installed in .foreman/prompts/.
   * With --fix, reinstalls missing prompts from bundled defaults.
   */
  async checkPrompts(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;

    const missing = findMissingPrompts(this.projectPath);

    if (missing.length === 0) {
      return {
        name: "prompt templates (.foreman/prompts/)",
        status: "pass",
        message: "All required prompt files are installed",
      };
    }

    const missingList = missing.join(", ");

    if (dryRun) {
      return {
        name: "prompt templates (.foreman/prompts/)",
        status: "fail",
        message: `${missing.length} missing prompt file(s): ${missingList}. Would reinstall (dry-run).`,
      };
    }

    if (fix) {
      try {
        const { installed } = installBundledPrompts(this.projectPath, false);
        // Re-check after install
        const stillMissing = findMissingPrompts(this.projectPath);
        if (stillMissing.length === 0) {
          return {
            name: "prompt templates (.foreman/prompts/)",
            status: "fixed",
            message: `${missing.length} missing prompt file(s)`,
            fixApplied: `Installed ${installed.length} prompt file(s) from bundled defaults`,
          };
        } else {
          return {
            name: "prompt templates (.foreman/prompts/)",
            status: "fail",
            message: `${stillMissing.length} prompt file(s) still missing after reinstall: ${stillMissing.join(", ")}`,
          };
        }
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          name: "prompt templates (.foreman/prompts/)",
          status: "fail",
          message: `Failed to reinstall prompts: ${msg}`,
        };
      }
    }

    return {
      name: "prompt templates (.foreman/prompts/)",
      status: "fail",
      message: `${missing.length} missing prompt file(s): ${missingList}. Run 'foreman init' or 'foreman doctor --fix' to reinstall.`,
    };
  }

  /**
   * Check that required Pi skills are installed in ~/.pi/agent/skills/.
   * With --fix, installs missing skills from bundled defaults.
   */
  async checkPiSkills(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;
    const missing = findMissingSkills();

    if (missing.length === 0) {
      return {
        name: "Pi skills (~/.pi/agent/skills/)",
        status: "pass",
        message: "All required Pi skills are installed",
      };
    }

    const missingList = missing.join(", ");

    if (dryRun) {
      return {
        name: "Pi skills (~/.pi/agent/skills/)",
        status: "fail",
        message: `${missing.length} missing Pi skill(s): ${missingList}. Would install (dry-run).`,
      };
    }

    if (fix) {
      try {
        const { installed } = installBundledSkills();
        const stillMissing = findMissingSkills();
        if (stillMissing.length === 0) {
          return {
            name: "Pi skills (~/.pi/agent/skills/)",
            status: "fixed",
            message: `${missing.length} missing Pi skill(s)`,
            fixApplied: `Installed ${installed.length} skill(s) to ~/.pi/agent/skills/`,
          };
        }
        return {
          name: "Pi skills (~/.pi/agent/skills/)",
          status: "fail",
          message: `${stillMissing.length} Pi skill(s) still missing after install: ${stillMissing.join(", ")}`,
        };
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          name: "Pi skills (~/.pi/agent/skills/)",
          status: "fail",
          message: `Failed to install Pi skills: ${msg}`,
        };
      }
    }

    return {
      name: "Pi skills (~/.pi/agent/skills/)",
      status: "fail",
      message: `${missing.length} missing Pi skill(s): ${missingList}. Run 'foreman init' or 'foreman doctor --fix' to install.`,
    };
  }

  /**
   * Check that all bundled workflow YAML files are installed in .foreman/workflows/.
   * With --fix, reinstalls missing workflow configs from bundled defaults.
   */
  async checkWorkflows(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;

    const missing = findMissingWorkflows(this.projectPath);

    if (missing.length === 0) {
      return {
        name: "workflow configs (.foreman/workflows/)",
        status: "pass",
        message: "All required workflow config files are installed",
      };
    }

    const missingList = missing.map((n) => `${n}.yaml`).join(", ");

    if (dryRun) {
      return {
        name: "workflow configs (.foreman/workflows/)",
        status: "fail",
        message: `${missing.length} missing workflow config(s): ${missingList}. Would reinstall (dry-run).`,
      };
    }

    if (fix) {
      try {
        const { installed } = installBundledWorkflows(this.projectPath, false);
        const stillMissing = findMissingWorkflows(this.projectPath);
        if (stillMissing.length === 0) {
          return {
            name: "workflow configs (.foreman/workflows/)",
            status: "fixed",
            message: `${missing.length} missing workflow config(s)`,
            fixApplied: `Installed ${installed.length} workflow config(s) from bundled defaults`,
          };
        }
        return {
          name: "workflow configs (.foreman/workflows/)",
          status: "fail",
          message: `${stillMissing.length} workflow config(s) still missing after reinstall: ${stillMissing.map((n) => `${n}.yaml`).join(", ")}`,
        };
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          name: "workflow configs (.foreman/workflows/)",
          status: "fail",
          message: `Failed to reinstall workflow configs: ${msg}`,
        };
      }
    }

    return {
      name: "workflow configs (.foreman/workflows/)",
      status: "fail",
      message: `${missing.length} missing workflow config(s): ${missingList}. Run 'foreman init' or 'foreman doctor --fix' to reinstall.`,
    };
  }

  async checkRepository(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult[]> {
    // TRD-024: sd backend removed. Always check for .beads initialization.
    const results: CheckResult[] = [];
    results.push(await this.checkDatabaseFile());
    results.push(await this.checkProjectRegistered());
    results.push(await this.checkBeadsInitialized());
    results.push(await this.checkPrompts(opts));
    results.push(await this.checkPiSkills(opts));
    results.push(await this.checkWorkflows(opts));
    return results;
  }

  // ── Data integrity checks ─────────────────────────────────────────

  async checkOrphanedWorktrees(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult[]> {
    const results: CheckResult[] = [];
    const { fix = false, dryRun = false } = opts;

    let worktrees;
    try {
      worktrees = await listWorktrees(this.projectPath);
    } catch {
      results.push({
        name: "orphaned worktrees",
        status: "warn",
        message: "Could not list worktrees (skipping check)",
      });
      return results;
    }

    const foremanWorktrees = worktrees.filter(
      (wt) => wt.branch && wt.branch.startsWith("foreman/"),
    );

    if (foremanWorktrees.length === 0) {
      results.push({
        name: "orphaned worktrees",
        status: "pass",
        message: "No foreman worktrees found",
      });
      return results;
    }

    for (const wt of foremanWorktrees) {
      const seedId = wt.branch.slice("foreman/".length);
      const runs = this.store.getRunsForSeed(seedId);
      const activeRun = runs.find((r: Run) =>
        ["pending", "running"].includes(r.status) && r.worktree_path === wt.path,
      );
      const completedRun = runs.find((r: Run) => r.status === "completed");
      const mergedRun = runs.find((r: Run) => r.status === "merged");
      const prCreatedRun = runs.find((r: Run) => r.status === "pr-created");
      const failableRun = runs.find((r: Run) =>
        (["failed", "stuck", "conflict", "test-failed"] as Run["status"][]).includes(r.status),
      );

      if (activeRun) {
        if (activeRun.status === "running") {
          if (isSDKBasedRun(activeRun.session_key)) {
            // Pi-based workers don't have a PID — liveness is checked via stale timeouts.
            results.push({
              name: `worktree: ${seedId}`,
              status: "pass",
              message: `Active run (${activeRun.status}) for seed ${seedId} — SDK-based worker`,
            });
          } else {
            // For traditional PID-based runs, verify the process is actually alive
            const pid = extractPid(activeRun.session_key);
            const alive = pid !== null && isProcessAlive(pid);
            if (alive) {
              results.push({
                name: `worktree: ${seedId}`,
                status: "pass",
                message: `Active run (${activeRun.status}) for seed ${seedId}`,
              });
            } else {
              results.push({
                name: `worktree: ${seedId}`,
                status: "warn",
                message: `Zombie run: status=running but no live process${pid ? ` (pid ${pid})` : ""}. Run 'foreman doctor --fix' to clean up.`,
              });
            }
          }
        } else {
          // pending runs don't have a process to check
          results.push({
            name: `worktree: ${seedId}`,
            status: "pass",
            message: `Active run (${activeRun.status}) for seed ${seedId}`,
          });
        }
      } else if (mergedRun) {
        if (dryRun) {
          results.push({
            name: `worktree: ${seedId}`,
            status: "warn",
            message: `Already merged — stale worktree at ${wt.path}. Would remove (dry-run).`,
          });
        } else if (fix) {
          try {
            await archiveWorktreeReports(this.projectPath, wt.path, seedId).catch(() => {});
            await removeWorktree(this.projectPath, wt.path);
            try { await execFileAsync("git", ["worktree", "prune"], { cwd: this.projectPath }); } catch { /* */ }
            results.push({
              name: `worktree: ${seedId}`,
              status: "fixed",
              message: `Already merged — stale worktree`,
              fixApplied: `Removed worktree at ${wt.path}`,
            });
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            results.push({
              name: `worktree: ${seedId}`,
              status: "warn",
              message: `Already merged but could not auto-remove: ${msg}`,
            });
          }
        } else {
          results.push({
            name: `worktree: ${seedId}`,
            status: "warn",
            message: `Already merged — stale worktree. Use --fix to remove.`,
          });
        }
      } else if (completedRun) {
        results.push({
          name: `worktree: ${seedId}`,
          status: "warn",
          message: `Needs merge. Run: foreman merge --seed ${seedId}`,
        });
      } else if (prCreatedRun) {
        results.push({
          name: `worktree: ${seedId}`,
          status: "warn",
          message: `PR open — awaiting manual review/merge (run ${prCreatedRun.id.slice(0, 8)})`,
        });
      } else if (failableRun) {
        const hint = failableRun.status === "failed" || failableRun.status === "test-failed"
          ? "use 'foreman reset' to retry"
          : failableRun.status === "stuck"
            ? "use 'foreman reset' to recover"
            : "resolve merge conflict manually";
        results.push({
          name: `worktree: ${seedId}`,
          status: "warn",
          message: `Run in '${failableRun.status}' state — ${hint}`,
        });
      } else {
        // Check if the branch exists on origin before removing locally.
        // NOTE: Uses locally-cached remote-tracking refs; does NOT network-fetch.
        // Run `git fetch` first if you need an authoritative answer.
        const onOrigin = await branchExistsOnOrigin(this.projectPath, wt.branch);
        if (onOrigin) {
          // Branch exists on origin — never auto-remove regardless of fix/dryRun.
          const dryRunSuffix = dryRun ? " (dry-run: would not remove either way)" : "";
          results.push({
            name: `worktree: ${seedId}`,
            status: "warn",
            message: `Orphaned worktree at ${wt.path} (no runs) but branch exists on origin — skipping auto-removal${dryRunSuffix}. Verify and remove manually if safe.`,
          });
        } else if (dryRun) {
          results.push({
            name: `worktree: ${seedId}`,
            status: "warn",
            message: `Orphaned worktree at ${wt.path} (no runs, not on origin). Would remove (dry-run).`,
          });
        } else if (fix) {
          try {
            await archiveWorktreeReports(this.projectPath, wt.path, seedId).catch(() => {});
            await removeWorktree(this.projectPath, wt.path);
            try { await execFileAsync("git", ["worktree", "prune"], { cwd: this.projectPath }); } catch { /* */ }
            results.push({
              name: `worktree: ${seedId}`,
              status: "fixed",
              message: `Orphaned worktree (no runs, not on origin)`,
              fixApplied: `Removed worktree at ${wt.path}`,
            });
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            results.push({
              name: `worktree: ${seedId}`,
              status: "warn",
              message: `Orphaned worktree — could not auto-remove: ${msg}`,
            });
          }
        } else {
          results.push({
            name: `worktree: ${seedId}`,
            status: "warn",
            message: `Orphaned worktree at ${wt.path} (no runs, not on origin). Use --fix to remove.`,
          });
        }
      }
    }

    return results;
  }

  async checkZombieRuns(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult[]> {
    const { fix = false, dryRun = false } = opts;
    const project = this.store.getProjectByPath(this.projectPath);
    if (!project) return [];

    const runningRuns = this.store.getRunsByStatus("running", project.id);
    if (runningRuns.length === 0) {
      return [
        {
          name: "zombie runs (running, no process)",
          status: "pass",
          message: "No running runs in database",
        },
      ];
    }

    const results: CheckResult[] = [];
    for (const run of runningRuns) {
      // Pi-based workers do not store a PID in session_key.
      // Liveness is detected only by stale timeouts, not PID checks.
      if (isSDKBasedRun(run.session_key)) {
        results.push({
          name: `run: ${run.seed_id} [${run.agent_type}]`,
          status: "pass",
          message: `Pi-based worker — liveness checked via timeout, not PID`,
        });
        continue;
      }

      const pid = extractPid(run.session_key);
      const isAlive = pid !== null && isProcessAlive(pid);

      if (isAlive) {
        results.push({
          name: `run: ${run.seed_id} [${run.agent_type}]`,
          status: "pass",
          message: `Process pid ${pid} is alive`,
        });
      } else {
        if (dryRun) {
          results.push({
            name: `run: ${run.seed_id} [${run.agent_type}]`,
            status: "warn",
            message: `Zombie run: status=running but no live process${pid ? ` (pid ${pid})` : ""}. Would mark failed (dry-run).`,
          });
        } else if (fix) {
          this.store.updateRun(run.id, {
            status: "failed",
            completed_at: new Date().toISOString(),
          });
          results.push({
            name: `run: ${run.seed_id} [${run.agent_type}]`,
            status: "fixed",
            message: `Zombie run (status=running, no live process${pid ? ` for pid ${pid}` : ""})`,
            fixApplied: "Marked as failed",
          });
        } else {
          results.push({
            name: `run: ${run.seed_id} [${run.agent_type}]`,
            status: "warn",
            message: `Zombie run: status=running but no live process${pid ? ` (pid ${pid})` : ""}. Use --fix to mark failed.`,
          });
        }
      }
    }

    return results;
  }

  async checkStalePendingRuns(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;
    const project = this.store.getProjectByPath(this.projectPath);
    if (!project) {
      return {
        name: "stale pending runs",
        status: "pass",
        message: "No project registered (skipping)",
      };
    }

    const pendingRuns = this.store.getRunsByStatus("pending", project.id);
    const staleThresholdMs = PIPELINE_TIMEOUTS.staleRunHours * 60 * 60 * 1000;
    const now = Date.now();

    const staleRuns = pendingRuns.filter((r) => {
      const age = now - new Date(r.created_at).getTime();
      return age > staleThresholdMs;
    });

    if (staleRuns.length === 0) {
      return {
        name: `stale pending runs (>${PIPELINE_TIMEOUTS.staleRunHours}h)`,
        status: "pass",
        message: `${pendingRuns.length} pending run(s), none older than ${PIPELINE_TIMEOUTS.staleRunHours}h`,
      };
    }

    if (dryRun) {
      return {
        name: `stale pending runs (>${PIPELINE_TIMEOUTS.staleRunHours}h)`,
        status: "warn",
        message: `${staleRuns.length} stale pending run(s). Would mark failed (dry-run).`,
      };
    }

    if (fix) {
      for (const run of staleRuns) {
        this.store.updateRun(run.id, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
      }
      return {
        name: `stale pending runs (>${PIPELINE_TIMEOUTS.staleRunHours}h)`,
        status: "fixed",
        message: `${staleRuns.length} stale pending run(s)`,
        fixApplied: `Marked ${staleRuns.length} run(s) as failed`,
      };
    }

    return {
      name: `stale pending runs (>${PIPELINE_TIMEOUTS.staleRunHours}h)`,
      status: "warn",
      message: `${staleRuns.length} pending run(s) older than ${PIPELINE_TIMEOUTS.staleRunHours}h. Use --fix to mark failed.`,
    };
  }

  /**
   * Read the beads JSONL and return a Set of seed IDs that are closed.
   * Falls back to an empty set on any read/parse error (non-fatal).
   */
  private async getClosedSeedIds(): Promise<Set<string>> {
    const jsonlPath = join(this.projectPath, ".beads", "issues.jsonl");
    const closed = new Set<string>();
    try {
      const raw = await readFile(jsonlPath, "utf8");
      for (const line of raw.split("\n")) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          const entry = JSON.parse(trimmed) as { id?: string; status?: string };
          if (entry.id && entry.status === "closed") {
            closed.add(entry.id);
          }
        } catch {
          // malformed line — skip
        }
      }
    } catch {
      // File missing or unreadable — return empty set
    }
    return closed;
  }

  /**
   * Check whether `foreman/<seedId>` has already been merged into `defaultBranch`.
   *
   * Uses `git merge-base --is-ancestor` which exits 0 if the branch tip is an
   * ancestor of the default branch (i.e. fully merged).  Returns false on any
   * git error so the caller treats the run as still problematic.
   */
  private async isBranchMerged(seedId: string, defaultBranch: string): Promise<boolean> {
    const branchName = `foreman/${seedId}`;
    try {
      await this.execFn(
        "git",
        ["merge-base", "--is-ancestor", branchName, defaultBranch],
        { cwd: this.projectPath },
      );
      return true; // exit 0 → branch is an ancestor → already merged
    } catch {
      return false; // non-zero exit or any error → not merged / branch missing
    }
  }

  async checkFailedStuckRuns(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult[]> {
    const { fix = false, dryRun = false } = opts;
    const project = this.store.getProjectByPath(this.projectPath);
    if (!project) return [];

    const results: CheckResult[] = [];

    // Detect the default branch once; fall back gracefully on errors.
    let defaultBranch: string;
    try {
      defaultBranch = await detectDefaultBranch(this.projectPath);
    } catch {
      defaultBranch = "main";
    }

    // Collect seed IDs that are already closed in beads so we can auto-resolve
    // stale run records without hitting git at all.
    const closedSeeds = await this.getClosedSeedIds();

    /**
     * For a set of runs (all failed or all stuck), filter out those that are
     * already resolved (seed closed or branch merged) and auto-mark them as
     * completed in the store.  Returns the subset that still needs attention.
     */
    const filterAutoResolved = async (
      runs: import("../lib/store.js").Run[],
    ): Promise<{ unresolved: import("../lib/store.js").Run[]; autoResolvedCount: number }> => {
      let autoResolvedCount = 0;
      const unresolved: import("../lib/store.js").Run[] = [];

      for (const run of runs) {
        // If the bead/seed is already closed, the run record is stale.
        if (closedSeeds.has(run.seed_id)) {
          this.store.updateRun(run.id, { status: "completed" });
          autoResolvedCount++;
          continue;
        }

        // If the branch has already been merged, the run is done.
        const merged = await this.isBranchMerged(run.seed_id, defaultBranch);
        if (merged) {
          this.store.updateRun(run.id, { status: "completed" });
          autoResolvedCount++;
          continue;
        }

        unresolved.push(run);
      }

      return { unresolved, autoResolvedCount };
    };

    const failedRuns = this.store.getRunsByStatus("failed", project.id);
    const stuckRuns = this.store.getRunsByStatus("stuck", project.id);

    const { unresolved: unresolvedFailed, autoResolvedCount: failedResolved } =
      await filterAutoResolved(failedRuns);
    const { unresolved: unresolvedStuck, autoResolvedCount: stuckResolved } =
      await filterAutoResolved(stuckRuns);

    const totalResolved = failedResolved + stuckResolved;
    if (totalResolved > 0) {
      results.push({
        name: "failed/stuck runs (auto-resolved)",
        status: "fixed",
        message: `Auto-resolved ${totalResolved} run(s) whose branch was already merged or seed was already closed`,
        fixApplied: `Marked ${totalResolved} run(s) as completed`,
      });
    }

    // ── Distinguish actionable vs. noise failures ─────────────────────────────
    // A failed run is "noise" (historical retry) if the same seed has a later
    // successful run (completed or merged).  These are not actionable.
    const { actionable: actionableFailed, historical: historicalFailed } =
      this.partitionByHistoricalRetry(unresolvedFailed);

    // ── Age-based cleanup of historical-retry runs ────────────────────────────
    // Historical retries that are older than the retention threshold can be
    // cleaned up automatically with --fix.
    const retentionMs = PIPELINE_TIMEOUTS.failedRunRetentionDays * 24 * 60 * 60 * 1000;
    const now = Date.now();

    const agedHistoricalFailed = historicalFailed.filter((r) => {
      const age = now - new Date(r.created_at).getTime();
      return age > retentionMs;
    });
    const recentHistoricalFailed = historicalFailed.filter((r) => {
      const age = now - new Date(r.created_at).getTime();
      return age <= retentionMs;
    });

    // Also age-partition unresolved stuck runs (no historical-retry check for stuck)
    const agedStuck = unresolvedStuck.filter((r) => {
      const age = now - new Date(r.created_at).getTime();
      return age > retentionMs;
    });
    const recentStuck = unresolvedStuck.filter((r) => {
      const age = now - new Date(r.created_at).getTime();
      return age <= retentionMs;
    });

    // Total runs eligible for age-based cleanup
    const agedTotal = agedHistoricalFailed.length + agedStuck.length;

    if (agedTotal > 0) {
      if (dryRun) {
        results.push({
          name: `failed/stuck runs (aged, dry-run)`,
          status: "warn",
          message: `${agedTotal} failed/stuck run(s) older than ${PIPELINE_TIMEOUTS.failedRunRetentionDays} day(s) are eligible for cleanup. Would mark as completed (dry-run). Re-run with --fix to apply.`,
        });
      } else if (fix) {
        const allAged = [...agedHistoricalFailed, ...agedStuck];
        for (const run of allAged) {
          this.store.updateRun(run.id, { status: "completed" });
        }
        results.push({
          name: `failed/stuck runs (aged, cleaned up)`,
          status: "fixed",
          message: `Cleaned up ${agedTotal} aged failed/stuck run(s) older than ${PIPELINE_TIMEOUTS.failedRunRetentionDays} day(s)`,
          fixApplied: `Marked ${agedTotal} aged run(s) as completed`,
        });
      } else {
        results.push({
          name: `failed/stuck runs (aged)`,
          status: "warn",
          message: `${agedTotal} failed/stuck run(s) are older than ${PIPELINE_TIMEOUTS.failedRunRetentionDays} day(s). Use --fix to clean up.`,
        });
      }
    }

    // Report historical retries that are within the retention window (informational)
    if (recentHistoricalFailed.length > 0) {
      results.push({
        name: `failed runs (historical retries)`,
        status: "warn",
        message: `${recentHistoricalFailed.length} failed run(s) are historical retries (seed later completed): ${recentHistoricalFailed.slice(0, 5).map((r) => r.seed_id).join(", ")}${recentHistoricalFailed.length > 5 ? "..." : ""}. These will be auto-cleaned after ${PIPELINE_TIMEOUTS.failedRunRetentionDays} day(s).`,
      });
    }

    // Actionable failures: seeds with ONLY failed runs — need attention
    if (actionableFailed.length > 0) {
      results.push({
        name: `failed runs`,
        status: "warn",
        message: `${actionableFailed.length} failed run(s): ${actionableFailed.slice(0, 5).map((r) => r.seed_id).join(", ")}${actionableFailed.length > 5 ? "..." : ""}. Use 'foreman reset' to retry.`,
      });
    }

    // Stuck runs that are recent (actionable)
    if (recentStuck.length > 0) {
      results.push({
        name: `stuck runs`,
        status: "warn",
        message: `${recentStuck.length} stuck run(s): ${recentStuck.slice(0, 5).map((r) => r.seed_id).join(", ")}${recentStuck.length > 5 ? "..." : ""}. Use 'foreman reset' to retry or 'foreman run --resume' to continue.`,
      });
    }

    const hasAnyIssue =
      totalResolved > 0 ||
      agedTotal > 0 ||
      recentHistoricalFailed.length > 0 ||
      actionableFailed.length > 0 ||
      recentStuck.length > 0;

    if (!hasAnyIssue) {
      results.push({
        name: "failed/stuck runs",
        status: "pass",
        message: "No failed or stuck runs",
      });
    }

    return results;
  }

  /**
   * Partition unresolved failed runs into "actionable" (seed has only failed runs)
   * and "historical" (seed has a later completed or merged run — noise from retries).
   */
  private partitionByHistoricalRetry(
    runs: import("../lib/store.js").Run[],
  ): { actionable: import("../lib/store.js").Run[]; historical: import("../lib/store.js").Run[] } {
    const actionable: import("../lib/store.js").Run[] = [];
    const historical: import("../lib/store.js").Run[] = [];

    for (const run of runs) {
      const allSeedRuns = this.store.getRunsForSeed(run.seed_id);
      const hasLaterSuccess = allSeedRuns.some(
        (r) =>
          ["completed", "merged"].includes(r.status) &&
          new Date(r.created_at).getTime() > new Date(run.created_at).getTime(),
      );
      if (hasLaterSuccess) {
        historical.push(run);
      } else {
        actionable.push(run);
      }
    }

    return { actionable, historical };
  }

  async checkRunStateConsistency(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult[]> {
    const { fix = false, dryRun = false } = opts;
    const project = this.store.getProjectByPath(this.projectPath);
    if (!project) return [];

    const results: CheckResult[] = [];

    // Check for runs with completed_at set but still in running/pending status
    const activeRuns = this.store.getActiveRuns(project.id);
    const inconsistentRuns = activeRuns.filter((r) => r.completed_at !== null);

    if (inconsistentRuns.length === 0) {
      results.push({
        name: "run state consistency",
        status: "pass",
        message: "All run states are consistent",
      });
    } else {
      for (const run of inconsistentRuns) {
        if (dryRun) {
          results.push({
            name: `run state: ${run.seed_id} [${run.agent_type}]`,
            status: "warn",
            message: `Run has completed_at set but status="${run.status}". Would mark as failed (dry-run).`,
          });
        } else if (fix) {
          this.store.updateRun(run.id, { status: "failed" });
          results.push({
            name: `run state: ${run.seed_id} [${run.agent_type}]`,
            status: "fixed",
            message: `Inconsistent state: completed_at set but status was "${run.status}"`,
            fixApplied: "Marked as failed",
          });
        } else {
          results.push({
            name: `run state: ${run.seed_id} [${run.agent_type}]`,
            status: "warn",
            message: `Inconsistent run state: completed_at set but status="${run.status}". Use --fix to repair.`,
          });
        }
      }
    }

    return results;
  }

  /**
   * Check for bead status drift between SQLite and the br backend.
   *
   * Calls syncBeadStatusOnStartup() to detect (and optionally fix) mismatches
   * between the run status recorded in SQLite and the corresponding seed status
   * in br.  Drift occurs when foreman was interrupted before a br update could
   * complete (e.g. after a crash, token exhaustion, or manual reset).
   *
   * Modes:
   *   - No flags / warn-only: detects mismatches but does not fix them.
   *   - fix=true, dryRun=false: detects and applies fixes via br update.
   *   - dryRun=true: detects mismatches but never applies fixes (dryRun wins over fix).
   *
   * Returns:
   *   pass  — no mismatches detected
   *   warn  — mismatches detected but not fixed (no --fix or dryRun mode)
   *   fixed — mismatches were detected and fixed
   *   fail  — the sync operation itself threw an unexpected error
   *   skip  — no project registered or no task client configured
   */
  async checkBeadStatusSync(opts: { fix?: boolean; dryRun?: boolean; projectPath?: string } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;
    const projectPath = opts.projectPath ?? this.projectPath;

    if (!this.taskClient) {
      return {
        name: "bead status sync (SQLite ↔ br)",
        status: "skip",
        message: "No task client configured — skipping bead status reconciliation",
      };
    }

    const project = this.store.getProjectByPath(this.projectPath);
    if (!project) {
      return {
        name: "bead status sync (SQLite ↔ br)",
        status: "skip",
        message: "No project registered — skipping bead status reconciliation",
      };
    }

    let result: Awaited<ReturnType<typeof syncBeadStatusOnStartup>>;
    try {
      // First pass: always run in dry-run mode to detect mismatches without side effects
      result = await syncBeadStatusOnStartup(this.store, this.taskClient, project.id, {
        dryRun: true,
        projectPath,
      });
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      return {
        name: "bead status sync (SQLite ↔ br)",
        status: "fail",
        message: `Bead status sync failed: ${msg}`,
      };
    }

    if (result.mismatches.length === 0) {
      return {
        name: "bead status sync (SQLite ↔ br)",
        status: "pass",
        message: "SQLite and br bead statuses are in sync",
      };
    }

    const mismatchList = result.mismatches
      .slice(0, 5)
      .map((m) => `${m.seedId}: br=${m.actualSeedStatus} → expected=${m.expectedSeedStatus}`)
      .join("; ");
    const truncated = result.mismatches.length > 5 ? ` … +${result.mismatches.length - 5} more` : "";

    if (dryRun) {
      return {
        name: "bead status sync (SQLite ↔ br)",
        status: "warn",
        message: `${result.mismatches.length} bead status mismatch(es) detected. Would fix (dry-run): ${mismatchList}${truncated}`,
        details: mismatchList + truncated,
      };
    }

    if (fix) {
      // Second pass: apply fixes
      let fixResult: Awaited<ReturnType<typeof syncBeadStatusOnStartup>>;
      try {
        fixResult = await syncBeadStatusOnStartup(this.store, this.taskClient, project.id, {
          dryRun: false,
          projectPath,
        });
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          name: "bead status sync (SQLite ↔ br)",
          status: "fail",
          message: `Bead status sync (fix pass) failed: ${msg}`,
          details: mismatchList + truncated,
        };
      }

      const errSuffix = fixResult.errors.length > 0
        ? ` (${fixResult.errors.length} error(s): ${fixResult.errors[0]})`
        : "";
      return {
        name: "bead status sync (SQLite ↔ br)",
        status: "fixed",
        message: `${fixResult.mismatches.length} bead status mismatch(es) detected`,
        fixApplied: `Fixed ${fixResult.synced} seed status(es) in br${errSuffix}`,
        details: mismatchList + truncated,
      };
    }

    return {
      name: "bead status sync (SQLite ↔ br)",
      status: "warn",
      message: `${result.mismatches.length} bead status mismatch(es) detected between SQLite and br. Use --fix to repair: ${mismatchList}${truncated}`,
      details: mismatchList + truncated,
    };
  }

  async checkBrRecoveryArtifacts(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;

    // br doctor --repair creates .br_recovery/ at the project root as a sibling to .beads/
    // It should be removed after successful recovery; stale artifacts indicate incomplete recovery.
    // NOTE: verify this path matches beads_rust behavior — it may also appear at .beads/.br_recovery/
    const recoveryPath = join(this.projectPath, ".br_recovery");
    try {
      await stat(recoveryPath);
      // Directory exists — stale recovery artifacts
      // dryRun takes precedence over fix
      if (dryRun) {
        return {
          name: "br recovery artifacts (.br_recovery/)",
          status: "warn",
          message: `.br_recovery/ directory exists — stale artifacts from incomplete recovery. Would remove (dry-run).`,
        };
      }
      if (fix) {
        try {
          await rm(recoveryPath, { recursive: true, force: true });
          return {
            name: "br recovery artifacts (.br_recovery/)",
            status: "fixed",
            message: "Stale .br_recovery/ directory from incomplete recovery",
            fixApplied: `Removed ${recoveryPath}`,
          };
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          return {
            name: "br recovery artifacts (.br_recovery/)",
            status: "warn",
            message: `.br_recovery/ exists but could not auto-remove: ${msg}`,
          };
        }
      }
      return {
        name: "br recovery artifacts (.br_recovery/)",
        status: "warn",
        message: `.br_recovery/ directory exists — stale artifacts detected. If recovery completed successfully, use --fix to remove stale artifacts; otherwise run 'br doctor --repair' to retry.`,
      };
    } catch {
      // Directory does not exist — no stale artifacts
      return {
        name: "br recovery artifacts (.br_recovery/)",
        status: "pass",
        message: "No stale recovery artifacts found",
      };
    }
  }

  async checkBlockedSeeds(): Promise<CheckResult> {
    if (!this.taskClient) {
      return {
        name: "blocked seeds",
        status: "skip",
        message: "No task client configured",
      };
    }

    let openSeeds: Awaited<ReturnType<typeof this.taskClient.list>>;
    let readySeeds: Awaited<ReturnType<typeof this.taskClient.ready>>;
    try {
      [openSeeds, readySeeds] = await Promise.all([
        this.taskClient.list({ status: "open" }),
        this.taskClient.ready(),
      ]);
    } catch {
      return {
        name: "blocked seeds",
        status: "warn",
        message: "Could not list seeds (skipping check)",
      };
    }

    const readyIds = new Set(readySeeds.map((s) => s.id));
    const blockedSeeds = openSeeds.filter((s) => !readyIds.has(s.id));

    if (blockedSeeds.length === 0) {
      return {
        name: "blocked seeds",
        status: "pass",
        message: "No blocked seeds",
      };
    }

    const list = blockedSeeds.map((s) => `${s.id} (${s.title})`).join(", ");
    return {
      name: "blocked seeds",
      status: "warn",
      message: `${blockedSeeds.length} blocked seed(s): ${list}`,
    };
  }

  // ── Merge queue checks ──────────────────────────────────────────────

  /**
   * Check for merge queue entries stuck in pending/merging for >24h (MQ-008).
   */
  async checkStaleMergeQueueEntries(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;

    if (!this.mergeQueue) {
      return { name: "stale merge queue entries", status: "pass", message: "No merge queue configured (skipping)" };
    }

    const allEntries = this.mergeQueue.list();
    const staleThresholdMs = 24 * 60 * 60 * 1000;
    const now = Date.now();

    const staleEntries = allEntries.filter((e) => {
      if (e.status !== "pending" && e.status !== "merging") return false;
      const timestamp = e.status === "merging" && e.started_at
        ? new Date(e.started_at).getTime()
        : new Date(e.enqueued_at).getTime();
      return now - timestamp > staleThresholdMs;
    });

    if (staleEntries.length === 0) {
      return { name: "stale merge queue entries (>24h)", status: "pass", message: `No stale entries` };
    }

    if (dryRun) {
      return {
        name: "stale merge queue entries (>24h)",
        status: "warn",
        message: `MQ-008: ${staleEntries.length} stale entry(ies). Would mark failed (dry-run).`,
      };
    }

    if (fix) {
      for (const entry of staleEntries) {
        this.mergeQueue.updateStatus(entry.id, "failed", {
          error: "MQ-008: Stale entry auto-failed by doctor",
          completedAt: new Date().toISOString(),
        });
      }
      return {
        name: "stale merge queue entries (>24h)",
        status: "fixed",
        message: `MQ-008: ${staleEntries.length} stale entry(ies)`,
        fixApplied: `Marked ${staleEntries.length} entry(ies) as failed`,
      };
    }

    return {
      name: "stale merge queue entries (>24h)",
      status: "warn",
      message: `MQ-008: ${staleEntries.length} stale entry(ies) in pending/merging >24h. Use --fix to mark failed.`,
    };
  }

  /**
   * Check for duplicate branch entries in the merge queue (MQ-009).
   */
  async checkDuplicateMergeQueueEntries(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;

    if (!this.mergeQueue) {
      return { name: "duplicate merge queue entries", status: "pass", message: "No merge queue configured (skipping)" };
    }

    const pending = this.mergeQueue.list("pending");
    const branchCounts = new Map<string, MergeQueueEntry[]>();
    for (const entry of pending) {
      const existing = branchCounts.get(entry.branch_name) ?? [];
      existing.push(entry);
      branchCounts.set(entry.branch_name, existing);
    }

    const duplicates = Array.from(branchCounts.entries()).filter(
      ([, entries]) => entries.length > 1,
    );

    if (duplicates.length === 0) {
      return { name: "duplicate merge queue entries", status: "pass", message: "No duplicate branch entries" };
    }

    const dupBranches = duplicates.map(([branch]) => branch).join(", ");

    if (dryRun) {
      return {
        name: "duplicate merge queue entries",
        status: "warn",
        message: `MQ-009: Duplicate entries for: ${dupBranches}. Would remove duplicates (dry-run).`,
      };
    }

    if (fix) {
      let removed = 0;
      for (const [, entries] of duplicates) {
        // Keep max(id), remove others
        const maxId = Math.max(...entries.map((e) => e.id));
        for (const entry of entries) {
          if (entry.id !== maxId) {
            this.mergeQueue.remove(entry.id);
            removed++;
          }
        }
      }
      return {
        name: "duplicate merge queue entries",
        status: "fixed",
        message: `MQ-009: Duplicate entries for: ${dupBranches}`,
        fixApplied: `Removed ${removed} duplicate entry(ies), kept latest`,
      };
    }

    return {
      name: "duplicate merge queue entries",
      status: "warn",
      message: `MQ-009: Duplicate entries for: ${dupBranches}. Use --fix to remove duplicates.`,
    };
  }

  /**
   * Check for merge queue entries referencing non-existent runs (MQ-010).
   */
  async checkOrphanedMergeQueueEntries(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;

    if (!this.mergeQueue) {
      return { name: "orphaned merge queue entries", status: "pass", message: "No merge queue configured (skipping)" };
    }

    const allEntries = this.mergeQueue.list();
    const orphaned = allEntries.filter((e) => !this.store.getRun(e.run_id));

    if (orphaned.length === 0) {
      return { name: "orphaned merge queue entries", status: "pass", message: "All entries reference existing runs" };
    }

    if (dryRun) {
      return {
        name: "orphaned merge queue entries",
        status: "warn",
        message: `MQ-010: ${orphaned.length} orphaned entry(ies). Would delete (dry-run).`,
      };
    }

    if (fix) {
      for (const entry of orphaned) {
        this.mergeQueue.remove(entry.id);
      }
      return {
        name: "orphaned merge queue entries",
        status: "fixed",
        message: `MQ-010: ${orphaned.length} orphaned entry(ies)`,
        fixApplied: `Deleted ${orphaned.length} entry(ies)`,
      };
    }

    return {
      name: "orphaned merge queue entries",
      status: "warn",
      message: `MQ-010: ${orphaned.length} orphaned entry(ies) referencing non-existent runs. Use --fix to delete.`,
    };
  }

  /**
   * Check for completed runs that are not present in the merge queue (MQ-011).
   * Detects runs that completed but were never enqueued — e.g. because their
   * branch was deleted before reconciliation ran, or because a system crash
   * prevented reconciliation from completing.
   *
   * When fix=true, calls mergeQueue.reconcile() to enqueue the missing runs.
   */
  async checkCompletedRunsNotQueued(opts: {
    fix?: boolean;
    dryRun?: boolean;
    projectPath?: string;
    execFileFn?: ExecFileAsyncFn | undefined;
  } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;

    if (!this.mergeQueue) {
      return {
        name: "completed runs queued",
        status: "skip",
        message: "No merge queue configured (skipping)",
      };
    }

    const missing = this.mergeQueue.missingFromQueue();

    if (missing.length === 0) {
      return {
        name: "completed runs queued",
        status: "pass",
        message: "All completed runs are in the merge queue",
      };
    }

    const details = missing.map((r) => `${r.seed_id} (run ${r.run_id})`).join(", ");

    if (dryRun) {
      return {
        name: "completed runs queued",
        status: "warn",
        message: `MQ-011: ${missing.length} completed run(s) not in merge queue. Would reconcile (dry-run).`,
        details,
      };
    }

    if (fix && opts.projectPath) {
      try {
        const execFn: ExecFileAsyncFn = opts.execFileFn ?? (execFileAsync as ExecFileAsyncFn);
        const result = await this.mergeQueue.reconcile(
          this.store.getDb(),
          opts.projectPath,
          execFn,
        );
        return {
          name: "completed runs queued",
          status: "fixed",
          message: `MQ-011: ${missing.length} completed run(s) not in merge queue`,
          fixApplied: `Reconciled: ${result.enqueued} enqueued, ${result.skipped} skipped, ${result.invalidBranch} invalid branch(es)`,
        };
      } catch (reconcileErr: unknown) {
        const msg = reconcileErr instanceof Error ? reconcileErr.message : String(reconcileErr);
        return {
          name: "completed runs queued",
          status: "warn",
          message: `MQ-011: ${missing.length} completed run(s) not in merge queue. Reconcile failed: ${msg}`,
          details,
        };
      }
    }

    return {
      name: "completed runs queued",
      status: "warn",
      message: `MQ-011: ${missing.length} completed run(s) not in merge queue. Run: foreman merge`,
      details,
    };
  }

  /**
   * Check for merge queue entries stuck in conflict/failed for >1h (MQ-012).
   */
  async checkStuckConflictFailedEntries(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;

    if (!this.mergeQueue) {
      return { name: "stuck conflict/failed entries", status: "pass", message: "No merge queue configured (skipping)" };
    }

    const allEntries = this.mergeQueue.list();
    const stuckThresholdMs = 60 * 60 * 1000; // 1 hour
    const now = Date.now();

    const stuckEntries = allEntries.filter((e) => {
      if (e.status !== "conflict" && e.status !== "failed") return false;
      const timestamp = e.completed_at
        ? new Date(e.completed_at).getTime()
        : new Date(e.enqueued_at).getTime();
      return now - timestamp > stuckThresholdMs;
    });

    if (stuckEntries.length === 0) {
      return { name: "stuck conflict/failed entries (>1h)", status: "pass", message: "No stuck entries" };
    }

    if (dryRun) {
      return {
        name: "stuck conflict/failed entries (>1h)",
        status: "warn",
        message: `MQ-012: ${stuckEntries.length} entry(ies) stuck in conflict/failed >1h. Would suggest retry (dry-run).`,
      };
    }

    if (fix) {
      let requeued = 0;
      for (const entry of stuckEntries) {
        if (this.mergeQueue.reEnqueue(entry.id)) {
          requeued++;
        }
      }
      return {
        name: "stuck conflict/failed entries (>1h)",
        status: "fixed",
        message: `MQ-012: ${stuckEntries.length} stuck entry(ies)`,
        fixApplied: `Re-enqueued ${requeued} entry(ies) for retry`,
      };
    }

    const seedIds = stuckEntries.map((e) => e.seed_id).join(", ");
    return {
      name: "stuck conflict/failed entries (>1h)",
      status: "warn",
      message: `MQ-012: ${stuckEntries.length} entry(ies) stuck in conflict/failed >1h (${seedIds}). Use --fix to retry or 'foreman merge --auto-retry'.`,
    };
  }

  /**
   * Run all merge queue health checks.
   */
  async checkMergeQueueHealth(opts: { fix?: boolean; dryRun?: boolean; projectPath?: string } = {}): Promise<CheckResult[]> {
    const [stale, duplicates, orphaned, notQueued, stuckConflictFailed] = await Promise.all([
      this.checkStaleMergeQueueEntries(opts),
      this.checkDuplicateMergeQueueEntries(opts),
      this.checkOrphanedMergeQueueEntries(opts),
      this.checkCompletedRunsNotQueued({ fix: opts.fix, dryRun: opts.dryRun, projectPath: opts.projectPath }),
      this.checkStuckConflictFailedEntries(opts),
    ]);
    return [stale, duplicates, orphaned, notQueued, stuckConflictFailed];
  }

  /**
   * Check for run records in the legacy global store (~/.foreman/foreman.db) that
   * are absent from the project-local store (.foreman/foreman.db).  This can occur
   * when a run completed before the bd-sjd migration to project-local stores was
   * fully rolled out.
   *
   * With --fix the orphaned records (and their associated costs/events) are copied
   * into the project-local store so that 'foreman merge' can see them.
   */
  async checkOrphanedGlobalStoreRuns(opts: { fix?: boolean; dryRun?: boolean } = {}): Promise<CheckResult> {
    const { fix = false, dryRun = false } = opts;
    const checkName = "orphaned global-store runs";
    const globalDbPath = join(homedir(), ".foreman", "foreman.db");

    // If the global store doesn't exist there is nothing to migrate.
    if (!existsSync(globalDbPath)) {
      return { name: checkName, status: "pass", message: "No legacy global store found" };
    }

    let globalStore: ForemanStore | null = null;
    try {
      globalStore = new ForemanStore(globalDbPath);
      const globalDb = globalStore.getDb();
      const projects = globalStore.listProjects();

      // Collect orphaned runs: completed or pr-created runs in the global store
      // whose project-local store already exists on disk (meaning the project
      // migrated to project-local storage but this particular run record was
      // written before the migration).
      const orphaned: Array<{
        run: Run;
        projectPath: string;
        projectName: string;
        projectId: string;
      }> = [];

      for (const project of projects) {
        const localDbPath = join(project.path, ".foreman", "foreman.db");
        if (!existsSync(localDbPath)) {
          // Project has no local store yet — nothing to migrate into.
          continue;
        }

        // Query global store for completed/pr-created runs for this project.
        const globalRuns = (globalDb
          .prepare(
            "SELECT * FROM runs WHERE project_id = ? AND status IN ('completed', 'pr-created') ORDER BY created_at ASC"
          )
          .all(project.id) as Run[]);

        if (globalRuns.length === 0) continue;

        // Open the local store and check which run IDs are already present.
        let localStore: ForemanStore | null = null;
        try {
          localStore = ForemanStore.forProject(project.path);
          const localDb = localStore.getDb();
          const existingIds = new Set(
            (localDb.prepare("SELECT id FROM runs").all() as Array<{ id: string }>).map(
              (r) => r.id
            )
          );

          for (const run of globalRuns) {
            if (!existingIds.has(run.id)) {
              orphaned.push({
                run,
                projectPath: project.path,
                projectName: project.name,
                projectId: project.id,
              });
            }
          }
        } finally {
          localStore?.close();
        }
      }

      if (orphaned.length === 0) {
        return {
          name: checkName,
          status: "pass",
          message: "No orphaned global-store runs found",
        };
      }

      const summary = `${orphaned.length} orphaned run(s) found in legacy global store across ${new Set(orphaned.map((o) => o.projectPath)).size} project(s)`;

      if (dryRun) {
        const details = orphaned
          .map((o) => `  ${o.run.id} (seed: ${o.run.seed_id}, project: ${o.projectName})`)
          .join("\n");
        return {
          name: checkName,
          status: "warn",
          message: `${summary}. Would migrate (dry-run).`,
          details,
        };
      }

      if (!fix) {
        return {
          name: checkName,
          status: "warn",
          message: `${summary}. Use --fix to migrate them to the project-local store.`,
        };
      }

      // Apply fix: copy each orphaned run (and related costs/events) into the
      // project-local store.
      let migratedCount = 0;
      const errors: string[] = [];

      for (const { run, projectPath, projectName, projectId } of orphaned) {
        let localStore: ForemanStore | null = null;
        try {
          localStore = ForemanStore.forProject(projectPath);
          const localDb = localStore.getDb();

          // Ensure the project record exists in the local store so the FK
          // constraint on runs.project_id is satisfied.
          const localProject = localStore.getProjectByPath(projectPath);
          const targetProjectId = localProject?.id ?? projectId;

          if (!localProject) {
            // Register the project in the local store using the same ID so that
            // we don't need to rewrite the run's project_id.
            localDb
              .prepare(
                `INSERT OR IGNORE INTO projects (id, name, path, status, created_at, updated_at)
                 VALUES (?, ?, ?, 'active', ?, ?)`
              )
              .run(
                projectId,
                projectName,
                projectPath,
                new Date().toISOString(),
                new Date().toISOString()
              );
          }

          const effectiveProjectId = localProject ? targetProjectId : projectId;

          // Insert the run record — INSERT OR IGNORE to be idempotent.
          localDb
            .prepare(
              `INSERT OR IGNORE INTO runs
                 (id, project_id, seed_id, agent_type, session_key, worktree_path,
                  status, started_at, completed_at, created_at, base_branch, tmux_session, progress)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
            )
            .run(
              run.id,
              effectiveProjectId,
              run.seed_id,
              run.agent_type,
              run.session_key,
              run.worktree_path,
              run.status,
              run.started_at,
              run.completed_at,
              run.created_at,
              run.base_branch ?? null,
              run.tmux_session ?? null,
              run.progress
            );

          // Copy associated cost records.
          const globalCosts = globalDb
            .prepare("SELECT * FROM costs WHERE run_id = ?")
            .all(run.id) as Array<{
              id: string;
              run_id: string;
              tokens_in: number;
              tokens_out: number;
              cache_read: number;
              estimated_cost: number;
              recorded_at: string;
            }>;

          for (const cost of globalCosts) {
            localDb
              .prepare(
                `INSERT OR IGNORE INTO costs
                   (id, run_id, tokens_in, tokens_out, cache_read, estimated_cost, recorded_at)
                 VALUES (?, ?, ?, ?, ?, ?, ?)`
              )
              .run(
                cost.id,
                cost.run_id,
                cost.tokens_in,
                cost.tokens_out,
                cost.cache_read,
                cost.estimated_cost,
                cost.recorded_at
              );
          }

          // Copy associated event records.
          const globalEvents = globalDb
            .prepare("SELECT * FROM events WHERE run_id = ?")
            .all(run.id) as Array<{
              id: string;
              project_id: string;
              run_id: string | null;
              event_type: string;
              details: string | null;
              created_at: string;
            }>;

          for (const event of globalEvents) {
            localDb
              .prepare(
                `INSERT OR IGNORE INTO events
                   (id, project_id, run_id, event_type, details, created_at)
                 VALUES (?, ?, ?, ?, ?, ?)`
              )
              .run(
                event.id,
                effectiveProjectId,
                event.run_id,
                event.event_type,
                event.details,
                event.created_at
              );
          }

          migratedCount++;
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          errors.push(`run ${run.id} (project: ${projectName}): ${msg}`);
        } finally {
          localStore?.close();
        }
      }

      if (errors.length > 0) {
        return {
          name: checkName,
          status: "warn",
          message: `Migrated ${migratedCount}/${orphaned.length} run(s); ${errors.length} error(s): ${errors.slice(0, 3).join("; ")}`,
          fixApplied: migratedCount > 0 ? `Migrated ${migratedCount} run(s) from global store to project-local stores` : undefined,
        };
      }

      return {
        name: checkName,
        status: "fixed",
        message: `Migrated ${migratedCount} run(s) from legacy global store to project-local stores`,
        fixApplied: `Migrated ${migratedCount} run(s) from global store to project-local stores`,
      };
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      return { name: checkName, status: "warn", message: `Could not check global store: ${msg}` };
    } finally {
      globalStore?.close();
    }
  }

  async checkDataIntegrity(opts: { fix?: boolean; dryRun?: boolean; projectPath?: string } = {}): Promise<CheckResult[]> {
    const results: CheckResult[] = [];

    const [worktreeResults, zombieResults, staleResult, failedStuckResults, consistencyResults, blockedResult, recoveryResult, beadSyncResult] =
      await Promise.all([
        this.checkOrphanedWorktrees(opts),
        this.checkZombieRuns(opts),
        this.checkStalePendingRuns(opts),
        this.checkFailedStuckRuns(opts),
        this.checkRunStateConsistency(opts),
        this.checkBlockedSeeds(),
        this.checkBrRecoveryArtifacts(opts),
        this.checkBeadStatusSync(opts),
      ]);

    results.push(...worktreeResults, ...zombieResults, staleResult, ...failedStuckResults, ...consistencyResults, blockedResult, recoveryResult, beadSyncResult);

    // Merge queue checks (only when merge queue is configured)
    if (this.mergeQueue) {
      const mqResults = await this.checkMergeQueueHealth(opts);
      results.push(...mqResults);
    }

    return results;
  }

  async runAll(opts: { fix?: boolean; dryRun?: boolean; projectPath?: string } = {}): Promise<DoctorReport> {
    const [system, repository, dataIntegrity] = await Promise.all([
      this.checkSystem(),
      this.checkRepository(opts),
      this.checkDataIntegrity(opts),
    ]);

    const all = [...system, ...repository, ...dataIntegrity];
    const summary = {
      pass: all.filter((r) => r.status === "pass").length,
      warn: all.filter((r) => r.status === "warn").length,
      fail: all.filter((r) => r.status === "fail").length,
      fixed: all.filter((r) => r.status === "fixed").length,
      skip: all.filter((r) => r.status === "skip").length,
    };

    return { system, repository, dataIntegrity, summary };
  }
}
