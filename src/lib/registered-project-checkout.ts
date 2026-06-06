import { execFileSync } from "node:child_process";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { isIgnorableControllerPath } from "./controller-paths.js";

const GIT_COMMAND_TIMEOUT_MS = 30_000;

function gitExec(
  repoPath: string,
  args: string[],
  options: {
    encoding?: BufferEncoding;
    stdio?: "pipe" | "inherit" | "ignore" | [stdin: "ignore" | "pipe" | "inherit", stdout: "ignore" | "pipe" | "inherit", stderr: "ignore" | "pipe" | "inherit"];
    env?: NodeJS.ProcessEnv;
  } = {},
): string | Buffer {
  const { env, ...rest } = options;
  return execFileSync("git", args, {
    cwd: repoPath,
    timeout: GIT_COMMAND_TIMEOUT_MS,
    env: {
      ...process.env,
      ...env,
      GIT_TERMINAL_PROMPT: "0",
    },
    ...rest,
  });
}


export interface RegisteredProjectCheckoutSyncOptions {
  projectId?: string;
  projectPath: string;
  defaultBranch?: string | null;
  warn?: (message: string) => void;
}

function gitOutput(repoPath: string, args: string[]): string {
  return String(gitExec(repoPath, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  })).trim();
}

function gitLines(repoPath: string, args: string[]): string[] {
  const output = gitOutput(repoPath, args);
  return output === "" ? [] : output.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
}

function gitTry(repoPath: string, args: string[]): boolean {
  try {
    gitExec(repoPath, args, { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

function detectDefaultBranch(repoPath: string): string {
  try {
    const remoteHead = gitOutput(repoPath, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]);
    if (remoteHead.startsWith("origin/")) {
      return remoteHead.slice("origin/".length);
    }
  } catch {
    // Fall through to the current local branch.
  }

  try {
    return gitOutput(repoPath, ["symbolic-ref", "--quiet", "--short", "HEAD"]);
  } catch {
    return "main";
  }
}

function collectDirtyPaths(repoPath: string): { tracked: string[]; untracked: string[] } {
  const tracked = Array.from(new Set([
    ...gitLines(repoPath, ["diff", "--name-only"]),
    ...gitLines(repoPath, ["diff", "--cached", "--name-only"]),
  ]));
  const untracked = gitLines(repoPath, ["ls-files", "--others", "--exclude-standard"]);
  return { tracked, untracked };
}

export function syncRegisteredProjectCheckout(options: RegisteredProjectCheckoutSyncOptions): void {
  const warn = options.warn ?? ((message: string) => console.warn(message));
  const branch = options.defaultBranch?.trim() || detectDefaultBranch(options.projectPath);
  const projectLabel = options.projectId ?? options.projectPath;
  const remoteRef = `origin/${branch}`;

  try {
    gitExec(options.projectPath, ["fetch", "origin", branch, "--prune"], {
      stdio: "pipe",
    });
  } catch {
    try {
      gitExec(options.projectPath, ["fetch", "origin", "--prune"], {
        stdio: "pipe",
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      warn(`[Foreman] Registered checkout fetch failed for '${projectLabel}': ${msg}`);
      return;
    }
  }

  if (!gitTry(options.projectPath, ["rev-parse", "--verify", remoteRef])) {
    warn(`[Foreman] Registered checkout sync skipped for '${projectLabel}': missing ${remoteRef}`);
    return;
  }

  try {
    const { tracked, untracked } = collectDirtyPaths(options.projectPath);
    const ignorableTracked = tracked.filter(isIgnorableControllerPath);
    const ignorableUntracked = untracked.filter(isIgnorableControllerPath);
    const nonIgnorable = [...tracked, ...untracked].filter((path) => !isIgnorableControllerPath(path));

    if (nonIgnorable.length > 0) {
      warn(
        `[Foreman] Registered checkout sync skipped for '${projectLabel}' due to local changes: ` +
        nonIgnorable.slice(0, 8).join(", "),
      );
      return;
    }

    if (ignorableTracked.length > 0) {
      gitExec(options.projectPath, ["restore", "--source=HEAD", "--staged", "--worktree", "--", ...ignorableTracked], {
        stdio: "pipe",
      });
    }

    for (const path of ignorableUntracked) {
      rmSync(join(options.projectPath, path), { recursive: true, force: true });
    }

    let currentBranch: string | undefined;
    try {
      currentBranch = gitOutput(options.projectPath, ["symbolic-ref", "--quiet", "--short", "HEAD"]);
    } catch {
      currentBranch = undefined;
    }

    if (currentBranch !== branch) {
      if (!gitTry(options.projectPath, ["checkout", branch])) {
        gitExec(options.projectPath, ["checkout", "-B", branch, remoteRef], {
          stdio: "pipe",
        });
      }
    }

    gitExec(options.projectPath, ["reset", "--hard", remoteRef], {
      stdio: "pipe",
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    warn(`[Foreman] Registered checkout sync failed for '${projectLabel}': ${msg}`);
  }
}
