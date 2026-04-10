import { BeadsRustClient } from "../lib/beads-rust.js";
import { normalizePriority } from "../lib/priority.js";
import { ProjectRegistry, type ProjectEntry } from "../lib/project-registry.js";
import { ForemanStore, type NativeTask } from "../lib/store.js";
import type { Issue } from "../lib/task-client.js";

export interface ProjectSchedulingCandidate {
  project: ProjectEntry;
  readyCount: number;
  bestPriority: number;
  oldestReadyAt: string | null;
  activeAgents: number;
  maxNewSlots: number;
  source: "native" | "beads" | "none";
  unavailableReason?: string;
}

export interface ProjectSchedulingDecision {
  project: ProjectEntry;
  grantedSlots: number;
  reason: string;
  candidate: ProjectSchedulingCandidate;
}

function summarizeNativeTasks(tasks: NativeTask[]): Pick<ProjectSchedulingCandidate, "readyCount" | "bestPriority" | "oldestReadyAt" | "source"> {
  if (tasks.length === 0) {
    return { readyCount: 0, bestPriority: 4, oldestReadyAt: null, source: "native" };
  }

  const bestPriority = Math.min(...tasks.map((task) => normalizePriority(task.priority)));
  const oldestReadyAt = tasks
    .map((task) => task.created_at)
    .sort((a, b) => new Date(a).getTime() - new Date(b).getTime())[0] ?? null;

  return {
    readyCount: tasks.length,
    bestPriority,
    oldestReadyAt,
    source: "native",
  };
}

function summarizeIssues(issues: Issue[]): Pick<ProjectSchedulingCandidate, "readyCount" | "bestPriority" | "oldestReadyAt" | "source"> {
  if (issues.length === 0) {
    return { readyCount: 0, bestPriority: 4, oldestReadyAt: null, source: "beads" };
  }

  const bestPriority = Math.min(...issues.map((issue) => normalizePriority(issue.priority)));
  const oldestReadyAt = issues
    .map((issue) => issue.created_at)
    .sort((a, b) => new Date(a).getTime() - new Date(b).getTime())[0] ?? null;

  return {
    readyCount: issues.length,
    bestPriority,
    oldestReadyAt,
    source: "beads",
  };
}

export async function collectProjectSchedulingCandidate(project: ProjectEntry): Promise<ProjectSchedulingCandidate> {
  const store = ForemanStore.forProject(project.path);
  try {
    const projectRow = store.getProjectByPath(project.path);
    const activeAgents = projectRow ? store.getActiveRuns(projectRow.id).length : 0;

    if (store.hasNativeTasks()) {
      const readyTasks = store.getReadyTasks();
      const summary = summarizeNativeTasks(readyTasks);
      return {
        project,
        activeAgents,
        maxNewSlots: summary.readyCount,
        ...summary,
      };
    }

    try {
      const brClient = new BeadsRustClient(project.path);
      const readyIssues = await brClient.ready();
      const summary = summarizeIssues(readyIssues);
      return {
        project,
        activeAgents,
        maxNewSlots: summary.readyCount,
        ...summary,
      };
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      return {
        project,
        readyCount: 0,
        bestPriority: 4,
        oldestReadyAt: null,
        activeAgents,
        maxNewSlots: 0,
        source: "none",
        unavailableReason: message,
      };
    }
  } finally {
    store.close();
  }
}

function compareCandidates(a: ProjectSchedulingCandidate, b: ProjectSchedulingCandidate): number {
  if (a.bestPriority !== b.bestPriority) {
    return a.bestPriority - b.bestPriority;
  }
  if (a.activeAgents !== b.activeAgents) {
    return a.activeAgents - b.activeAgents;
  }
  const aOldest = a.oldestReadyAt ? new Date(a.oldestReadyAt).getTime() : Number.POSITIVE_INFINITY;
  const bOldest = b.oldestReadyAt ? new Date(b.oldestReadyAt).getTime() : Number.POSITIVE_INFINITY;
  if (aOldest !== bOldest) {
    return aOldest - bOldest;
  }
  if (a.readyCount !== b.readyCount) {
    return b.readyCount - a.readyCount;
  }
  return new Date(a.project.addedAt).getTime() - new Date(b.project.addedAt).getTime();
}

function explainSelection(candidate: ProjectSchedulingCandidate): string {
  const parts = [`priority P${candidate.bestPriority}`];
  parts.push(candidate.activeAgents === 0 ? "no active agents" : `${candidate.activeAgents} active agent(s)`);
  if (candidate.oldestReadyAt) {
    parts.push(`oldest ready work ${candidate.oldestReadyAt}`);
  }
  return `Selected for fairness: ${parts.join(", ")}.`;
}

export function planProjectDispatches(
  candidates: ProjectSchedulingCandidate[],
  maxAgents: number,
): ProjectSchedulingDecision[] {
  const sorted = [...candidates].sort(compareCandidates);
  const totalActiveAgents = sorted.reduce((sum, candidate) => sum + candidate.activeAgents, 0);
  let remainingSlots = Math.max(0, maxAgents - totalActiveAgents);
  const granted = new Map<string, number>();

  while (remainingSlots > 0) {
    const next = sorted.find((candidate) => {
      const alreadyGranted = granted.get(candidate.project.path) ?? 0;
      return candidate.maxNewSlots > alreadyGranted;
    });
    if (!next) break;
    granted.set(next.project.path, (granted.get(next.project.path) ?? 0) + 1);
    remainingSlots -= 1;
    sorted.sort((a, b) => {
      const grantDelta = (granted.get(a.project.path) ?? 0) - (granted.get(b.project.path) ?? 0);
      return grantDelta !== 0 ? grantDelta : compareCandidates(a, b);
    });
  }

  return candidates
    .map((candidate) => {
      const grantedSlots = granted.get(candidate.project.path) ?? 0;
      let reason: string;
      if (candidate.unavailableReason) {
        reason = `Scheduler skipped this project because ready work could not be inspected: ${candidate.unavailableReason}`;
      } else if (candidate.readyCount === 0) {
        reason = "Scheduler found no ready work for this project.";
      } else if (grantedSlots > 0) {
        reason = explainSelection(candidate);
      } else {
        reason = "Scheduler deferred this project because fleet capacity was allocated to higher-priority or less-served projects in this pass.";
      }
      return {
        project: candidate.project,
        grantedSlots,
        reason,
        candidate,
      };
    })
    .sort((a, b) => compareCandidates(a.candidate, b.candidate));
}

export async function collectAllProjectSchedulingCandidates(
  registry: Pick<ProjectRegistry, "list"> = new ProjectRegistry(),
): Promise<ProjectSchedulingCandidate[]> {
  const projects = registry.list();
  const candidates: ProjectSchedulingCandidate[] = [];
  for (const project of projects) {
    candidates.push(await collectProjectSchedulingCandidate(project));
  }
  return candidates;
}
