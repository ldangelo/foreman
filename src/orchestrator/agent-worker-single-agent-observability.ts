import type { RunProgress } from "../lib/store.js";

type SingleAgentProgressWriter = {
  updateProgress?(progress: RunProgress): Promise<void> | void;
};

type SingleAgentEventWriter = {
  logEvent?(eventType: "complete" | "fail" | "stuck", data: Record<string, unknown>): Promise<void> | void;
};

function isProgress(value: unknown): value is RunProgress {
  return typeof value === "object" && value !== null && "toolCalls" in value && "costUsd" in value;
}

export async function writeSingleAgentProgress(
  writer: SingleAgentProgressWriter | undefined,
  runIdOrRegistered: string | unknown,
  progressOrRunId: RunProgress | string,
  logOrProgress: ((msg: string) => void) | RunProgress,
  maybeLog?: (msg: string) => void,
): Promise<void> {
  const progress = isProgress(progressOrRunId) ? progressOrRunId : isProgress(logOrProgress) ? logOrProgress : undefined;
  const log = typeof logOrProgress === "function" ? logOrProgress : maybeLog ?? (() => undefined);
  try {
    await Promise.resolve(writer?.updateProgress?.(progress as RunProgress));
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[agent-worker] single-agent progress event failed (non-fatal): ${msg}`);
  }
}

export async function writeSingleAgentTerminalEvent(
  writer: SingleAgentEventWriter | undefined,
  projectIdOrRegistered: string | unknown,
  runIdOrProjectId: string,
  eventTypeOrRunId: "complete" | "fail" | "stuck" | string,
  dataOrEventType: Record<string, unknown> | "complete" | "fail" | "stuck",
  logOrData: ((msg: string) => void) | Record<string, unknown>,
  maybeLog?: (msg: string) => void,
): Promise<void> {
  const legacy = typeof dataOrEventType === "string";
  const eventType = (legacy ? dataOrEventType : eventTypeOrRunId) as "complete" | "fail" | "stuck";
  const data = (legacy ? logOrData : dataOrEventType) as Record<string, unknown>;
  const log = ((legacy ? maybeLog : logOrData) as ((msg: string) => void) | undefined) ?? (() => undefined);
  try {
    await Promise.resolve(writer?.logEvent?.(eventType, data));
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[agent-worker] single-agent terminal event failed (non-fatal): ${msg}`);
  }
}
