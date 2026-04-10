import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { runWithPiSdk, type PiRunOptions, type PiRunResult } from "./pi-sdk-runner.js";
import type { AgentRole } from "./execution-engine.js";

export interface PhaseRunnerConfig {
  modulePath: string;
  exportName?: string;
  optionsPath?: string;
}

export interface PhaseRunnerMetadata {
  phaseName: string;
  role: Exclude<AgentRole, "lead" | "worker" | "sentinel">;
  mode: "single" | "pipeline" | "troubleshooter";
  runId: string;
  projectId: string;
  seedId: string;
  seedTitle: string;
  seedDescription?: string;
  seedComments?: string;
  seedType?: string;
  seedLabels?: string[];
  seedPriority?: string;
  worktreePath: string;
  projectPath?: string;
  workflowName?: string;
  targetBranch?: string;
  taskId?: string | null;
}

export interface PhaseRunnerRequest {
  metadata: PhaseRunnerMetadata;
  pi: PiRunOptions;
}

export type PhaseRunner = (request: PhaseRunnerRequest) => Promise<PiRunResult>;

export interface PhaseRunnerFactoryContext {
  projectRoot: string;
  config: PhaseRunnerConfig;
}

interface PhaseRunnerModule {
  createPhaseRunner?: (ctx: PhaseRunnerFactoryContext) => PhaseRunner | Promise<PhaseRunner>;
}

export function createDefaultPhaseRunner(): PhaseRunner {
  return async ({ pi }) => runWithPiSdk(pi);
}

function normalizeModulePath(modulePath: string, projectRoot: string): string {
  if (modulePath.startsWith("file://")) {
    return modulePath;
  }
  if (modulePath.startsWith(".") || modulePath.startsWith("/")) {
    const resolvedPath = modulePath.startsWith("/") ? modulePath : resolve(projectRoot, modulePath);
    return pathToFileURL(resolvedPath).href;
  }
  return modulePath;
}

export async function createConfiguredPhaseRunner(
  config: PhaseRunnerConfig | undefined,
  projectRoot: string,
): Promise<PhaseRunner> {
  if (!config?.modulePath) {
    return createDefaultPhaseRunner();
  }

  const specifier = normalizeModulePath(config.modulePath, projectRoot);
  const loaded = await import(specifier) as PhaseRunnerModule & Record<string, unknown>;
  const exportName = config.exportName ?? "createPhaseRunner";
  const factory = loaded[exportName];

  if (typeof factory !== "function") {
    throw new Error(
      `Phase runner module '${config.modulePath}' must export function '${exportName}'`,
    );
  }

  const createRunner = factory as NonNullable<PhaseRunnerModule["createPhaseRunner"]>;
  const runner = await createRunner({
    projectRoot,
    config,
  });

  if (typeof runner !== "function") {
    throw new Error(
      `Phase runner factory '${exportName}' from '${config.modulePath}' must return a function`,
    );
  }

  return runner;
}
