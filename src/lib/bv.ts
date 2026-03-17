import { execFile } from "node:child_process";
import { join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const HOME = process.env.HOME ?? "~";
const BV_PATH = join(HOME, ".local", "bin", "bv");
const BR_PATH = join(HOME, ".local", "bin", "br");

// TRD-NF-003: bv timeout at 3s for projects up to 500 issues
const DEFAULT_TIMEOUT_MS = 3_000;

// ── Interfaces ──────────────────────────────────────────────────────────────

export interface BvRecommendation {
  id: string;
  title: string;
  score: number;
  action?: string;
  reasons?: string[];
}

export interface BvTriageResult {
  recommendations: BvRecommendation[];
  quick_ref?: { actionable_count: number; top_picks: BvRecommendation[] };
}

export interface BvNextResult {
  id: string;
  title: string;
  score: number;
  claim_command?: string;
}

export interface BvClientOptions {
  /** Maximum milliseconds to wait for any bv invocation. Default: 10 000. */
  timeoutMs?: number;
}

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
  private readonly projectPath: string;
  private readonly timeoutMs: number;

  constructor(projectPath: string, opts?: BvClientOptions) {
    this.projectPath = projectPath;
    this.timeoutMs = opts?.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }

  /** Returns the single highest-priority actionable task. */
  async robotNext(): Promise<BvNextResult | null> {
    const raw = await this._execBv("next");
    if (raw === null) return null;
    try {
      const parsed = JSON.parse(raw) as BvNextResult;
      if (typeof parsed.id !== "string") return null;
      return parsed;
    } catch {
      return null;
    }
  }

  /** Returns full triage output with recommendations and quick_ref. */
  async robotTriage(): Promise<BvTriageResult | null> {
    const raw = await this._execBv("triage");
    if (raw === null) return null;
    try {
      const parsed = JSON.parse(raw) as BvTriageResult;
      if (!Array.isArray(parsed.recommendations)) return null;
      return parsed;
    } catch {
      return null;
    }
  }

  /** Returns parallel execution plan tracks. */
  async robotPlan(): Promise<unknown | null> {
    const raw = await this._execBv("plan");
    if (raw === null) return null;
    try {
      return JSON.parse(raw) as unknown;
    } catch {
      return null;
    }
  }

  /** Returns full graph metrics (PageRank, betweenness, HITS, etc.). */
  async robotInsights(): Promise<unknown | null> {
    const raw = await this._execBv("insights");
    if (raw === null) return null;
    try {
      return JSON.parse(raw) as unknown;
    } catch {
      return null;
    }
  }

  /** Returns stale issues, blocking cascades, and priority mismatches. */
  async robotAlerts(): Promise<unknown | null> {
    const raw = await this._execBv("alerts");
    if (raw === null) return null;
    try {
      return JSON.parse(raw) as unknown;
    } catch {
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
  private async _execBv(
    robotFlag: string,
    extraArgs?: string[],
  ): Promise<string | null> {
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
    } catch {
      return null;
    }
  }

  /** Runs `br sync --flush-only` silently; failure is ignored. */
  private async _runBrSync(): Promise<void> {
    try {
      await execFileAsync(BR_PATH, ["sync", "--flush-only"], {
        cwd: this.projectPath,
        timeout: this.timeoutMs,
        maxBuffer: 1024 * 1024,
      });
    } catch {
      // Ignore — bv may still work even if sync fails
    }
  }
}
