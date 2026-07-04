import type { RunProgress } from "../lib/store.js";

type MarkStuckWriter = {
  updateProgress?(progress: RunProgress): Promise<void> | void;
  logEvent?(eventType: "stuck" | "fail", data: Record<string, unknown>): Promise<void> | void;
};

function isProgress(value: unknown): value is RunProgress {
  return typeof value === "object" && value !== null && "toolCalls" in value && "costUsd" in value;
}

export async function writeMarkStuckProgress(
  writer: MarkStuckWriter | undefined,
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
    log(`[markStuck] progress event failed (non-fatal): ${msg}`);
  }
}

export async function writeMarkStuckEvent(
  writer: MarkStuckWriter | undefined,
  projectIdOrRegistered: string | unknown,
  runIdOrProjectId: string,
  eventTypeOrRunId: "stuck" | "fail" | string,
  dataOrEventType: Record<string, unknown> | "stuck" | "fail",
  logOrData: ((msg: string) => void) | Record<string, unknown>,
  maybeLog?: (msg: string) => void,
): Promise<void> {
  const legacy = typeof dataOrEventType === "string";
  const eventType = (legacy ? dataOrEventType : eventTypeOrRunId) as "stuck" | "fail";
  const data = (legacy ? logOrData : dataOrEventType) as Record<string, unknown>;
  const log = ((legacy ? maybeLog : logOrData) as ((msg: string) => void) | undefined) ?? (() => undefined);
  try {
    await Promise.resolve(writer?.logEvent?.(eventType, data));
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[markStuck] ${eventType} event failed (non-fatal): ${msg}`);
  }
}
