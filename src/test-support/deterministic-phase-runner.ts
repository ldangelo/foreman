import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { execFileSync } from "node:child_process";
import type { PiRunResult } from "../orchestrator/pi-sdk-runner.js";
import type { PhaseRunnerOptions } from "../orchestrator/phase-runner.js";

type ScenarioKind = "create" | "append" | "replace";

interface DeterministicScenario {
  kind?: ScenarioKind;
  file?: string;
  content?: string;
}

const PHASE_ARTIFACTS: Record<string, string> = {
  explore: "EXPLORER_REPORT.md",
  explorer: "EXPLORER_REPORT.md",
  develop: "DEVELOPER_REPORT.md",
  developer: "DEVELOPER_REPORT.md",
  fix: "DEVELOPER_REPORT.md",
  implement: "IMPLEMENT_REPORT.md",
  prd: "PRD.md",
  trd: "TRD.md",
  documentation: "DOCUMENTATION_REPORT.md",
  qa: "QA_REPORT.md",
  reviewer: "REVIEW.md",
  finalize: "FINALIZE_VALIDATION.md",
  troubleshooter: "TROUBLESHOOT_REPORT.md",
};

const EDIT_PHASES = new Set(["develop", "developer", "fix", "implement"]);

function parseScenario(description?: string): DeterministicScenario {
  const marker = "FOREMAN_TEST_SCENARIO=";
  const line = description?.split("\n").find((entry) => entry.includes(marker));
  if (!line) return {};
  const raw = line.slice(line.indexOf(marker) + marker.length).trim();
  try {
    return JSON.parse(raw) as DeterministicScenario;
  } catch {
    return {};
  }
}

function writeArtifact(cwd: string, artifact: string, body: string): void {
  const path = join(cwd, artifact);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, body, "utf-8");
}

function findReportDir(taskId: string, runId?: string): string | null {
  const reportsRoot = process.env.FOREMAN_HOME ? join(process.env.FOREMAN_HOME, "reports") : null;
  if (!reportsRoot || !existsSync(reportsRoot)) return null;
  const stack = [reportsRoot];
  while (stack.length) {
    const dir = stack.pop()!;
    if (runId && dir.endsWith(join(taskId, runId))) return dir;
    if (!runId && dir.endsWith(taskId)) {
      const children = readdirSync(dir).map((entry) => join(dir, entry)).filter((entry) => statSync(entry).isDirectory());
      if (children.length === 1) return children[0];
    }
    for (const entry of readdirSync(dir)) {
      const child = join(dir, entry);
      if (statSync(child).isDirectory()) stack.push(child);
    }
  }

  if (runId) {
    const projectDirs = readdirSync(reportsRoot)
      .map((entry) => join(reportsRoot, entry))
      .filter((entry) => statSync(entry).isDirectory());
    if (projectDirs.length === 1) return join(projectDirs[0], taskId, runId);
  }

  return null;
}

