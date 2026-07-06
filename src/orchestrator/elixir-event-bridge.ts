import { ElixirServerClient } from "../lib/elixir-server-client.js";
import { ElixirServerManager } from "../lib/elixir-server-manager.js";

let clientPromise: Promise<ElixirServerClient> | undefined;

function client(): Promise<ElixirServerClient> {
  clientPromise ??= new ElixirServerManager().ensureRunning().then((status) => (
    new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN)
  ));
  return clientPromise;
}

function eventTypeForWorkerProtocol(eventType: string): string {
  return eventType.replace(/-/g, "_");
}

export async function writeElixirOrchestrationEvent(input: {
  runId: string;
  projectId: string;
  eventType: string;
  payload: Record<string, unknown>;
}): Promise<void> {
  const phaseId = typeof input.payload.phase === "string"
    ? input.payload.phase
    : typeof input.payload.phase_id === "string"
      ? input.payload.phase_id
      : input.eventType;

  await (await client()).sendWorkerEvent({
    run_id: input.runId,
    project_id: input.projectId,
    phase_id: phaseId,
    worker_id: `node-orchestration:${input.eventType}:${Date.now()}:${Math.random().toString(36).slice(2)}`,
    type: eventTypeForWorkerProtocol(input.eventType),
    sequence: 1,
    status: typeof input.payload.status === "string" ? input.payload.status : undefined,
    message: typeof input.payload.message === "string"
      ? input.payload.message
      : typeof input.payload.reason === "string"
        ? input.payload.reason
        : undefined,
    details: input.payload,
  });
}
