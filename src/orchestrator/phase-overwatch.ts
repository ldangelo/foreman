import { existsSync, readFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import type { ExtensionAPI, ExtensionFactory } from "@mariozechner/pi-coding-agent";

export type PhaseOutcome = "completed" | "completed_budget_limited" | "blocked_budget_exhausted" | "failed" | "cancelled";

export interface PhaseContractConfig {
  goal?: string;
  requiredSections?: string[];
  completion?: {
    minEditTargets?: number;
    maxEditTargets?: number;
    requireTestTargets?: boolean;
    requireFilesChanged?: boolean;
    requireValidationNotes?: boolean;
  };
  allowedScope?: {
    canRead?: boolean;
    canWriteOnly?: string[];
  };
}

export interface PhaseOverwatchConfig {
  enabled?: boolean;
  mode?: "off" | "warn" | "enforce";
  checkEveryTurns?: number;
  forceArtifactNearMaxTurns?: boolean;
  continueIfArtifactValidOnBudgetStop?: boolean;
  maxSteersPerPhase?: number;
  forceArtifactAfterSteers?: number;
  forceArtifactAfterToolCalls?: number;
  repeatedCommandLimit?: number;
  maxToolCalls?: number;
  blockedCommands?: string[];
}

export interface PhaseControlConfig {
  phaseName: string;
  worktreePath: string;
  artifact?: string;
  maxTurns?: number;
  contract?: PhaseContractConfig;
  overwatch?: PhaseOverwatchConfig;
}

export interface ArtifactValidation {
  exists: boolean;
  valid: boolean;
  path?: string;
  missingSections: string[];
  findings: string[];
}

export interface PhaseTelemetrySummary {
  phaseName: string;
  turns: number;
  toolCalls: number;
  toolCounts: Record<string, number>;
  filesRead: string[];
  filesWritten: string[];
  commandsRun: string[];
  deniedActions: string[];
  steers: number;
  lastSteer?: string;
}

interface ToolCallEventLike {
  toolName: string;
  input?: Record<string, unknown>;
}

function normalizeToolName(name: string): string {
  return name.trim().toLowerCase();
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function stripCwd(path: string, cwd: string): string {
  const resolved = resolve(cwd, path);
  const prefix = resolve(cwd) + "/";
  return resolved.startsWith(prefix) ? resolved.slice(prefix.length) : path;
}

function resolveArtifact(worktreePath: string, artifact?: string): string | undefined {
  if (!artifact) return undefined;
  return resolve(worktreePath, artifact);
}

function readArtifact(worktreePath: string, artifact?: string): { path?: string; content?: string } {
  const path = resolveArtifact(worktreePath, artifact);
  if (!path || !existsSync(path)) return { path };
  try {
    return { path, content: readFileSync(path, "utf8") };
  } catch {
    return { path };
  }
}

function sectionPresent(content: string, section: string): boolean {
  const escaped = section.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(^|\\n)#{1,6}\\s+.*${escaped}|(^|\\n)\\*\\*${escaped}\\*\\*`, "i").test(content)
    || content.toLowerCase().includes(section.toLowerCase());
}

function countListItemsAfterHeading(content: string, headingTerms: string[]): number {
  const lines = content.split(/\r?\n/);
  let inSection = false;
  let count = 0;
  for (const line of lines) {
    const isHeading = /^#{1,6}\s+/.test(line);
    if (isHeading) {
      const lower = line.toLowerCase();
      inSection = headingTerms.some((term) => lower.includes(term));
      continue;
    }
    if (!inSection) continue;
    if (/^\s*(-|\*|\d+\.)\s+\S/.test(line)) count++;
  }
  return count;
}

export function validatePhaseArtifact(config: PhaseControlConfig): ArtifactValidation {
  const { path, content } = readArtifact(config.worktreePath, config.artifact);
  const result: ArtifactValidation = {
    exists: Boolean(content),
    valid: false,
    path,
    missingSections: [],
    findings: [],
  };
  if (!content) {
    result.findings.push(config.artifact ? `Artifact missing: ${config.artifact}` : "No artifact configured");
    return result;
  }

  const required = config.contract?.requiredSections ?? defaultRequiredSections(config.phaseName);
  for (const section of required) {
    if (!sectionPresent(content, section)) result.missingSections.push(section);
  }

  if (config.phaseName === "explorer") {
    const editTargets = countListItemsAfterHeading(content, ["edit target", "likely edit", "implementation target"]);
    const testTargets = countListItemsAfterHeading(content, ["test target", "test", "validation"]);
    const minEditTargets = config.contract?.completion?.minEditTargets ?? 1;
    const maxEditTargets = config.contract?.completion?.maxEditTargets ?? 3;
    const requireTestTargets = config.contract?.completion?.requireTestTargets ?? true;
    if (editTargets < minEditTargets) result.findings.push(`Expected at least ${minEditTargets} edit target(s)`);
    if (editTargets > maxEditTargets) result.findings.push(`Expected no more than ${maxEditTargets} edit target(s)`);
    if (requireTestTargets && testTargets < 1) result.findings.push("Expected at least one test target");
  }

  if (["qa", "reviewer", "finalize", "cli-review", "pr-review"].includes(config.phaseName)) {
    if (!/\b(PASS|FAIL|BLOCKED|VERDICT)\b/i.test(content)) {
      result.findings.push("Expected explicit verdict/status");
    }
  }

  if (config.contract?.completion?.requireFilesChanged && !/\b(Files Changed|Changed Files|Modified Files)\b/i.test(content)) {
    result.findings.push("Expected changed-files summary");
  }

  if (config.contract?.completion?.requireValidationNotes && !/\b(QA Handoff|Commands|Validation|Verification|Findings)\b/i.test(content)) {
    result.findings.push("Expected validation handoff or command notes");
  }

  result.valid = result.missingSections.length === 0 && result.findings.length === 0;
  return result;
}

function defaultRequiredSections(phaseName: string): string[] {
  switch (phaseName) {
    case "explorer":
      return ["Summary", "Likely edit targets", "Test targets", "Risks"];
    case "developer":
      return ["Approach", "Files Changed", "QA Handoff", "Decisions", "Known Limitations"];
    case "qa":
      return ["Verdict", "Commands", "Findings"];
    case "reviewer":
      return ["Verdict", "Summary", "Issues"];
    case "documentation":
      return ["Verdict", "Documentation Updated", "Documentation Not Needed", "Checks"];
    case "pr-review":
      return ["Verdict", "Findings Reviewed", "Actions Taken", "Validation", "Remaining Blocking Items"];
    case "troubleshooter":
      return ["Summary", "Root Cause", "Recommended Fix"];
    case "finalize":
      return ["Verdict", "Commands"];
    default:
      return [];
  }
}

class PhaseTelemetry {
  private readonly startedAt = Date.now();
  turns = 0;
  toolCalls = 0;
  toolCounts: Record<string, number> = {};
  filesRead = new Set<string>();
  filesWritten = new Set<string>();
  commandsRun: string[] = [];
  deniedActions: string[] = [];
  steers = 0;
  lastSteer?: string;

  constructor(private readonly config: PhaseControlConfig) {}

  recordTurn(turn: number): void {
    this.turns = Math.max(this.turns, turn);
  }

  recordTool(toolName: string, input: Record<string, unknown>): void {
    const normalized = normalizeToolName(toolName);
    this.toolCalls++;
    this.toolCounts[normalized] = (this.toolCounts[normalized] ?? 0) + 1;
    const path = asString(input.path) ?? asString(input.file_path) ?? asString(input.filePath);
    if (path && (normalized === "read" || normalized === "grep")) {
      this.filesRead.add(stripCwd(path, this.config.worktreePath));
    }
    if (path && (normalized === "write" || normalized === "edit")) {
      this.filesWritten.add(stripCwd(path, this.config.worktreePath));
    }
    const command = asString(input.command);
    if (command && normalized === "bash") this.commandsRun.push(command);
  }

  deny(reason: string): void {
    this.deniedActions.push(reason);
  }

  steer(message: string): void {
    this.steers++;
    this.lastSteer = message;
  }

  summary(): PhaseTelemetrySummary {
    return {
      phaseName: this.config.phaseName,
      turns: this.turns,
      toolCalls: this.toolCalls,
      toolCounts: { ...this.toolCounts },
      filesRead: [...this.filesRead],
      filesWritten: [...this.filesWritten],
      commandsRun: [...this.commandsRun],
      deniedActions: [...this.deniedActions],
      steers: this.steers,
      lastSteer: this.lastSteer,
    };
  }
}

function artifactWriteAllowed(config: PhaseControlConfig, filePath: string): boolean {
  if (!config.artifact) return false;
  return resolve(config.worktreePath, filePath) === resolve(config.worktreePath, config.artifact);
}

function writeAllowed(config: PhaseControlConfig, filePath: string): boolean {
  if (artifactWriteAllowed(config, filePath)) return true;
  const allow = config.contract?.allowedScope?.canWriteOnly;
  if (!allow?.length) return true;
  const targetBase = basename(filePath);
  return allow.some((allowed) => targetBase === basename(allowed));
}

function shouldControl(config: PhaseControlConfig): boolean {
  return config.overwatch?.enabled === true && config.overwatch.mode !== "off";
}

function mode(config: PhaseControlConfig): "warn" | "enforce" {
  return config.overwatch?.mode === "warn" ? "warn" : "enforce";
}

function block(reason: string) {
  return { block: true, reason };
}

function normalizedCommand(command: string): string {
  return command.replace(/\s+/g, " ").trim();
}

function qaBroadCommand(command: string): boolean {
  const normalized = normalizedCommand(command);
  return /^(npm|pnpm|yarn)\s+(test|vitest)(\s+run)?$/i.test(normalized)
    || /^mix\s+test$/i.test(normalized)
    || /^cargo\s+test$/i.test(normalized)
    || /^go\s+test\s+\.\/\.\.\.$/i.test(normalized);
}

function hasExplicitSearchPath(command: string): boolean {
  return /\s(--glob|-g|src\/?|packages\/?|lib\/?|test\/?|tests\/?|docs\/?|\.ts\b|\.tsx\b|\.js\b|\.jsx\b|\.ex\b|\.exs\b|\.md\b)/i.test(command);
}

function broadDiscoveryCommand(command: string): boolean {
  const normalized = normalizedCommand(command);
  const recursiveGrep = /(^|\s)grep\s+[^|;]*\s-[^|;]*r/i.test(normalized) && !hasExplicitSearchPath(normalized);
  const unscopedRg = /(^|\s)rg(\s|$)/i.test(normalized) && !hasExplicitSearchPath(normalized);
  return /(^|\s)(find|fd)\s+(\.|\*|\/|$)/i.test(normalized)
    || /(^|\s)ls\s+(-[^\s]*R|.*\s-R)(\s|$)/i.test(normalized)
    || /(^|\s)tree(\s|$)/i.test(normalized)
    || /(^|\s)git\s+log\b.*\s--all\b/i.test(normalized)
    || recursiveGrep
    || unscopedRg;
}

function broadDiscoveryTool(tool: string, input: Record<string, unknown>): boolean {
  if (tool === "glob") return true;
  if (tool !== "grep") return false;
  const path = asString(input.path) ?? asString(input.glob) ?? asString(input.include);
  return !path;
}

function anyTestCommand(command: string): boolean {
  const normalized = normalizedCommand(command);
  return /(^|\s)(npm|pnpm|yarn)\s+(test|vitest)\b/i.test(normalized)
    || /(^|\s)npx\s+vitest\b/i.test(normalized)
    || /(^|\s)mix\s+test\b/i.test(normalized)
    || /(^|\s)cargo\s+test\b/i.test(normalized)
    || /(^|\s)go\s+test\b/i.test(normalized);
}

function configuredBlockedCommand(config: PhaseControlConfig, command: string): string | undefined {
  const normalized = normalizedCommand(command);
  for (const pattern of config.overwatch?.blockedCommands ?? []) {
    try {
      if (new RegExp(pattern, "i").test(normalized)) return pattern;
    } catch {
      if (normalized.includes(pattern)) return pattern;
    }
  }
  return undefined;
}

function steeringMessage(config: PhaseControlConfig, validation: ArtifactValidation): string {
  if (validation.valid) {
    return `Overwatch: ${config.phaseName} artifact is valid. Stop further tool use and finish this phase now.`;
  }
  const missing = [...validation.missingSections, ...validation.findings].join("; ");
  return `Overwatch: stop broad exploration. Write ${config.artifact ?? "the phase artifact"} now. Missing: ${missing || "required handoff details"}.`;
}

function deterministicPolicy(config: PhaseControlConfig, telemetry: PhaseTelemetry, event: ToolCallEventLike): { allow: true } | { allow: false; reason: string } {
  const tool = normalizeToolName(event.toolName);
  const input = event.input ?? {};
  const path = asString(input.path) ?? asString(input.file_path) ?? asString(input.filePath);
  const command = asString(input.command);
  const validation = validatePhaseArtifact(config);

  if (validation.valid) {
    return { allow: false, reason: steeringMessage(config, validation) };
  }

  if ((tool === "write" || tool === "edit") && path && !writeAllowed(config, path)) {
    return { allow: false, reason: `Overwatch: ${config.phaseName} may only write configured artifact files.` };
  }

  if (["developer", "qa"].includes(config.phaseName) && broadDiscoveryTool(tool, input)) {
    return { allow: false, reason: `Overwatch: ${config.phaseName} must use Explorer/Developer handoff targets, not broad discovery tools.` };
  }

  if (tool === "bash" && command) {
    const blockedPattern = configuredBlockedCommand(config, command);
    if (blockedPattern) {
      return { allow: false, reason: `Overwatch: command blocked for ${config.phaseName} by pattern ${blockedPattern}.` };
    }
    if (["developer", "qa"].includes(config.phaseName) && broadDiscoveryCommand(command)) {
      return { allow: false, reason: `Overwatch: ${config.phaseName} must not run broad repo discovery; use the handoff targets or report blocked.` };
    }
    if (config.phaseName === "developer" && anyTestCommand(command)) {
      return { allow: false, reason: "Overwatch: Developer must not run tests; write QA handoff with focused validation commands instead." };
    }
    if (config.phaseName === "qa" && qaBroadCommand(command)) {
      return { allow: false, reason: "Overwatch: QA may not run broad full-suite commands; run targeted validation only or write BLOCKED with rationale." };
    }
    const repeatedCommandLimit = config.overwatch?.repeatedCommandLimit ?? 3;
    const previousRuns = telemetry.summary().commandsRun.filter((previous) => normalizedCommand(previous) === normalizedCommand(command)).length;
    if (previousRuns >= repeatedCommandLimit) {
      return { allow: false, reason: `Overwatch: repeated command limit reached for ${config.phaseName}. Write ${config.artifact ?? "the phase artifact"} with current evidence or change strategy.` };
    }
  }

  if (config.phaseName === "documentation" && (tool === "write" || tool === "edit") && path && !artifactWriteAllowed(config, path) && !/(^|\/)docs\/|README\.md$|CLAUDE\.md$|AGENTS\.md$/i.test(path)) {
    return { allow: false, reason: "Overwatch: documentation phase may only edit documentation files or its configured report artifact." };
  }

  const summary = telemetry.summary();
  const maxSteers = config.overwatch?.maxSteersPerPhase ?? 3;
  const forceAfter = config.overwatch?.forceArtifactAfterSteers ?? 2;
  const forceAfterTools = config.overwatch?.forceArtifactAfterToolCalls ?? (config.phaseName === "explorer" ? 10 : undefined);
  const maxToolCalls = config.overwatch?.maxToolCalls;
  const isArtifactWrite = Boolean(path && (tool === "write" || tool === "edit") && artifactWriteAllowed(config, path));
  const nearMaxTurns = Boolean(config.maxTurns && summary.turns >= Math.max(1, config.maxTurns - 5));
  const readLikeCalls = (summary.toolCounts.read ?? 0) + (summary.toolCounts.grep ?? 0) + (summary.toolCounts.find ?? 0);
  const shouldForceArtifact = Boolean(
    config.artifact &&
    (
      nearMaxTurns ||
      (forceAfterTools !== undefined && summary.toolCalls >= forceAfterTools) ||
      (config.phaseName === "explorer" && readLikeCalls >= 10)
    ) &&
    summary.steers < maxSteers
  );
  if (shouldForceArtifact && !isArtifactWrite) {
    return { allow: false, reason: steeringMessage(config, validation) };
  }
  if (config.artifact && summary.steers >= forceAfter && !isArtifactWrite) {
    return { allow: false, reason: `Overwatch: no more unbounded work in ${config.phaseName}. Write ${config.artifact} with current evidence.` };
  }
  if (maxToolCalls !== undefined && summary.toolCalls >= maxToolCalls && !isArtifactWrite) {
    return { allow: false, reason: `Overwatch: ${config.phaseName} exceeded maxToolCalls (${maxToolCalls}). Finish or write ${config.artifact ?? "a handoff artifact"}.` };
  }

  return { allow: true };
}

export interface PhaseToolPolicy {
  beforeTool(toolName: string, input: Record<string, unknown>): string | undefined;
  afterTurn?(turn: number): void;
}

export function createPhaseToolPolicy(config: PhaseControlConfig, emit?: (event: { kind: "warning" | "update"; message: string; toolName?: string; argsPreview?: string }) => void): PhaseToolPolicy | undefined {
  if (!shouldControl(config)) return undefined;
  const telemetry = new PhaseTelemetry(config);
  return {
    afterTurn(turn: number): void {
      telemetry.recordTurn(turn);
    },
    beforeTool(toolName: string, input: Record<string, unknown>): string | undefined {
      const decision = deterministicPolicy(config, telemetry, { toolName, input });
      if (!decision.allow) {
        telemetry.deny(decision.reason);
        telemetry.steer(decision.reason);
        emit?.({ kind: "warning", message: decision.reason, toolName, argsPreview: JSON.stringify(input) });
        if (mode(config) === "enforce") return decision.reason;
      }
      telemetry.recordTool(toolName, input);
      return undefined;
    },
  };
}

export function createPhaseOverwatchExtension(config: PhaseControlConfig, emit?: (event: { kind: "warning" | "update"; message: string; toolName?: string; argsPreview?: string }) => void): ExtensionFactory | undefined {
  if (!shouldControl(config)) return undefined;
  const telemetry = new PhaseTelemetry(config);

  return (pi: ExtensionAPI) => {
    (pi as ExtensionAPI & { on: (event: "tool_call", handler: (event: ToolCallEventLike) => unknown) => void }).on("tool_call", async (event: ToolCallEventLike) => {
      const decision = deterministicPolicy(config, telemetry, event);
      if (decision.allow) return undefined;
      telemetry.deny(decision.reason);
      telemetry.steer(decision.reason);
      emit?.({ kind: "warning", message: decision.reason, toolName: event.toolName, argsPreview: JSON.stringify(event.input ?? {}) });
      if (mode(config) === "warn") return undefined;
      return block(decision.reason);
    });

    (pi as ExtensionAPI & { on: (event: "turn_end", handler: (event: { iteration?: unknown }) => unknown) => void }).on("turn_end", async (event: { iteration?: unknown }) => {
      const iteration = typeof event.iteration === "number" ? event.iteration : telemetry.turns + 1;
      telemetry.recordTurn(iteration);
    });

    pi.on("tool_execution_start", async (event: { toolName: string; args?: unknown }) => {
      const args = event.args && typeof event.args === "object" ? event.args as Record<string, unknown> : {};
      telemetry.recordTool(event.toolName, args);
    });
  };
}

export function acceptBudgetLimitedCompletion(config: PhaseControlConfig, errorMessage?: string): { accept: boolean; reason?: string; validation: ArtifactValidation } {
  const validation = validatePhaseArtifact(config);
  const isBudgetStop = /maxTurns|budget|aborted|terminated/i.test(errorMessage ?? "");
  const accept = Boolean(config.overwatch?.continueIfArtifactValidOnBudgetStop && isBudgetStop && validation.valid);
  return {
    accept,
    reason: accept ? `${config.phaseName} stopped by budget after producing valid artifact` : undefined,
    validation,
  };
}
