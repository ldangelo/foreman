import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFileSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { WorkerConfig } from "../agent-worker.js";
import type { PhaseResult } from "../pipeline-executor.js";
import type { RunProgress } from "../../lib/store.js";
import { ForemanStore } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import { resolveProjectDatabaseUrl } from "../../lib/project-mail-client.js";
import type { AgentMailClient } from "../../lib/agent-mail-client.js";
import type { WorkflowConfig, WorkflowPhaseConfig } from "../../lib/workflow-loader.js";
import { getRunReportsDir, resolveArtifactPath } from "../../lib/report-paths.js";
import { isGhAuthFailure, Refinery } from "../refinery.js";
import type { ITaskClient } from "../../lib/task-client.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import type { VcsBackend } from "../../lib/vcs/interface.js";
import { PIPELINE_TIMEOUTS } from "../../lib/config.js";
import { runCodeRabbitCliReview } from "../coderabbit-cli-review.js";
import { collectPrReviewContext, collectPrWaitSnapshot, summarizePrWaitStatus, updatePrReadyStability, writePrReviewFindings, writePrWaitReport } from "../pr-review-context.js";
import { autoMerge } from "../auto-merge.js";
import { enqueueToMergeQueue } from "../agent-worker-enqueue.js";
import { updateTerminalRunStatus } from "../agent-worker-run-status.js";

const execFileAsync = promisify(execFile);

type AnyMailClient = AgentMailClient;

function sendMail(client: AnyMailClient | null, to: string, subject: string, body: Record<string, unknown>): void {
  if (!client) return;
  client.sendMessage(to, subject, JSON.stringify(body)).catch(() => undefined);
}

/**
 * Derive fallback refinery options for registered/native run lookups.
 *
 * If registeredProjectId is missing but a database URL exists in the project path,
 * derive a PostgresStore for run lookups. This ensures registered/native runs can
 * be found even when registeredProjectId was not propagated.
 *
 * Error handling: Safely handles the case where the connection pool may not be
 * properly initialized by wrapping PostgresStore.forProject in a try-catch that
 * logs the error and returns undefined instead of throwing.
 */
export function deriveFallbackRefineryOptions(
  registeredProjectId: string | undefined,
  registeredReadStore: PostgresStore | undefined,
  pipelineProjectPath: string,
  configProjectId: string,
  log?: (msg: string) => void,
): { registeredProjectId: string; runLookup: PostgresStore } | undefined {
  const fallbackRegisteredProjectId = !registeredProjectId && resolveProjectDatabaseUrl(pipelineProjectPath)
    ? configProjectId
    : undefined;
  const refineryProjectId = registeredProjectId ?? fallbackRegisteredProjectId;

  if (!refineryProjectId) {
    return undefined;
  }

  let fallbackReadStore: PostgresStore | undefined;
  const projectIdForFallback = fallbackRegisteredProjectId ?? registeredProjectId;
  if (!registeredReadStore && projectIdForFallback) {
    try {
      fallbackReadStore = PostgresStore.forProject(projectIdForFallback);
    } catch (err) {
      log?.(`[deriveFallbackRefineryOptions] Failed to create PostgresStore for fallback: ${err instanceof Error ? err.message : String(err)}`);
      return undefined;
    }
  }

  const runLookup = registeredReadStore ?? fallbackReadStore;
  if (!runLookup) {
    return undefined;
  }

  return {
    registeredProjectId: refineryProjectId,
    runLookup,
  };
}

/**
 * Run the full pipeline: Explorer → Developer ⇄ QA → Reviewer → Finalize.
 * Each phase is a separate SDK session. TypeScript orchestrates the loop.
 */
function parsePrNumber(prUrl: string): number | undefined {
  const match = /\/pull\/(\d+)(?:\b|$)/.exec(prUrl);
  return match ? Number(match[1]) : undefined;
}

export function workerReportDir(config: WorkerConfig): string {
  return config.taskMeta?.projectReportsDir || getRunReportsDir(config.projectId, config.seedId, config.runId);
}

async function hasChangesAgainstBase(vcsBackend: VcsBackend | undefined, repoPath: string, baseBranch: string, branchName: string): Promise<boolean> {
  if (!vcsBackend) return true;
  const changedFiles = await vcsBackend.getChangedFiles(repoPath, baseBranch, branchName);
  return changedFiles.length > 0;
}

