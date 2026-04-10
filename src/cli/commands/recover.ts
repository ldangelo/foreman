/**
 * `foreman recover <bead-id>` — Autonomous recovery agent for pipeline failures.
 *
 * Gathers all artifacts for a bead's pipeline execution (logs, mail messages,
 * reports, run progress, test output, blocked beads, git log) and invokes an
 * Opus agent to diagnose and autonomously fix common failure modes:
 *
 *   test-failed   — post-merge npm test failures (stale cache, bad expectations, bugs)
 *   stuck         — agent pipeline that stopped responding
 *   stale-blocked — beads blocked by already-closed dependencies
 *
 * Unlike `foreman debug`, this command is NOT read-only — the agent has write
 * access and will make fixes, commit, and push when appropriate.
 */

import { Command } from "commander";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import chalk from "chalk";
import { ForemanStore } from "../../lib/store.js";
import type { Run, Message, RunProgress } from "../../lib/store.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { runWithPiSdk } from "../../orchestrator/pi-sdk-runner.js";
import { loadAndInterpolate } from "../../orchestrator/template-loader.js";
import { getHighspeedModel } from "../../lib/config.js";
import { getForemanBranchName } from "../../lib/branch-names.js";

// ── Types ────────────────────────────────────────────────────────────────────

type RecoveryReason = "test-failed" | "stuck" | "stale-blocked";

export interface RecoverOpts {
  reason?: string;
  runId?: string;
  output?: string;
  model?: string;
  raw?: boolean;
}

interface RecoverStore {
  getRunsForSeed(seedId: string, projectId?: string): Run[];
  getRunProgress(runId: string): RunProgress | null;
  getAllMessages(runId: string): Message[];
  close(): void;
}

interface CommandCapture {
  output: string;
  ok: boolean;
  status: number | null;
  error?: string;
}

export interface RecoverActionDeps {
  createVcs?: typeof VcsBackendFactory.create;
  createStore?: (projectPath: string) => RecoverStore;
  runCommand?: (args: string[], cwd: string) => CommandCapture;
  runRecoveryAgent?: typeof runWithPiSdk;
  loadPrompt?: typeof loadAndInterpolate;
  getModel?: typeof getHighspeedModel;
  getBranchName?: typeof getForemanBranchName;
}

interface RecoveryArtifacts {
  runSummary: string;
  messagesText: string;
  reports: Record<string, string>;
  logContent: string | null;
  testOutput: string;
  blockedBeads: string;
  recentGitLog: string;
  warnings: string[];
}

// ── Artifact collection ─────────────────────────────────────────────────────

const REPORT_FILES = [
  "EXPLORER_REPORT.md",
  "DEVELOPER_REPORT.md",
  "QA_REPORT.md",
  "REVIEW.md",
  "FINALIZE_REPORT.md",
  "SESSION_LOG.md",
  "TASK.md",
  "BLOCKED.md",
  "RUN_LOG.md",
];

function readFileOrNull(path: string): string | null {
  try { return readFileSync(path, "utf-8"); } catch { return null; }
}

function findLogFile(runId: string): string | null {
  const logsDir = join(process.env.HOME ?? "~", ".foreman", "logs");
  if (!existsSync(logsDir)) return null;
  const logPath = join(logsDir, `${runId}.log`);
  if (existsSync(logPath)) return readFileOrNull(logPath);
  const errPath = join(logsDir, `${runId}.err`);
  if (existsSync(errPath)) return readFileOrNull(errPath);
  return null;
}

function formatMessages(messages: Message[]): string {
  if (messages.length === 0) return "(no messages)";
  return messages.map((m) => {
    const ts = m.created_at;
    return `[${ts}] ${m.sender_agent_type} → ${m.recipient_agent_type} | ${m.subject}\n  ${m.body.slice(0, 500)}`;
  }).join("\n\n");
}

function formatRunSummary(run: Run, progress: Record<string, unknown> | null): string {
  const lines = [
    `Run ID: ${run.id}`,
    `Seed: ${run.seed_id}`,
    `Status: ${run.status}`,
    `Agent Type: ${run.agent_type}`,
    `Started: ${run.started_at ?? "unknown"}`,
    `Completed: ${run.completed_at ?? "still running"}`,
    `Worktree: ${run.worktree_path ?? "unknown"}`,
  ];
  if (progress) {
    lines.push(`Progress: ${JSON.stringify(progress, null, 2)}`);
  }
  return lines.join("\n");
}

