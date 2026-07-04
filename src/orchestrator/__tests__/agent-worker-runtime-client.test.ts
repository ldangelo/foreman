import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

describe("agent-worker runtime task client threading", () => {
  const sourcePath = fileURLToPath(new URL("../agent-worker.ts", import.meta.url));
  const source = readFileSync(sourcePath, "utf8");

  it("threads config.projectId into every runtime task-client call", () => {
    expect(source).toContain("async function createRuntimeTaskClient(projectPath: string, registeredProjectId?: string)");
    const registeredCalls = source.match(/createRuntimeTaskClient\(pipelineProjectPath, registeredProjectId\)/g) ?? [];
    expect(registeredCalls.length).toBeGreaterThanOrEqual(2);
    expect(source).not.toContain("createRuntimeTaskClient(pipelineProjectPath)");
  });

  it("does not initialize Postgres or inject DATABASE_URL in the worker", () => {
    expect(source).not.toContain("resolveProjectDatabaseUrl");
    expect(source).not.toContain("initPool");
    expect(source).not.toContain("PostgresAdapter");
    expect(source).not.toContain("PostgresStore");
    expect(source).not.toContain("createDualWriteStore");
    expect(source).not.toContain("ForemanStore.forProject");
    expect(source).not.toContain("autoMerge(");
  });

  it("uses the runtime task client callback for native phase updates instead of direct stores", () => {
    expect(source).not.toContain("new NativeTaskStore(store.getDb())");
    expect(source).toContain("const { taskClient: runtimeTaskClient, backendType: runtimeTaskBackend } = await createTaskClient(");
    expect(source).toContain("async onTaskPhaseChange(taskId, phaseName)");
    expect(source).toContain('if (runtimeTaskBackend !== "native" || !taskId) return;');
    expect(source).toContain("await runtimeTaskClient.update(taskId, { status: nativeStatus });");
  });

  it("writes registered observability through Elixir worker events only", () => {
    expect(source).toContain("createElixirWorkerObservabilityWriter(config, eventProjectId)");
    expect(source).toContain("await writer.logEvent?.(eventType, data)");
    expect(source).toContain("observabilityWriter: registeredObservabilityWriter,");
    expect(source).not.toContain("registeredReadStore.updateRunProgress");
    expect(source).not.toContain("registeredReadStore.logEvent");
  });
});