export async function runCreatePrBuiltinPhase(args: {
  config: WorkerConfig;
  store: ForemanStore;
  runtimeTaskClient: ITaskClient;
  pipelineProjectPath: string;
  registeredProjectId?: string;
  registeredReadStore?: PostgresStore;
  vcsBackend?: VcsBackend;
  workflowConfig: WorkflowConfig;
  log: (msg: string) => void;
  agentMailClient: AnyMailClient | null;
}): Promise<PhaseResult> {
  const { config, store, runtimeTaskClient, pipelineProjectPath, registeredProjectId, registeredReadStore, vcsBackend, workflowConfig, log, agentMailClient } = args;

  // Fallback logic mirrors runPipeline: if registeredReadStore is missing but a database
  // URL exists in the project path, derive a PostgresStore for run lookups. This ensures
  // registered/native runs can be found even when registeredProjectId was not propagated.
  const registeredRefineryOptions = deriveFallbackRefineryOptions(
    registeredProjectId,
    registeredReadStore,
    pipelineProjectPath,
    config.projectId,
    log,
  );

  const refinery = new Refinery(
    store,
    runtimeTaskClient,
    pipelineProjectPath,
    vcsBackend,
    registeredRefineryOptions,
  );
  const baseBranch = config.targetBranch ?? await vcsBackend?.detectDefaultBranch(pipelineProjectPath).catch(() => "main") ?? "main";
  const branchName = `foreman/${config.seedId}`;
  const branchHasChanges = await hasChangesAgainstBase(vcsBackend, pipelineProjectPath, baseBranch, branchName).catch(() => true);
  if (!branchHasChanges) {
    const metadataPath = resolveArtifactPath(config.worktreePath, join(workerReportDir(config), "PR_METADATA.json"));
    await mkdir(dirname(metadataPath), { recursive: true });
    await writeFile(metadataPath, JSON.stringify({
      skipped: true,
      reason: "no_changes_against_base",
      branchName,
      baseBranch,
    }, null, 2) + "\n", "utf8");
    await runtimeTaskClient.close(config.seedId, "No changes against target branch; acceptance already satisfied.").catch((err: unknown) => {
      log(`[CREATE-PR] no-change task close failed (non-fatal): ${err instanceof Error ? err.message : String(err)}`);
    });
    log(`[CREATE-PR] No changes between ${baseBranch} and ${branchName}; skipping PR and closing task.`);
    sendMail(agentMailClient, "foreman", "phase-complete", {
      seedId: config.seedId,
      runId: config.runId,
      phase: "create-pr",
      status: "skipped",
      reason: "no_changes_against_base",
    });
    return { success: true, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, outputText: "no_changes_against_base", stopPipelineSuccess: true };
  }
  const pr = await refinery.ensurePullRequestForRun({
    runId: config.runId,
    baseBranch,
    updateRunStatus: false,
    bodyNote: workflowConfig.merge === "auto"
      ? "Automatically published before PR review and refinery merge."
      : "Published for operator review.",
  });
  const prNumber = parsePrNumber(pr.prUrl);
  const headSha = vcsBackend ? await vcsBackend.getHeadId(config.worktreePath).catch(() => undefined) : undefined;
  const metadataPath = resolveArtifactPath(config.worktreePath, join(workerReportDir(config), "PR_METADATA.json"));
  await mkdir(dirname(metadataPath), { recursive: true });
  await writeFile(metadataPath, JSON.stringify({
    prUrl: pr.prUrl,
    prNumber,
    branchName: pr.branchName,
    headSha,
    baseBranch,
  }, null, 2) + "\n", "utf8");
  log(`[CREATE-PR] PR ready: ${pr.prUrl}`);
  sendMail(agentMailClient, "foreman", "pr-created", {
    seedId: config.seedId,
    runId: config.runId,
    branchName: pr.branchName,
    prUrl: pr.prUrl,
    prNumber,
    strategy: workflowConfig.merge ?? "auto",
  });
  return { success: true, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, outputText: pr.prUrl };
}

async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

