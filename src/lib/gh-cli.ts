/**
 * GhCli — thin wrapper around GitHub CLI (`gh`) commands.
 *
 * All GitHub operations go through this class. Uses `gh` exclusively for auth,
 * cloning, and API calls. `gh` manages credentials via OS keychain — Foreman
 * never handles tokens directly.
 *
 * Design decisions:
 * - `gh` path is configurable (default: `gh` from PATH) for testing.
 * - `authStatus()` returns boolean — does not throw on unauthenticated state.
 * - `repoClone()` throws descriptive errors — callers handle auth failures.
 * - `api()` wraps `gh api` with full response/error passthrough.
 *
 * @module gh-cli
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

export interface GhCliOptions {
  /** Path to `gh` binary. Defaults to `gh` from PATH. */
  ghPath?: string;
}

export interface GhApiOptions {
  method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
  body?: string;
  jq?: string;
  silent?: boolean;
}

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

/** Base error for all GhCli failures. */
export class GhError extends Error {
  override readonly name = "GhError" as string;
}

/** Thrown when `gh` is not installed or not on PATH. */
export class GhNotInstalledError extends GhError {
  override readonly name = "GhNotInstalledError" as string;

  constructor() {
    super(
      "GitHub CLI (gh) is required but not installed. Install it from https://cli.github.com"
    );
  }
}

/**
 * Thrown when `gh` auth fails — e.g. no credentials stored, or token revoked.
 * Subclass of GhCloneError so callers that catch clone errors also catch auth.
 */
export class GhNotAuthenticatedError extends GhError {
  override readonly name = "GhNotAuthenticatedError" as string;
  readonly exitCode: number;

  constructor(stderr: string, exitCode: number) {
    super(`GitHub authentication required: ${stderr.trim() || "Not authenticated"}`);
    this.exitCode = exitCode;
  }
}

/** Thrown when `gh repo clone` fails for any reason (including auth). */
export class GhCloneError extends GhError {
  override readonly name = "GhCloneError" as string;
  readonly exitCode: number;

  constructor(message: string, stderr: string, exitCode: number) {
    super(message);
    this.exitCode = exitCode;
    // Attach stderr for debugging without cluttering the message
    if (stderr.trim()) {
      (this as unknown as { stderr: string }).stderr = stderr.trim();
    }
  }
}

/** Thrown when `gh api` returns a non-success status. */
export class GhApiError extends GhError {
  override readonly name = "GhApiError" as string;
  readonly exitCode: number;
  readonly status?: number;
  readonly stderr: string;

  constructor(
    message: string,
    stderr: string,
    exitCode: number,
    status?: number
  ) {
    super(message);
    this.exitCode = exitCode;
    this.stderr = stderr.trim();
    this.status = status;
  }
}

// ---------------------------------------------------------------------------
// GhCli
// ---------------------------------------------------------------------------

export class GhCli {
  private readonly ghPath: string;

  constructor(options: GhCliOptions = {}) {
    this.ghPath = options.ghPath ?? "gh";
  }

  /**
   * Run a `gh` command and return the result.
   * Does NOT throw on non-zero exit — caller decides what to do with the exit code.
   */
  private async execGh(
    args: string[],
    options: { timeout?: number; cwd?: string } = {}
  ): Promise<{ stdout: string; stderr: string; exitCode: number }> {
    try {
      const { stdout, stderr } = await execFileAsync(this.ghPath, args, {
        timeout: options.timeout ?? 60_000,
        cwd: options.cwd,
        encoding: "utf8",
        maxBuffer: 50 * 1024 * 1024, // 50 MB — large enough for `gh api` responses
      });
      return { stdout: stdout.trimEnd(), stderr: stderr.trimEnd(), exitCode: 0 };
    } catch (err: unknown) {
      const execError = err as {
        code?: number;
        killed?: boolean;
        stderr?: string;
        stdout?: string;
      };
      if (execError.code === 127 || execError.code === undefined) {
        throw new GhNotInstalledError();
      }
      return {
        stdout: (execError.stdout ?? "").trimEnd(),
        stderr: (execError.stderr ?? "").trimEnd(),
        exitCode: execError.code ?? 1,
      };
    }
  }

  /**
   * Check whether `gh` is authenticated.
   *
   * Runs `gh auth status --json`. Returns `true` only if authenticated
   * and exit code is 0. Returns `false` in all other cases (not logged in,
   * token expired, network error, gh not installed).
   */
  async authStatus(): Promise<boolean> {
    const result = await this.execGh(["auth", "status", "--json"], {
      timeout: 10_000,
    });
    if (result.exitCode !== 0) {
      return false;
    }
    // gh auth status --json outputs a JSON array even when not authenticated
    // but the structure differs; check for auth token presence
    try {
      const parsed = JSON.parse(result.stdout);
      // If authenticated, gh returns an array with at least one entry
      return Array.isArray(parsed) && parsed.length > 0;
    } catch {
      return false;
    }
  }