function extractReportDir(prompt: string): string | null {
  const mkdirMatch = prompt.match(/mkdir -p \"([^\"]+)\"/);
  if (mkdirMatch?.[1]) return mkdirMatch[1];
  const reportPathMatch = prompt.match(/\*\*([^*\n]+\/(?:PRD|TRD|IMPLEMENT_REPORT|DEVELOPER_REPORT|DOCUMENTATION_REPORT|QA_REPORT|REVIEW|FINALIZE_VALIDATION|TROUBLESHOOT_REPORT)\.md)\*\*/);
  if (reportPathMatch?.[1]) return dirname(reportPathMatch[1]);
  return null;
}

function buildArtifactBody(phase: string, taskId: string): string {
  if (phase === "documentation") {
    return [
      "# Documentation",
      "",
      `Task: ${taskId}`,
      "## Verdict: PASS",
      "",
      "## Documentation Updated",
      "- none required for deterministic test",
      "",
    ].join("\n");
  }

  if (phase === "qa") {
    return [
      "# QA",
      "",
      `Task: ${taskId}`,
      "## Verdict: PASS",
      "",
      "## Test Evidence",
      "- Command: npm test",
      "- Result: 1 passed, 0 failed",
      "",
    ].join("\n");
  }

  if (phase === "reviewer") {
    return [
      "# Review",
      "",
      `Task: ${taskId}`,
      "## Verdict: PASS",
      "",
      "## Issues",
      "(none)",
      "",
    ].join("\n");
  }

  if (phase === "finalize") {
    return [
      "# Finalize",
      "",
      `Task: ${taskId}`,
      "## Verdict: PASS",
      "## Test Validation: SKIPPED",
      "## Target Integration: SKIPPED",
      "",
    ].join("\n");
  }

  if (phase === "explorer") {
    return [
      "# Explorer",
      "",
      `Task: ${taskId}`,
      "## Verdict: PASS",
      "",
      "Smoke test noop.",
      "",
    ].join("\n");
  }

  return [
    `# ${phase}`,
    "",
    `Task: ${taskId}`,
    "## Verdict: PASS",
    "",
  ].join("\n");
}

function applyScenario(cwd: string, scenario: DeterministicScenario): string[] {
  const file = scenario.file ?? "test.txt";
  const target = join(cwd, file);
  mkdirSync(dirname(target), { recursive: true });
  const content = scenario.content ?? "deterministic smoke output\n";

  switch (scenario.kind ?? "create") {
    case "append": {
      const existing = existsSync(target) ? readFileSync(target, "utf-8") : "";
      writeFileSync(target, `${existing}${content}`, "utf-8");
      break;
    }
    case "replace":
    case "create":
    default:
      writeFileSync(target, content, "utf-8");
      break;
  }

  return [file];
}

function commitChanges(cwd: string, taskId: string): void {
  execFileSync("git", ["add", "-A"], { cwd, stdio: "pipe" });
  const status = execFileSync("git", ["status", "--short"], {
    cwd,
    encoding: "utf-8",
    stdio: "pipe",
  }).trim();
  if (!status) return;
  execFileSync("git", ["commit", "-m", `Deterministic smoke finalize (${taskId})`], {
    cwd,
    stdio: "pipe",
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "Foreman Test",
      GIT_AUTHOR_EMAIL: "foreman-test@example.com",
      GIT_COMMITTER_NAME: "Foreman Test",
      GIT_COMMITTER_EMAIL: "foreman-test@example.com",
    },
  });
}

export async function runDeterministicPhase(opts: PhaseRunnerOptions): Promise<PiRunResult> {
  const { context, cwd, onTurnEnd } = opts;
  const phase = context.phaseName;
  const scenario = parseScenario(context.taskDescription);
  const artifact = PHASE_ARTIFACTS[phase] ?? `${phase.toUpperCase()}_REPORT.md`;
  const filesChanged: string[] = [];
  const reportDir = extractReportDir(opts.prompt) ?? findReportDir(context.taskId, context.runId);

  if (EDIT_PHASES.has(phase)) {
    filesChanged.push(...applyScenario(cwd, scenario));
  }

  if (phase === "finalize") {
    if (!filesChanged.length && scenario.kind) {
      filesChanged.push(...applyScenario(cwd, scenario));
    }
    commitChanges(cwd, context.taskId);
  }

  const artifactBody = buildArtifactBody(phase, context.taskId);
  writeArtifact(cwd, artifact, artifactBody);
  if (reportDir) {
    writeArtifact(cwd, join(reportDir, artifact), artifactBody);
  }
  appendFileSync(
    join(cwd, "RUN_LOG.md"),
    `${new Date().toISOString()} ${phase} ${context.taskId}\n`,
    "utf-8",
  );

  onTurnEnd?.(1);
  return {
    success: true,
    costUsd: 0,
    turns: 1,
    toolCalls: 0,
    toolBreakdown: {},
    tokensIn: 0,
    tokensOut: 0,
    filesChanged,
    outputText: filesChanged.join(", "),
  };
}
