import { writeFile, mkdir, open } from "node:fs/promises";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

import type { VcsBackend } from "../lib/vcs/index.js";
import type { PhaseRunnerConfig } from "./phase-runner.js";

export type AgentRole = "lead" | "explorer" | "developer" | "qa" | "reviewer" | "finalize" | "worker" | "sentinel" | "troubleshooter";
export type ExecutionPhaseRole = Exclude<AgentRole, "lead" | "worker" | "sentinel">;

export interface WorkerConfig {
  runId: string;
  projectId: string;
  seedId: string;
  seedTitle: string;
  seedDescription?: string;
  seedComments?: string;
  model: string;
  worktreePath: string;
  projectPath?: string;
  prompt: string;
  env: Record<string, string>;
  resume?: string;
  pipeline?: boolean;
  skipExplore?: boolean;
  skipReview?: boolean;
  dbPath?: string;
  seedType?: string;
  seedLabels?: string[];
  seedPriority?: string;
  /** Override integration branch for auto-merge after finalize. */
  targetBranch?: string;
  taskId?: string | null;
  epicTasks?: import("./pipeline-executor.js").EpicTask[];
  groupedTasks?: import("./pipeline-executor.js").EpicTask[];
  epicId?: string;
  groupedParentId?: string;
  groupedParentType?: string;
  phaseRunner?: PhaseRunnerConfig;
}

export interface SpawnResult {}

export interface SpawnStrategy {
  spawn(config: WorkerConfig): Promise<SpawnResult>;
}

function resolveWorkerPaths(homeDir?: string): { tsxBin: string; workerScript: string; logDir: string } {
  const __filename = fileURLToPath(import.meta.url);
  const __dirname = dirname(__filename);
  const projectRoot = join(__dirname, "..", "..");
  return {
    tsxBin: join(projectRoot, "node_modules", ".bin", "tsx"),
    workerScript: join(__dirname, "agent-worker.js"),
    logDir: join(homeDir ?? process.env.HOME ?? "/tmp", ".foreman", "logs"),
  };
}

function log(msg: string): void {
  const ts = new Date().toISOString().slice(11, 23);
  console.error(`[foreman ${ts}] ${msg}`);
}

export class DetachedSpawnStrategy implements SpawnStrategy {
  async spawn(config: WorkerConfig): Promise<SpawnResult> {
    const homeDir = config.env.HOME ?? process.env.HOME ?? "/tmp";
    const { tsxBin, workerScript, logDir } = resolveWorkerPaths(homeDir);

    const configDir = join(homeDir, ".foreman", "tmp");
    await mkdir(configDir, { recursive: true });
    const configPath = join(configDir, `worker-${config.runId}.json`);
    await writeFile(configPath, JSON.stringify(config), "utf-8");

    await mkdir(logDir, { recursive: true });
    const outFd = await open(join(logDir, `${config.runId}.out`), "w");
    const errFd = await open(join(logDir, `${config.runId}.err`), "w");

    const spawnEnv: Record<string, string | undefined> = { ...config.env };
    delete spawnEnv.CLAUDECODE;

    const __filename = fileURLToPath(import.meta.url);
    const projectRoot = join(dirname(__filename), "..", "..");
    const child = spawn(tsxBin, [workerScript, configPath], {
      detached: true,
      stdio: ["ignore", outFd.fd, errFd.fd],
      cwd: projectRoot,
      env: spawnEnv,
    });

    child.unref();
    await outFd.close();
    await errFd.close();

    log(`  Worker pid=${child.pid} for ${config.seedId}`);
    return {};
  }
}

export async function spawnWorkerProcess(config: WorkerConfig): Promise<SpawnResult> {
  return new DetachedSpawnStrategy().spawn(config);
}

export function buildWorkerEnv(
  telemetry: boolean | undefined,
  seedId: string,
  runId: string,
  model: string,
  notifyUrl?: string,
  vcsBackend?: VcsBackend,
): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined && key !== "CLAUDECODE") {
      env[key] = value;
    }
  }
  const home = process.env.HOME ?? "/home/nobody";
  env.PATH = `${home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:${env.PATH ?? ""}`;

  if (notifyUrl) {
    env.FOREMAN_NOTIFY_URL = notifyUrl;
  }
  if (vcsBackend?.name) {
    env.FOREMAN_VCS_BACKEND = vcsBackend.name;
  }
  if (telemetry) {
    env.CLAUDE_CODE_ENABLE_TELEMETRY = "1";
    env.OTEL_RESOURCE_ATTRIBUTES = [
      process.env.OTEL_RESOURCE_ATTRIBUTES,
      `foreman.seed_id=${seedId}`,
      `foreman.run_id=${runId}`,
      `foreman.model=${model}`,
    ].filter(Boolean).join(",");
  }

  return env;
}

export function resolvePhaseRunnerConfigFromEnv(): PhaseRunnerConfig | undefined {
  const modulePath = process.env.FOREMAN_PHASE_RUNNER_MODULE?.trim();
  if (!modulePath) return undefined;
  return {
    modulePath,
    exportName: process.env.FOREMAN_PHASE_RUNNER_EXPORT?.trim() || undefined,
    optionsPath: process.env.FOREMAN_PHASE_RUNNER_OPTIONS_PATH?.trim() || undefined,
  };
}