  /**
   * Verify GitHub CLI is available and authenticated.
   *
   * Calls `gh auth status` and throws `GhNotInstalledError` if gh is not
   * installed, or `GhNotAuthenticatedError` if not logged in.
   * Use this at the entry point of any command that requires GitHub access.
   *
   * @throws GhNotInstalledError if gh binary is not found
   * @throws GhNotAuthenticatedError if gh is not logged in
   */
  async checkAuth(): Promise<void> {
    const installed = await this.isInstalled();
    if (!installed) {
      throw new GhNotInstalledError();
    }
    const authenticated = await this.authStatus();
    if (!authenticated) {
      throw new GhNotAuthenticatedError(
        "Run 'gh auth login' to authenticate with GitHub.",
        1
      );
    }
  }

  /**
   * Check whether `gh` is installed and can be invoked.
   * Unlike `authStatus()`, this does not require authentication — it only
   * checks that the `gh` binary is on PATH.
   */
  async isInstalled(): Promise<boolean> {
    try {
      const result = await this.execGh(["--version"], { timeout: 5_000 });
      return result.exitCode === 0;
    } catch {
      return false;
    }
  }

  /**
   * Clone a GitHub repository using `gh repo clone`.
   *
   * @param url  - Full repo URL (e.g. `https://github.com/owner/repo` or `owner/repo`)
   * @param targetPath - Absolute directory path to clone into
   * @throws GhNotAuthenticatedError on auth failure
   * @throws GhCloneError on any other clone failure
   */
  async repoClone(url: string, targetPath: string): Promise<void> {
    const result = await this.execGh(
      ["repo", "clone", url, targetPath, "--", "--depth=1"],
      { timeout: 300_000 } // 5 min — large repos can be slow
    );

    if (result.exitCode === 0) return;

    const stderr = result.stderr;

    // gh returns exit code 1 for most failures including auth
    // Exit code 4 = template not found (unlikely for clone)
    // Check stderr for auth-related messages
    const authIndicators = [
      "authentication",
      "not authenticated",
      "auth",
      "login",
      "credentials",
      "token",
      "gh auth login",
    ];
    const isAuthFailure = authIndicators.some((indicator) =>
      stderr.toLowerCase().includes(indicator)
    );

    if (isAuthFailure) {
      throw new GhNotAuthenticatedError(stderr, result.exitCode);
    }

    throw new GhCloneError(
      `Failed to clone repository '${url}' to '${targetPath}': ${stderr || "Unknown error"}`,
      stderr,
      result.exitCode
    );
  }

  /**
   * Call the GitHub API via `gh api`.
   *
   * @param endpoint - API endpoint path (e.g. `/repos/owner/repo`)
   * @param options - HTTP method, request body, jq filter, silent flag
   * @returns Parsed JSON response
   * @throws GhApiError on non-success status
   */
  async api<T = unknown>(
    endpoint: string,
    options: GhApiOptions = {}
  ): Promise<T> {
    const args = ["api", endpoint];

    if (options.method && options.method !== "GET") {
      args.push("--method", options.method);
    }
    if (options.body !== undefined) {
      args.push("--input", "-");
    }
    if (options.jq) {
      args.push("--jq", options.jq);
    }
    if (options.silent) {
      args.push("--silent");
    }

    // gh api --paginate auto-fetches all pages; not enabled by default to keep
    // behavior predictable. Callers that need pagination can call repeatedly or
    // use --paginate.
    // args.push("--paginate"); // disabled by default

    const result = await this.execGh(args, {
      timeout: 30_000,
    });

    if (result.exitCode !== 0) {
      // Parse gh error output for status code
      // gh outputs errors like: HTTP 404: Not Found (https://api.github.com/repos/...)
      const statusMatch = result.stderr.match(/HTTP (\d{3})/);
      const status = statusMatch ? parseInt(statusMatch[1], 10) : undefined;

      throw new GhApiError(
        `GitHub API error for '${endpoint}': ${result.stderr || `Exit code ${result.exitCode}`}`,
        result.stderr,
        result.exitCode,
        status
      );
    }

    // Empty response (e.g. 204 No Content)
    if (!result.stdout) {
      return undefined as T;
    }

    try {
      return JSON.parse(result.stdout) as T;
    } catch {
      // gh api --jq can return non-JSON; return as string
      return result.stdout as unknown as T;
    }
  }

  // ---------------------------------------------------------------------------
  // Repository metadata helpers (built on top of api())
  // ---------------------------------------------------------------------------

  /**
   * Fetch repository metadata from the GitHub API.
   */
  async getRepoMetadata(owner: string, repo: string): Promise<{
    defaultBranch: string;
    visibility: "public" | "private" | "internal";
    fullName: string;
  }> {
    const data = await this.api<{
      default_branch: string;
      visibility: string;
      full_name: string;
    }>(`/repos/${owner}/${repo}`);

    return {
      defaultBranch: data.default_branch,
      visibility:
        data.visibility === "public" ||
        data.visibility === "private" ||
        data.visibility === "internal"
          ? (data.visibility as "public" | "private" | "internal")
          : "private",
      fullName: data.full_name,
    };
  }
}
