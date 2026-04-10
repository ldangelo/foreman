import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { randomUUID } from "node:crypto";
import type { ForemanStore } from "../lib/store.js";
import type { BeadsRustClient } from "../lib/beads-rust.js";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";
import { GitBackend } from "../lib/vcs/git-backend.js";

const execFileAsync = promisify(execFile);

export interface IntegrationValidationOptions {
  branch: string;
  testCommand: string;
  intervalMinutes: number;
  failureThreshold: number;
  dryRun?: boolean;
}

export interface IntegrationValidationResult {
  id: string;
  status: "passed" | "failed" | "error";
  commitHash: string | null;
  output: string;
  durationMs: number;
}

export class IntegrationValidator {
  private running = false;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private consecutiveFailures = 0;

  constructor(
    private readonly store: ForemanStore,
    private readonly seeds: BeadsRustClient,
    private readonly projectId: string,
    private readonly projectPath: string,
  ) {}

  async runOnce(opts: IntegrationValidationOptions): Promise<IntegrationValidationResult> {
    const runId = randomUUID();
    const startedAt = new Date().toISOString();
    const startMs = Date.now();

    this.store.logEvent(this.projectId, "integration-validation-start", {
      runId,
      branch: opts.branch,
      testCommand: opts.testCommand,
    });

    this.store.recordSentinelRun({
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

    let commitHash: string | null = null;
    let output = "";
    let status: "passed" | "failed" | "error" = "error";

    try {
      if (!opts.dryRun) {
        commitHash = await this.resolveCommit(opts.branch);
        const testResult = await this.runTestCommand(opts.testCommand);
        output = testResult.output;
        status = testResult.status;
      } else {
        output = `[dry-run] Would validate integration branch ${opts.branch} with: ${opts.testCommand}`;
        status = "passed";
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      output = `Unexpected integration validation error: ${msg}`;
      status = "error";
    }

    const durationMs = Date.now() - startMs;
    const completedAt = new Date().toISOString();

    this.store.updateSentinelRun(runId, {
      status,
      output: output.slice(0, 50_000),
      completed_at: completedAt,
      failure_count: this.consecutiveFailures,
    });

    this.store.logEvent(
      this.projectId,
      status === "passed" ? "integration-validation-pass" : "integration-validation-fail",
      { runId, branch: opts.branch, commitHash, durationMs, status },
    );

    if (status === "failed" || status === "error") {
      this.consecutiveFailures++;
      if (this.consecutiveFailures >= opts.failureThreshold && !opts.dryRun) {
        await this.createBugTask(opts.branch, commitHash, output);
        this.consecutiveFailures = 0;
      }
    } else {
      this.consecutiveFailures = 0;
    }

    return { id: runId, status, commitHash, output, durationMs };
  }

  start(
    opts: IntegrationValidationOptions,
    onResult?: (result: IntegrationValidationResult) => void,
  ): void {
    if (this.running) {
      throw new Error("Integration validator is already running");
    }
    this.running = true;
    this.consecutiveFailures = 0;

    const intervalMs = opts.intervalMinutes * 60 * 1000;
    let activeRun = false;

    const loop = async (): Promise<void> => {
      if (!this.running) return;

      if (activeRun) {
        this.timer = setTimeout(() => void loop(), intervalMs);
        return;
      }

      activeRun = true;
      try {
        const result = await this.runOnce(opts);
        onResult?.(result);
      } catch (err) {
        console.error("[integration-validator] Unexpected error in loop:", err);
      } finally {
        activeRun = false;
      }

      if (this.running) {
        this.timer = setTimeout(() => void loop(), intervalMs);
      }
    };

    void loop();
  }

  stop(): void {
    this.running = false;
    if (this.timer !== null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }

  isRunning(): boolean {
    return this.running;
  }

  private async resolveCommit(branch: string): Promise<string | null> {
    const backend = new GitBackend(this.projectPath);
    for (const ref of [`origin/${branch}`, branch]) {
      try {
        return await backend.resolveRef(this.projectPath, ref);
      } catch {
        // Try next ref
      }
    }
    return null;
  }

  private async runTestCommand(
    testCommand: string,
  ): Promise<{ status: "passed" | "failed" | "error"; output: string }> {
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
    } catch (err: unknown) {
      const e = err as { stdout?: string; stderr?: string; killed?: boolean };
      const output = [e.stdout ?? "", e.stderr ? `STDERR:\n${e.stderr}` : ""]
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

  private async createBugTask(
    branch: string,
    commitHash: string | null,
    output: string,
  ): Promise<void> {
    const shortHash = commitHash ? commitHash.slice(0, 8) : "unknown";
    const title = `[Integration Validator] Failures on ${branch} @ ${shortHash}`;
    const description =
      `Automated integration validation detected ${this.consecutiveFailures} consecutive failure(s) ` +
      `on integration branch \`${branch}\`.\n\n` +
      `**Commit:** ${commitHash ?? "unknown"}\n\n` +
      `**Test output (truncated):**\n\`\`\`\n${output.slice(0, 2_000)}\n\`\`\``;

    try {
      const existingBeads = await this.seeds.list({
        status: "open",
        label: "kind:integration-validator",
      });
      const duplicate = existingBeads.find((b) => b.title === title);
      if (duplicate) {
        console.log(
          `[integration-validator] Skipping duplicate bead creation — open bead ${duplicate.id} already exists for "${title}"`,
        );
        return;
      }

      await this.seeds.create(title, {
        type: "bug",
        priority: "P0",
        description,
        labels: ["kind:integration-validator"],
      });
    } catch (err) {
      console.error("[integration-validator] Failed to create bug task:", err);
    }
  }
}