function positiveIntEnv(name: string, fallback: number): number {
  const value = Number.parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

const PR_WAIT_POLL_MS = positiveIntEnv("FOREMAN_PR_WAIT_POLL_MS", 60_000);
const PR_READY_STABILITY_MS = positiveIntEnv("FOREMAN_PR_READY_STABILITY_MS", 60_000);
const MERGE_GATE_POLL_MS = positiveIntEnv("FOREMAN_MERGE_GATE_POLL_MS", 30_000);
const MERGE_GATE_TIMEOUT_MS = positiveIntEnv("FOREMAN_MERGE_GATE_TIMEOUT_MS", 10 * 60_000);


function readPrNumberFromMetadata(worktreePath: string, reportDir?: string): number {
  const metadataPath = resolveArtifactPath(worktreePath, reportDir ? join(reportDir, "PR_METADATA.json") : "PR_METADATA.json");
  const raw = readFileSync(metadataPath, "utf8");
  const metadata = JSON.parse(raw) as { prNumber?: number; prUrl?: string };
  const prNumber = metadata.prNumber ?? (metadata.prUrl ? parsePrNumber(metadata.prUrl) : undefined);
  if (!prNumber) throw new Error("PR metadata missing prNumber");
  return prNumber;
}

export async function runPrWaitBuiltinPhase(args: {
  config: WorkerConfig;
  phase: WorkflowPhaseConfig;
  pipelineProjectPath: string;
  log: (msg: string) => void;
}): Promise<PhaseResult> {
  const prNumber = readPrNumberFromMetadata(args.config.worktreePath, workerReportDir(args.config));

  const timeoutMs = (args.phase.timeoutSecs ?? 600) * 1000;
  const pollIntervalMs = PR_WAIT_POLL_MS;
  const stabilityMs = PR_READY_STABILITY_MS;
  const startedAt = Date.now();
  let readySince: number | undefined;
  let lastSnapshot = await collectPrWaitSnapshot(args.pipelineProjectPath, prNumber);
  let timedOut = false;

  while (true) {
    const status = summarizePrWaitStatus(lastSnapshot);
    const now = Date.now();
    const stability = updatePrReadyStability(status, readySince, now, stabilityMs);
    readySince = stability.readySince;
    if (status.mergeConflict) break;
    if (stability.stable) break;
    if (Date.now() - startedAt >= timeoutMs) {
      timedOut = true;
      break;
    }
    const stableFor = readySince ? Date.now() - readySince : 0;
    args.log(`[PR-WAIT] Waiting for PR #${prNumber}: checksTerminal=${String(status.checksTerminal)} codeRabbitSeen=${String(status.codeRabbitSeen)} codeRabbitComplete=${String(status.codeRabbitComplete)} mergeConflict=${String(status.mergeConflict)} stableForMs=${stableFor}`);
    await sleep(Math.min(pollIntervalMs, Math.max(0, timeoutMs - (Date.now() - startedAt))));
    lastSnapshot = await collectPrWaitSnapshot(args.pipelineProjectPath, prNumber);
  }

  await writePrWaitReport(args.config.worktreePath, lastSnapshot, timedOut, workerReportDir(args.config));
  const finalStatus = summarizePrWaitStatus(lastSnapshot);
  const success = finalStatus.checksTerminal && finalStatus.codeRabbitComplete && !finalStatus.mergeConflict;
  return {
    success,
    costUsd: 0,
    turns: 0,
    tokensIn: 0,
    tokensOut: 0,
    error: success
      ? undefined
      : finalStatus.mergeConflict
        ? `PR has merge conflicts: ${finalStatus.mergeConflictReason ?? "unknown"}`
        : finalStatus.checksTerminal
          ? "CodeRabbit review did not complete before timeout"
          : "PR checks did not reach a terminal state before timeout",
    outputText: `checksTerminal=${String(finalStatus.checksTerminal)} codeRabbitSeen=${String(finalStatus.codeRabbitSeen)} codeRabbitComplete=${String(finalStatus.codeRabbitComplete)} mergeConflict=${String(finalStatus.mergeConflict)} timedOut=${String(timedOut)}`,
  };
}

export async function runPreparePrReviewBuiltinPhase(args: {
  config: WorkerConfig;
  pipelineProjectPath: string;
  log: (msg: string) => void;
}): Promise<PhaseResult> {
  const prNumber = readPrNumberFromMetadata(args.config.worktreePath, workerReportDir(args.config));
  const context = await collectPrReviewContext(args.pipelineProjectPath, prNumber);
  await writePrReviewFindings(args.config.worktreePath, context, workerReportDir(args.config));
  args.log(`[PR-REVIEW] Collected ${context.blockingFindings.length} blocking CodeRabbit finding(s), ${context.failedChecks.length} failed check(s)`);
  return { success: true, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, outputText: `blocking=${context.blockingFindings.length} failedChecks=${context.failedChecks.length}` };
}

export async function runCliReviewBuiltinPhase(args: {
  config: WorkerConfig;
  pipelineProjectPath: string;
  vcsBackend?: VcsBackend;
  log: (msg: string) => void;
}): Promise<PhaseResult> {
  const baseBranch = args.config.targetBranch
    || await args.vcsBackend?.detectDefaultBranch(args.pipelineProjectPath).catch(() => "main")
    || "main";
  const review = await runCodeRabbitCliReview({
    worktreePath: args.config.worktreePath,
    baseBranch,
    reportDir: workerReportDir(args.config),
    log: args.log,
  });
  return {
    success: review.status === "passed",
    costUsd: 0,
    turns: 0,
    tokensIn: 0,
    tokensOut: 0,
    error: review.status === "passed" ? undefined : review.details,
    outputText: `status=${review.status} blocking=${review.blockingFindings.length} nonBlocking=${review.nonBlockingFindings.length}`,
  };
}

async function runShellForFinalize(command: string, cwd: string, timeoutMs = 120_000): Promise<{ ok: boolean; output: string }> {
  try {
    const { stdout, stderr } = await execFileAsync("/bin/bash", ["-lc", command], {
      cwd,
      timeout: timeoutMs,
      maxBuffer: 5 * 1024 * 1024,
    });
    return { ok: true, output: `${stdout ?? ""}${stderr ?? ""}`.trim() };
  } catch (err: unknown) {
    const e = err as { stdout?: string; stderr?: string; message?: string };
    return { ok: false, output: `${e.stdout ?? ""}${e.stderr ?? ""}${e.message ? `\n${e.message}` : ""}`.trim() };
  }
}

function truncateFinalizeOutput(output: string): string {
  return output.length > 3000 ? `${output.slice(0, 3000)}\n...<truncated>` : output;
}

function isVerificationTask(config: WorkerConfig): boolean {
  const type = (config.seedType ?? "").toLowerCase();
  const title = config.seedTitle.toLowerCase();
  return type === "test" || /\b(verify|validate|test)\b/.test(title);
}

async function writeFinalizeValidation(args: {
  config: WorkerConfig;
  baseBranch: string;
  integrationStatus: "SUCCESS" | "SKIPPED" | "FAIL";
  validationStatus: "PASS" | "FAIL" | "SKIPPED";
  failureScope: "MODIFIED_FILES" | "UNRELATED_FILES" | "UNKNOWN" | "SKIPPED";
  verdict: "PASS" | "FAIL";
  qaRef?: string;
  currentRef?: string;
  output: string;
}): Promise<void> {
  const reportDir = resolveArtifactPath(args.config.worktreePath, workerReportDir(args.config));
  await mkdir(reportDir, { recursive: true });
  await writeFile(join(reportDir, "FINALIZE_VALIDATION.md"), `# Finalize Validation: ${args.config.seedTitle}\n\n` +
    `## Seed: ${args.config.seedId}\n` +
    `## Run: ${args.config.runId}\n` +
    `## Timestamp: ${new Date().toISOString()}\n\n` +
    `## Target Integration\n` +
    `- Status: ${args.integrationStatus}\n` +
    `- Target: origin/${args.baseBranch}\n` +
    `- QA Validated Target Ref: ${args.qaRef ?? ""}\n` +
    `- Current Target Ref: ${args.currentRef ?? ""}\n\n` +
    `## Test Validation\n` +
    `- Status: ${args.validationStatus}\n` +
    `- Output:\n\n\`\`\`text\n${truncateFinalizeOutput(args.output) || "(no output)"}\n\`\`\`\n\n` +
    `## Failure Scope\n` +
    `- ${args.failureScope}\n\n` +
    `## Verdict: ${args.verdict}\n`, "utf8");
}

async function writeFinalizeReport(args: {
  config: WorkerConfig;
  install: { ok: boolean; output: string };
  typecheck: { ok: boolean; output: string };
  commitHash: string;
  pushStatus: "SUCCESS" | "FAILED";
  branchName: string;
}): Promise<void> {
  const reportDir = resolveArtifactPath(args.config.worktreePath, workerReportDir(args.config));
  await mkdir(reportDir, { recursive: true });
  await writeFile(join(reportDir, "FINALIZE_REPORT.md"), `# Finalize Report: ${args.config.seedTitle}\n\n` +
    `## Seed: ${args.config.seedId}\n` +
    `## Run: ${args.config.runId}\n` +
    `## Timestamp: ${new Date().toISOString()}\n\n` +
    `## Dependency Install\n- Status: ${args.install.ok ? "SUCCESS" : "FAILED"}\n- Details: ${truncateFinalizeOutput(args.install.output) || "(none)"}\n\n` +
    `## Type Check\n- Status: ${args.typecheck.ok ? "SUCCESS" : "FAILED"}\n- Details: ${truncateFinalizeOutput(args.typecheck.output) || "(none)"}\n\n` +
    `## Commit\n- Status: SUCCESS\n- Hash: ${args.commitHash}\n\n` +
    `## Push\n- Status: ${args.pushStatus}\n- Branch: ${args.branchName}\n`, "utf8");
}

export async function runFinalizeBuiltinPhase(args: {
  config: WorkerConfig;
  pipelineProjectPath: string;
  vcsBackend?: VcsBackend;
  log: (msg: string) => void;
  progress?: RunProgress;
}): Promise<PhaseResult> {
  const { config, pipelineProjectPath, log } = args;
  const vcsBackend = args.vcsBackend ?? await VcsBackendFactory.create({ backend: "auto" }, config.worktreePath);
  const baseBranch = config.targetBranch || await vcsBackend.detectDefaultBranch(pipelineProjectPath).catch(() => "main");
  const branchName = `foreman/${config.seedId}`;
  const reportDir = workerReportDir(config);

  log(`[FINALIZE] deterministic builtin starting for ${branchName}`);
  const install = await runShellForFinalize("npm ci", config.worktreePath, 5 * 60_000);
  const typecheck = await runShellForFinalize("npx tsc --noEmit", config.worktreePath, 5 * 60_000);

  const commands = vcsBackend.getFinalizeCommands({
    seedId: config.seedId,
    seedTitle: config.seedTitle,
    baseBranch,
    worktreePath: config.worktreePath,
    githubIssueNumber: config.githubIssueNumber,
  });

  await runShellForFinalize(commands.stageCommand || "true", config.worktreePath, PIPELINE_TIMEOUTS.gitOperationMs);
  await runShellForFinalize(commands.restoreTrackedStateCommand || "true", config.worktreePath, PIPELINE_TIMEOUTS.gitOperationMs);

  let commitHash = await vcsBackend.getHeadId(config.worktreePath).catch(() => "unknown");
  const statusBeforeCommit = await vcsBackend.status(config.worktreePath).catch(() => "");
  if (statusBeforeCommit.trim()) {
    try {
      const suffix = config.githubIssueNumber ? `\n\nFixes #${config.githubIssueNumber}` : "";
      await vcsBackend.commit(config.worktreePath, `chore: finalize ${config.seedId}\n\n${config.seedTitle}${suffix}`);
      commitHash = await vcsBackend.getHeadId(config.worktreePath).catch(() => commitHash);
    } catch (err: unknown) {
      const changedAgainstBase = await vcsBackend.getChangedFiles(config.worktreePath, `origin/${baseBranch}`, "HEAD").catch(() => []);
      if (changedAgainstBase.length === 0 && !isVerificationTask(config)) {
        const msg = err instanceof Error ? err.message : String(err);
        return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: `nothing_to_commit: ${msg}` };
      }
      log(`[FINALIZE] commit skipped; branch already has changes or task is verification-only`);
    }
  } else {
    const changedAgainstBase = await vcsBackend.getChangedFiles(config.worktreePath, `origin/${baseBranch}`, "HEAD").catch(() => []);
    if (changedAgainstBase.length === 0 && !isVerificationTask(config)) {
      return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: "nothing_to_commit" };
    }
  }

  let currentTargetRef = "";
  for (const candidate of [`origin/${baseBranch}`, baseBranch]) {
    try { currentTargetRef = await vcsBackend.resolveRef(config.worktreePath, candidate); break; } catch { /* try next */ }
  }
  const qaRef = args.progress?.qaValidatedTargetRef;
  const shouldValidate = !qaRef || !currentTargetRef || qaRef !== currentTargetRef;
  let integrationStatus: "SUCCESS" | "SKIPPED" | "FAIL" = "SKIPPED";

  if (shouldValidate) {
    let rebaseError: string | undefined;
    const rebase = await vcsBackend.rebase(config.worktreePath, `origin/${baseBranch}`).catch((err: unknown) => {
      rebaseError = err instanceof Error ? err.message : String(err);
      return { success: false, hasConflicts: true, conflictingFiles: [] };
    });
    if (!rebase.success) {
      await vcsBackend.abortRebase(config.worktreePath).catch(() => undefined);
      const details = rebaseError ?? (rebase.conflictingFiles?.length ? `conflicts: ${rebase.conflictingFiles.join(", ")}` : "rebase failed");
      await writeFinalizeValidation({ config, baseBranch, integrationStatus: "FAIL", validationStatus: "SKIPPED", failureScope: "UNKNOWN", verdict: "FAIL", qaRef, currentRef: currentTargetRef, output: details });
      return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: `rebase_conflict: ${details}`, outputText: readFileSync(resolveArtifactPath(config.worktreePath, join(reportDir, "FINALIZE_VALIDATION.md")), "utf8") };
    }
    integrationStatus = "SUCCESS";
    const test = await runShellForFinalize("npm test -- --reporter=dot", config.worktreePath, 10 * 60_000);
    if (!test.ok) {
      await writeFinalizeValidation({ config, baseBranch, integrationStatus, validationStatus: "FAIL", failureScope: "UNKNOWN", verdict: "FAIL", qaRef, currentRef: currentTargetRef, output: test.output });
      return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: "finalize_validation_failed", outputText: readFileSync(resolveArtifactPath(config.worktreePath, join(reportDir, "FINALIZE_VALIDATION.md")), "utf8") };
    }
    await writeFinalizeValidation({ config, baseBranch, integrationStatus, validationStatus: "PASS", failureScope: "SKIPPED", verdict: "PASS", qaRef, currentRef: currentTargetRef, output: test.output });
  } else {
    await writeFinalizeValidation({ config, baseBranch, integrationStatus, validationStatus: "SKIPPED", failureScope: "SKIPPED", verdict: "PASS", qaRef, currentRef: currentTargetRef, output: "QA already passed and target branch did not move after QA." });
  }

  try {
    await vcsBackend.push(config.worktreePath, branchName, { allowNew: true });
  } catch (err: unknown) {
    await writeFinalizeReport({ config, install, typecheck, commitHash, pushStatus: "FAILED", branchName });
    return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: `push_failed: ${err instanceof Error ? err.message : String(err)}` };
  }

  await writeFinalizeReport({ config, install, typecheck, commitHash, pushStatus: "SUCCESS", branchName });
  return {
    success: true,
    costUsd: 0,
    turns: 0,
    tokensIn: 0,
    tokensOut: 0,
    outputText: readFileSync(resolveArtifactPath(config.worktreePath, join(reportDir, "FINALIZE_VALIDATION.md")), "utf8"),
  };
}


