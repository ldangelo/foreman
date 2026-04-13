import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
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
  explorer: "EXPLORER_REPORT.md",
  developer: "DEVELOPER_REPORT.md",
  qa: "QA_REPORT.md",
  reviewer: "REVIEW.md",
  finalize: "FINALIZE_VALIDATION.md",
  troubleshooter: "TROUBLESHOOT_REPORT.md",
};

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

function buildArtifactBody(phase: string, seedId: string): string {
  if (phase === "qa") {
    return [
      "# QA",
      "",
      `Seed: ${seedId}`,
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
      `Seed: ${seedId}`,
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
      `Seed: ${seedId}`,
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
      `Seed: ${seedId}`,
      "## Verdict: PASS",
      "",
      "Smoke test noop.",
      "",
    ].join("\n");
  }

  return [
    `# ${phase}`,
    "",
    `Seed: ${seedId}`,
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

function commitChanges(cwd: string, seedId: string): void {
  execFileSync("git", ["add", "-A"], { cwd, stdio: "pipe" });
  const status = execFileSync("git", ["status", "--short"], {
    cwd,
    encoding: "utf-8",
    stdio: "pipe",
  }).trim();
  if (!status) return;
  execFileSync("git", ["commit", "-m", `Deterministic smoke finalize (${seedId})`], {
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
  const scenario = parseScenario(context.seedDescription);
  const artifact = PHASE_ARTIFACTS[phase] ?? `${phase.toUpperCase()}_REPORT.md`;
  const filesChanged: string[] = [];

  if (phase === "developer") {
    filesChanged.push(...applyScenario(cwd, scenario));
  }

  if (phase === "finalize") {
    if (!filesChanged.length && scenario.kind) {
      filesChanged.push(...applyScenario(cwd, scenario));
    }
    commitChanges(cwd, context.seedId);
  }

  writeArtifact(
    cwd,
    artifact,
    buildArtifactBody(phase, context.seedId),
  );
  appendFileSync(
    join(cwd, "RUN_LOG.md"),
    `${new Date().toISOString()} ${phase} ${context.seedId}\n`,
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
    outputText: filesChanged.join(", "),
  };
}