function runCommandCapture(args: string[], cwd: string): CommandCapture {
  const result = spawnSync(args[0], args.slice(1), {
    encoding: "utf-8",
    cwd,
    timeout: 60_000,
  });

  const output = [result.stdout, result.stderr]
    .filter((part): part is string => typeof part === "string" && part.length > 0)
    .join("\n")
    .trim();

  if (result.error) {
    return {
      output: output || `(command failed: ${result.error.message})`,
      ok: false,
      status: result.status ?? null,
      error: result.error.message,
    };
  }

  return {
    output: output || (result.status === 0 ? "" : "(no output)"),
    ok: result.status === 0,
    status: result.status ?? null,
    error: result.status === 0 ? undefined : `exit ${result.status ?? "unknown"}`,
  };
}

// ── Prompt builder ──────────────────────────────────────────────────────────

function buildRecoveryPrompt(
  opts: {
    beadId: string;
    reason: RecoveryReason;
    branchName: string;
    runId: string;
    projectRoot: string;
    runSummary: string;
    testOutput: string;
    blockedBeads: string;
    recentGitLog: string;
    reports: Record<string, string>;
    logContent: string | null;
  },
  loadPrompt: typeof loadAndInterpolate,
): string {
  const reportSections = Object.entries(opts.reports)
    .map(([name, content]) => `### ${name}\n\`\`\`\n${content.slice(0, 5000)}\n\`\`\``)
    .join("\n\n");

  const logSection = opts.logContent
    ? `## Agent Worker Log (last 200 lines)\n\`\`\`\n${opts.logContent.split("\n").slice(-200).join("\n")}\n\`\`\``
    : "## Agent Worker Log\n(not found)";

  return loadPrompt("recover.md", {
    beadId: opts.beadId,
    reason: opts.reason,
    branchName: opts.branchName,
    runId: opts.runId,
    projectRoot: opts.projectRoot,
    runSummary: opts.runSummary,
    testOutput: opts.testOutput || "(not captured)",
    blockedBeads: opts.blockedBeads || "(none)",
    recentGitLog: opts.recentGitLog || "(not available)",
    reportSections: reportSections
      ? `## Pipeline Reports\n${reportSections}`
      : "## Pipeline Reports\n(none found)",
    logSection,
  });
}

function emitArtifactSummary(artifacts: RecoveryArtifacts): void {
  console.error(chalk.dim(`  Messages:    ${artifacts.messagesText === "(no messages)" ? 0 : "see raw/prompt"}`));
  console.error(chalk.dim(`  Reports:     ${Object.keys(artifacts.reports).join(", ") || "(none)"}`));
  console.error(chalk.dim(`  Log:         ${artifacts.logContent ? "found" : "not found"}`));
  console.error(chalk.dim(`  Test output: ${artifacts.testOutput ? `${artifacts.testOutput.split("\n").length} lines` : "(none)"}`));
  console.error(chalk.dim(`  Blocked:     ${artifacts.blockedBeads ? artifacts.blockedBeads.split("\n").filter(Boolean).length : 0} beads`));
  console.error();
}

function emitCollectionWarnings(warnings: string[]): void {
  if (warnings.length === 0) {
    return;
  }

  console.warn(chalk.yellow("Recovery context is degraded:"));
  for (const warning of warnings) {
    console.warn(chalk.yellow(`  - ${warning}`));
  }
  console.warn();
}

function emitRawArtifacts(artifacts: RecoveryArtifacts): void {
  console.log(chalk.bold("─── Run Summary ───"));
  console.log(artifacts.runSummary);
  console.log(chalk.bold("\n─── Messages ───"));
  console.log(artifacts.messagesText);
  for (const [name, content] of Object.entries(artifacts.reports)) {
    console.log(chalk.bold(`\n─── ${name} ───`));
    console.log(content.slice(0, 3000));
  }
  if (artifacts.logContent) {
    console.log(chalk.bold("\n─── Log (last 100 lines) ───"));
    console.log(artifacts.logContent.split("\n").slice(-100).join("\n"));
  }
  if (artifacts.testOutput) {
    console.log(chalk.bold("\n─── Test Output (last 100 lines) ───"));
    console.log(artifacts.testOutput.split("\n").slice(-100).join("\n"));
  }
  console.log(chalk.bold("\n─── Blocked Beads ───"));
  console.log(artifacts.blockedBeads || "(none)");
  console.log(chalk.bold("\n─── Recent Git Log ───"));
  console.log(artifacts.recentGitLog || "(none)");
}