export async function validatePrReviewGate(args: {
  worktreePath: string;
  pipelineProjectPath: string;
  log: (msg: string) => void;
  reportDir?: string;
}): Promise<{ success: boolean; reason?: string }> {
  const prNumber = readPrNumberFromMetadata(args.worktreePath, args.reportDir);
  const startedAt = Date.now();
  let readySince: number | undefined;
  let waitSnapshot = await collectPrWaitSnapshot(args.pipelineProjectPath, prNumber);
  let waitStatus = summarizePrWaitStatus(waitSnapshot);

  while (true) {
    const stability = updatePrReadyStability(waitStatus, readySince, Date.now(), PR_READY_STABILITY_MS);
    readySince = stability.readySince;
    if (waitStatus.mergeConflict) break;
    if (stability.stable) break;
    if (Date.now() - startedAt >= MERGE_GATE_TIMEOUT_MS) break;
    const stableFor = readySince ? Date.now() - readySince : 0;
    args.log(
      `[PR-REVIEW] Final gate waiting for PR #${prNumber}: checksTerminal=${String(waitStatus.checksTerminal)} ` +
        `codeRabbitSeen=${String(waitStatus.codeRabbitSeen)} codeRabbitComplete=${String(waitStatus.codeRabbitComplete)} mergeConflict=${String(waitStatus.mergeConflict)} ` +
        `pending=${waitStatus.pendingChecks.join(", ") || "none"} stableForMs=${stableFor}`,
    );
    await sleep(Math.min(MERGE_GATE_POLL_MS, Math.max(0, MERGE_GATE_TIMEOUT_MS - (Date.now() - startedAt))));
    waitSnapshot = await collectPrWaitSnapshot(args.pipelineProjectPath, prNumber);
    waitStatus = summarizePrWaitStatus(waitSnapshot);
  }

  const reviewContext = await collectPrReviewContext(args.pipelineProjectPath, prNumber);

  args.log(
    `[PR-REVIEW] Final gate for PR #${prNumber}: checksTerminal=${String(waitStatus.checksTerminal)} ` +
      `codeRabbitSeen=${String(waitStatus.codeRabbitSeen)} codeRabbitComplete=${String(waitStatus.codeRabbitComplete)} mergeConflict=${String(waitStatus.mergeConflict)} ` +
      `blocking=${reviewContext.blockingFindings.length} failedChecks=${reviewContext.failedChecks.length}`,
  );

  if (waitStatus.mergeConflict) return { success: false, reason: `pr_review_merge_conflict: ${waitStatus.mergeConflictReason ?? "unknown"}` };
  if (!waitStatus.checksTerminal) return { success: false, reason: `pr_review_checks_pending: ${waitStatus.pendingChecks.join(", ") || "unknown"}` };
  if (!waitStatus.codeRabbitComplete) return { success: false, reason: waitStatus.codeRabbitSeen ? "pr_review_coderabbit_not_complete" : "pr_review_coderabbit_not_observed" };
  if (reviewContext.failedChecks.length > 0) return { success: false, reason: `pr_review_failed_checks: ${reviewContext.failedChecks.map((check) => check.name).join(", ")}` };
  if (reviewContext.blockingFindings.length > 0) return { success: false, reason: `pr_review_blocking_findings: ${reviewContext.blockingFindings.length}` };
  return { success: true };
}

