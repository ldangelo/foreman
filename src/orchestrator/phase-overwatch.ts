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

  if (config.phaseName === "qa" || config.phaseName === "reviewer" || config.phaseName === "finalize") {
    if (!/\b(PASS|FAIL|BLOCKED|VERDICT)\b/i.test(content)) {
      result.findings.push("Expected explicit verdict/status");
    }
  }

  result.valid = result.missingSections.length === 0 && result.findings.length === 0;
  return result;
}

function defaultRequiredSections(phaseName: string): string[] {
  switch (phaseName) {
    case "explorer":
      return ["Summary", "Likely edit targets", "Test targets", "Risks"];
    case "qa":
      return ["Verdict", "Commands", "Findings"];
    case "reviewer":
      return ["Verdict", "Findings"];
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

function writeAllowed(config: PhaseControlConfig, filePath: string): boolean {
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

function qaBroadCommand(command: string): boolean {
  const normalized = command.replace(/\s+/g, " ").trim();
  return /^(npm|pnpm|yarn)\s+(test|vitest)(\s+run)?$/i.test(normalized)
    || /^mix\s+test$/i.test(normalized)
    || /^cargo\s+test$/i.test(normalized)
    || /^go\s+test\s+\.\/\.\.\.$/i.test(normalized);
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

  if ((tool === "read" || tool === "grep" || tool === "find" || tool === "ls") && validation.valid) {
    return { allow: false, reason: steeringMessage(config, validation) };
  }

  if ((tool === "write" || tool === "edit") && path && !writeAllowed(config, path)) {
    return { allow: false, reason: `Overwatch: ${config.phaseName} may only write configured artifact files.` };
  }

  if (config.phaseName === "qa" && tool === "bash" && command && qaBroadCommand(command)) {
    return { allow: false, reason: "Overwatch: QA may not run broad full-suite commands; run targeted validation only or write BLOCKED with rationale." };
  }

  if (config.phaseName === "documentation" && (tool === "write" || tool === "edit") && path && !/(^|\/)docs\/|README\.md$|CLAUDE\.md$|AGENTS\.md$/i.test(path)) {
    return { allow: false, reason: "Overwatch: documentation phase may only edit documentation files." };
  }

  const maxSteers = config.overwatch?.maxSteersPerPhase ?? 3;
  const forceAfter = config.overwatch?.forceArtifactAfterSteers ?? 2;
  const readLikeCalls = (telemetry.summary().toolCounts.read ?? 0) + (telemetry.summary().toolCounts.grep ?? 0) + (telemetry.summary().toolCounts.find ?? 0);
  if (config.phaseName === "explorer" && readLikeCalls >= 10 && telemetry.summary().steers < maxSteers) {
    return { allow: false, reason: steeringMessage(config, validation) };
  }
  if (config.phaseName === "explorer" && telemetry.summary().steers >= forceAfter && (tool === "read" || tool === "grep" || tool === "find")) {
    return { allow: false, reason: `Overwatch: no more investigation. Write ${config.artifact ?? "the artifact"} with current evidence.` };
  }

  return { allow: true };
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
