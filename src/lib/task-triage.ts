export type TaskScope = "local" | "moderate" | "broad";
export type TaskRisk = "low" | "medium" | "high";
export type WorkflowLane = "small" | "medium" | "default" | "smoke" | "epic";

export interface TaskTriageInput {
  seedType: string;
  seedTitle: string;
  seedDescription?: string;
  seedComments?: string;
  seedLabels?: string[];
}

export interface TaskTriageResult {
  score: number;
  scope: TaskScope;
  risk: TaskRisk;
  workflowName: WorkflowLane | string;
  confidence: "low" | "medium" | "high";
  rationale: string[];
}

function clampScore(score: number): number {
  return Math.max(0, Math.min(100, score));
}

function includesAny(text: string, needles: string[]): boolean {
  return needles.some((needle) => text.includes(needle));
}

export function triageTask(input: TaskTriageInput): TaskTriageResult {
  const labels = input.seedLabels ?? [];
  for (const label of labels) {
    if (label.startsWith("workflow:")) {
      return {
        score: 50,
        scope: "moderate",
        risk: "medium",
        workflowName: label.slice("workflow:".length),
        confidence: "high",
        rationale: [`explicit workflow override via ${label}`],
      };
    }
  }

  if (input.seedType === "smoke") {
    return {
      score: 10,
      scope: "local",
      risk: "low",
      workflowName: "smoke",
      confidence: "high",
      rationale: ["smoke tasks use the dedicated smoke workflow"],
    };
  }

  if (input.seedType === "epic") {
    return {
      score: 90,
      scope: "broad",
      risk: "high",
      workflowName: "epic",
      confidence: "high",
      rationale: ["epic tasks always require the epic workflow"],
    };
  }

  const combined = [
    input.seedTitle,
    input.seedDescription ?? "",
    input.seedComments ?? "",
    labels.join(" "),
  ].join(" ").toLowerCase();

  let score = 25;
  const rationale: string[] = [];

  const smallSignals = [
    "status",
    "list",
    "title",
    "description",
    "spacing",
    "output",
    "display",
    "render",
    "prompt",
    "docs",
    "typo",
    "cli",
    "inbox",
    "watch",
  ];
  const mediumSignals = [
    "feature",
    "validator",
    "triage",
    "retry",
    "reviewer",
    "qa",
    "phase",
    "dashboard",
    "workflow",
    "routing",
  ];
  const complexSignals = [
    "migration",
    "database",
    "schema",
    "security",
    "authentication",
    "authorization",
    "concurrency",
    "orchestrator",
    "refactor",
    "architecture",
    "performance",
    "vcs",
    "merge",
    "queue",
    "session sharing",
  ];

  if (includesAny(combined, smallSignals)) {
    score -= 15;
    rationale.push("localized CLI/output signals detected");
  }

  if (includesAny(combined, mediumSignals)) {
    score += 15;
    rationale.push("workflow/validation signals indicate medium coordination");
  }

  if (includesAny(combined, complexSignals)) {
    score += 30;
    rationale.push("high-complexity/risk signals detected");
  }

  if ((input.seedDescription ?? "").length > 600) {
    score += 10;
    rationale.push("long description suggests broader scope");
  }

  if (input.seedType === "bug") {
    score -= 5;
    rationale.push("bug type slightly lowers default complexity");
  } else if (input.seedType === "feature") {
    score += 5;
    rationale.push("feature type slightly increases default complexity");
  }

  score = clampScore(score);

  const workflowName = score <= 20 ? "small" : score <= 50 ? "medium" : "default";
  const scope: TaskScope = score <= 20 ? "local" : score <= 50 ? "moderate" : "broad";
  const risk: TaskRisk = score <= 20 ? "low" : score <= 50 ? "medium" : "high";
  const confidence = rationale.length >= 2 ? "high" : "medium";

  return {
    score,
    scope,
    risk,
    workflowName,
    confidence,
    rationale,
  };
}

export function formatTriageReport(input: TaskTriageInput, result: TaskTriageResult): string {
  return [
    `# Triage Report: ${input.seedTitle}`,
    "",
    `- Score: ${result.score}/100`,
    `- Scope: ${result.scope}`,
    `- Risk: ${result.risk}`,
    `- Confidence: ${result.confidence}`,
    `- Recommended workflow: ${result.workflowName}`,
    "",
    "## Rationale",
    ...result.rationale.map((item) => `- ${item}`),
    "",
  ].join("\n");
}
