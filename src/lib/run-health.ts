import { PIPELINE_TIMEOUTS } from "./config.js";
import type { Run, RunProgress } from "./store.js";

export interface SdkRunHealth {
  isSdkRun: boolean;
  isStale: boolean;
  lastActivityAt: string | null;
  ageMs: number | null;
  staleThresholdHours: number;
}

export function isSdkBasedRun(sessionKey: string | null): boolean {
  return sessionKey?.startsWith("foreman:sdk:") ?? false;
}

function resolveRunActivityTimestamp(run: Run, progress: RunProgress | null): string | null {
  return progress?.lastActivity ?? run.started_at ?? run.created_at ?? null;
}

export function getSdkRunHealth(
  run: Run,
  progress: RunProgress | null,
  now = Date.now(),
  staleThresholdHours = PIPELINE_TIMEOUTS.staleRunHours,
): SdkRunHealth {
  const sdkRun = isSdkBasedRun(run.session_key);
  if (!sdkRun || run.status !== "running") {
    return {
      isSdkRun: sdkRun,
      isStale: false,
      lastActivityAt: null,
      ageMs: null,
      staleThresholdHours,
    };
  }

  const lastActivityAt = resolveRunActivityTimestamp(run, progress);
  if (!lastActivityAt) {
    return {
      isSdkRun: true,
      isStale: true,
      lastActivityAt: null,
      ageMs: null,
      staleThresholdHours,
    };
  }

  const activityMs = new Date(lastActivityAt).getTime();
  if (Number.isNaN(activityMs)) {
    return {
      isSdkRun: true,
      isStale: true,
      lastActivityAt,
      ageMs: null,
      staleThresholdHours,
    };
  }

  const ageMs = Math.max(0, now - activityMs);
  const staleThresholdMs = staleThresholdHours * 60 * 60 * 1000;

  return {
    isSdkRun: true,
    isStale: ageMs > staleThresholdMs,
    lastActivityAt,
    ageMs,
    staleThresholdHours,
  };
}