function collectArtifacts(
  run: Run,
  beadId: string,
  reason: RecoveryReason,
  opts: RecoverOpts,
  projectPath: string,
  store: RecoverStore,
  runCommand: (args: string[], cwd: string) => CommandCapture,
): RecoveryArtifacts {
  const warnings: string[] = [];

  const progress = store.getRunProgress(run.id);
  const runSummary = formatRunSummary(run, progress as Record<string, unknown> | null);
  const allMessages = store.getAllMessages(run.id);
  const messagesText = formatMessages(allMessages);

  const reports: Record<string, string> = {};
  const worktreePath = run.worktree_path;
  if (!worktreePath) {
    warnings.push("Run has no worktree path; pipeline reports could not be collected.");
  } else if (!existsSync(worktreePath)) {
    warnings.push(`Worktree path does not exist: ${worktreePath}`);
  } else {
    for (const file of REPORT_FILES) {
      const content = readFileOrNull(join(worktreePath, file));
      if (content) {
        reports[file] = content;
      }
    }
  }

  const beadInfo = runCommand(["br", "show", beadId], projectPath);
  if (beadInfo.ok && beadInfo.output) {
    reports.BEAD_INFO = beadInfo.output;
  } else {
    warnings.push(`Bead metadata could not be collected via 'br show': ${beadInfo.error ?? beadInfo.output ?? "unknown error"}`);
  }

  const logContent = findLogFile(run.id);
  if (!logContent) {
    warnings.push(`Worker log was not found for run ${run.id}.`);
  }

  let testOutput = opts.output ?? "";
  if (!testOutput && !opts.raw && reason === "test-failed") {
    console.error(chalk.dim("  Running npm test to capture fresh output..."));
    const testRun = runCommand(["npm", "test"], projectPath);
    testOutput = testRun.output;
    if (!testRun.output) {
      warnings.push(`Fresh npm test output was not captured: ${testRun.error ?? "no output"}`);
    }
  }

  if (!testOutput && reason === "test-failed" && !opts.raw) {
    warnings.push("No test failure output was available for a test-failed recovery.");
  }

  const blockedBeadsResult = runCommand(
    ["br", "list", "--status=blocked", "--limit", "0"],
    projectPath,
  );
  const blockedBeads = blockedBeadsResult.output;
  if (!blockedBeadsResult.ok) {
    warnings.push(`Blocked bead listing failed: ${blockedBeadsResult.error ?? blockedBeadsResult.output ?? "unknown error"}`);
  }

  const devLog = runCommand(["git", "log", "--oneline", "-20", "dev"], projectPath);
  const mainLog = devLog.ok ? null : runCommand(["git", "log", "--oneline", "-20", "main"], projectPath);
  const recentGitLog = (devLog.ok ? devLog.output : mainLog?.output ?? "").trim();
  if (!recentGitLog) {
    const sourceError = mainLog?.error ?? devLog.error ?? mainLog?.output ?? devLog.output ?? "unknown error";
    warnings.push(`Recent git history could not be collected: ${sourceError}`);
  }

  return {
    runSummary,
    messagesText,
    reports,
    logContent,
    testOutput,
    blockedBeads,
    recentGitLog,
    warnings,
  };
}

// ── Core action (exported for testing) ─────────────────────────────────────