async function writeMergeReport(args: {
  config: WorkerConfig;
  status: "SUCCESS" | "FAIL" | "SKIPPED";
  details: string;
  merged?: number;
  conflicts?: number;
  failed?: number;
  prNumber?: number;
}): Promise<void> {
  const reportPath = resolveArtifactPath(args.config.worktreePath, join(workerReportDir(args.config), "MERGE_REPORT.md"));
  await mkdir(dirname(reportPath), { recursive: true });
  await writeFile(reportPath, `# Merge Report: ${args.config.seedTitle}\n\n` +
    `## Seed: ${args.config.seedId}\n` +
    `## Run: ${args.config.runId}\n` +
    `## Status: ${args.status}\n\n` +
    `## PR\n` +
    `- Number: ${args.prNumber ?? "unknown"}\n\n` +
    `## Result\n` +
    `- Merged: ${args.merged ?? 0}\n` +
    `- Conflicts: ${args.conflicts ?? 0}\n` +
    `- Failed: ${args.failed ?? 0}\n\n` +
    `## Details\n${args.details}\n`, "utf8");
}

export async function runMergeBuiltinPhase(args: {
  config: WorkerConfig;
  store: ForemanStore;
  pipelineProjectPath: string;
  registeredProjectId?: string;
  registeredReadStore?: PostgresStore;
  vcsBackend?: VcsBackend;
  workflowConfig: WorkflowConfig;
  runtimeTaskClient: ITaskClient;
  log: (msg: string) => void;
  agentMailClient: AnyMailClient | null;
}): Promise<PhaseResult> {
  const { config, store, pipelineProjectPath, registeredProjectId, registeredReadStore, vcsBackend, workflowConfig, runtimeTaskClient, log, agentMailClient } = args;
  const mergeStrategy = workflowConfig.merge ?? "auto";
  const prNumber = (() => {
    try { return readPrNumberFromMetadata(config.worktreePath, workerReportDir(config)); } catch { return undefined; }
  })();

  if (mergeStrategy !== "auto") {
    const details = `Workflow merge strategy is ${mergeStrategy}; explicit merge phase skipped auto-merge.`;
    await writeMergeReport({ config, status: "SKIPPED", details, prNumber });
    log(`[MERGE] ${details}`);
    return { success: true, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, outputText: details };
  }

  const gate = await validatePrReviewGate({
    worktreePath: config.worktreePath,
    pipelineProjectPath,
    log,
    reportDir: workerReportDir(config),
  }).catch((err: unknown) => {
    const message = err instanceof Error ? err.message : String(err);
    const reason = isGhAuthFailure(err)
      ? `pr_review_gate_auth_unavailable: ${message}`
      : `pr_review_gate_error: ${message}`;
    return { success: false, reason };
  });
  if (!gate.success) {
    const details = gate.reason ?? "pr_review_gate_failed";
    await writeMergeReport({ config, status: "FAIL", details, prNumber });
    return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: details, outputText: details };
  }

  let enqueueFiles: string[] = [];
  try {
    const enqueueBackend = vcsBackend ?? await VcsBackendFactory.create({ backend: "auto" }, config.worktreePath);
    const enqueueDefaultBranch = await enqueueBackend.detectDefaultBranch(config.worktreePath);
    enqueueFiles = await enqueueBackend.getChangedFiles(config.worktreePath, enqueueDefaultBranch, "HEAD");
  } catch {
    // Non-fatal — proceed with empty file list.
  }

  const enqueueResult = await enqueueToMergeQueue({
    projectId: config.projectId,
    seedId: config.seedId,
    runId: config.runId,
    operation: "auto_merge",
    worktreePath: config.worktreePath,
    getFilesModified: () => enqueueFiles,
  });
  if (!enqueueResult.success) {
    const details = `Merge queue enqueue failed: ${enqueueResult.error ?? "unknown"}`;
    await writeMergeReport({ config, status: "FAIL", details, prNumber });
    return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: details, outputText: details };
  }

  sendMail(agentMailClient, "refinery", "branch-ready", {
    seedId: config.seedId,
    runId: config.runId,
    branch: `foreman/${config.seedId}`,
    worktreePath: config.worktreePath,
  });

  const now = new Date().toISOString();
  await updateTerminalRunStatus({
    runId: config.runId,
    projectId: config.projectId,
    projectPath: pipelineProjectPath,
    updates: { status: "completed", completed_at: now },
  });

  const registeredAutoMergeReadStore = registeredProjectId ? registeredReadStore : undefined;
  const currentRun = registeredAutoMergeReadStore
    ? (await registeredAutoMergeReadStore.getRun(config.runId)) ?? undefined
    : store.getRun(config.runId) ?? undefined;
  const mergeResult = await autoMerge({
    store,
    taskClient: runtimeTaskClient,
    projectPath: pipelineProjectPath,
    targetBranch: config.targetBranch,
    ...(registeredAutoMergeReadStore
      ? { registeredProjectId, readLookup: registeredAutoMergeReadStore }
      : {}),
    runId: config.runId,
    targetOnly: true,
    ...(currentRun ? { overrideRun: currentRun } : {}),
  });

  const targetMergeResult = mergeResult.target;
  const details = `Immediate target merge result: merged=${mergeResult.merged}, conflicts=${mergeResult.conflicts}, failed=${mergeResult.failed}`
    + (targetMergeResult
      ? `; target=${targetMergeResult.runId} merged=${targetMergeResult.merged}, conflicts=${targetMergeResult.conflicts}, failed=${targetMergeResult.failed}`
      : "");
  const success = targetMergeResult
    ? targetMergeResult.merged > 0 && targetMergeResult.conflicts === 0 && targetMergeResult.failed === 0
    : mergeResult.merged > 0 && mergeResult.conflicts === 0 && mergeResult.failed === 0;
  await writeMergeReport({
    config,
    status: success ? "SUCCESS" : "FAIL",
    details,
    merged: mergeResult.merged,
    conflicts: mergeResult.conflicts,
    failed: mergeResult.failed,
    prNumber,
  });
  log(`[MERGE] ${details}`);

  return {
    success,
    costUsd: 0,
    turns: 0,
    tokensIn: 0,
    tokensOut: 0,
    error: success ? undefined : details,
    outputText: details,
  };
}