export async function recoverAction(
  beadId: string,
  opts: RecoverOpts,
  deps: RecoverActionDeps = {},
): Promise<number> {
  const reason = (opts.reason ?? "test-failed") as RecoveryReason;
  const validReasons: RecoveryReason[] = ["test-failed", "stuck", "stale-blocked"];
  if (!validReasons.includes(reason)) {
    console.error(chalk.red(`Invalid reason "${reason}". Must be one of: ${validReasons.join(", ")}`));
    return 1;
  }

  const createVcs = deps.createVcs ?? VcsBackendFactory.create;
  const createStore = deps.createStore ?? ((projectPath: string) => ForemanStore.forProject(projectPath));
  const runCommand = deps.runCommand ?? runCommandCapture;
  const runRecoveryAgent = deps.runRecoveryAgent ?? runWithPiSdk;
  const loadPrompt = deps.loadPrompt ?? loadAndInterpolate;
  const getModel = deps.getModel ?? getHighspeedModel;
  const getBranchName = deps.getBranchName ?? getForemanBranchName;

  const vcs = await createVcs({ backend: "auto" }, process.cwd());
  const projectPath = await vcs.getRepoRoot(process.cwd());
  const store = createStore(projectPath);

  try {
    const runs = store.getRunsForSeed(beadId);
    if (runs.length === 0) {
      console.error(chalk.red(`No runs found for seed ${beadId}`));
      return 1;
    }

    const run = opts.runId
      ? runs.find((candidate) => candidate.id === opts.runId || candidate.id.startsWith(opts.runId ?? ""))
      : runs[0];

    if (!run) {
      console.error(chalk.red(`Run ${opts.runId} not found for seed ${beadId}`));
      console.error(`Available runs: ${runs.map((candidate) => `${candidate.id.slice(0, 8)} (${candidate.status})`).join(", ")}`);
      return 1;
    }

    console.error(chalk.bold(`\nRecovery: ${beadId} — reason: ${reason} — run ${run.id.slice(0, 8)} (${run.status})\n`));

    const artifacts = collectArtifacts(run, beadId, reason, opts, projectPath, store, runCommand);
    emitArtifactSummary(artifacts);
    emitCollectionWarnings(artifacts.warnings);

    if (opts.raw) {
      emitRawArtifacts(artifacts);
      if (artifacts.warnings.length > 0) {
        console.error(chalk.yellow("Raw recovery context emitted with gaps; recovery agent was not invoked."));
        return 1;
      }
      console.error(chalk.yellow("Raw recovery context emitted; recovery agent was not invoked."));
      return 0;
    }

    const prompt = buildRecoveryPrompt({
      beadId,
      reason,
      branchName: getBranchName(beadId),
      runId: run.id,
      projectRoot: projectPath,
      runSummary: artifacts.runSummary,
      testOutput: artifacts.testOutput,
      blockedBeads: artifacts.blockedBeads,
      recentGitLog: artifacts.recentGitLog,
      reports: artifacts.reports,
      logContent: artifacts.logContent,
    }, loadPrompt);

    const model = opts.model ?? getModel();
    if (artifacts.warnings.length > 0) {
      console.error(chalk.yellow(`Invoking ${model} with degraded recovery context...\n`));
    } else {
      console.error(chalk.yellow(`Sending to ${model} for autonomous recovery...\n`));
    }

    const result = await runRecoveryAgent({
      prompt,
      systemPrompt: [
        "You are an autonomous recovery agent for Foreman, an AI pipeline orchestrator.",
        "You have full write access and should diagnose and fix the reported failure.",
        "Make code fixes, run tests, commit, and push when appropriate.",
        "Be decisive — when you identify a fix, apply it. Do not just describe what to do.",
        "Use markdown formatting for your final summary.",
      ].join(" "),
      cwd: projectPath,
      model,
      allowedTools: ["Read", "Write", "Edit", "Bash", "Grep", "Find", "LS"],
      onText: (text) => process.stdout.write(text),
    });

    if (!result.success) {
      console.error(chalk.red(`\nRecovery agent failed: ${result.errorMessage}`));
      return 1;
    }

    if (result.outputText && !result.outputText.includes("\n")) {
      console.log(result.outputText);
    }

    if (artifacts.warnings.length > 0) {
      console.error(chalk.yellow(`\nRecovery agent completed, but context collection was degraded ($${result.costUsd.toFixed(4)})\n`));
      return 1;
    }

    console.error(chalk.green(`\nRecovery complete ($${result.costUsd.toFixed(4)})\n`));
    return 0;
  } finally {
    store.close();
  }
}

// ── Command ─────────────────────────────────────────────────────────────────

export const recoverCommand = new Command("recover")
  .description("Autonomous recovery agent for pipeline failures")
  .argument("<bead-id>", "The bead/seed ID that needs recovery")
  .option(
    "--reason <reason>",
    "Failure reason: test-failed | stuck | stale-blocked",
    "test-failed",
  )
  .option("--run-id <id>", "Specific run ID (default: latest run for this seed)")
  .option("--output <text>", "Pre-captured test output to include in context")
  .option("--model <model>", "Model to use for recovery")
  .option("--raw", "Print collected context without invoking AI")
  .action(async (beadId: string, opts: RecoverOpts) => {
    const exitCode = await recoverAction(beadId, opts);
    if (exitCode !== 0) {
      process.exit(exitCode);
    }
  });
