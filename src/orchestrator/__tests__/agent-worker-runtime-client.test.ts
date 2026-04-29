import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

describe("agent-worker runtime task client threading", () => {
  it("threads config.projectId into every runtime task-client call", () => {
    const sourcePath = fileURLToPath(new URL("../agent-worker.ts", import.meta.url));
    const source = readFileSync(sourcePath, "utf8");

    expect(source).toContain("async function createRuntimeTaskClient(projectPath: string, registeredProjectId?: string)");
    expect(source.match(/createRuntimeTaskClient\(pipelineProjectPath, registeredProjectId\)/g)).toHaveLength(3);
  });

  it("resolves worker databaseUrl from storeProjectPath so inferred registered Postgres stays enabled", () => {
    const sourcePath = fileURLToPath(new URL("../agent-worker.ts", import.meta.url));
    const source = readFileSync(sourcePath, "utf8");

    expect(source).toContain("const storeProjectPath = configProjectPath ?? inferProjectPathFromWorkspacePath(worktreePath);");
    expect(source).toContain("const databaseUrl = resolveProjectDatabaseUrl(storeProjectPath);");
    expect(source).not.toContain("const databaseUrl = resolveProjectDatabaseUrl(config.projectPath);");
  });

  it("uses the runtime task client callback for native phase updates instead of NativeTaskStore(store.getDb())", () => {
    const sourcePath = fileURLToPath(new URL("../agent-worker.ts", import.meta.url));
    const source = readFileSync(sourcePath, "utf8");

    expect(source).not.toContain("new NativeTaskStore(store.getDb())");
    expect(source).toContain("const { taskClient: runtimeTaskClient, backendType: runtimeTaskBackend } = await createTaskClient(");
    expect(source).toContain("async onTaskPhaseChange(taskId, phaseName)");
    expect(source).toContain('if (runtimeTaskBackend !== "native" || !taskId) return;');
    expect(source).toContain("try {");
    expect(source).toContain("await runtimeTaskClient.update(taskId, { status: phaseName });");
    expect(source).toContain("native status update failed (non-fatal)");
  });

  it("threads a registered observability writer into pipeline execution without changing local fallback wiring", () => {
    const sourcePath = fileURLToPath(new URL("../agent-worker.ts", import.meta.url));
    const source = readFileSync(sourcePath, "utf8");
    const pipelineSourcePath = fileURLToPath(new URL("../pipeline-executor.ts", import.meta.url));
    const pipelineSource = readFileSync(pipelineSourcePath, "utf8");

    expect(source).toContain("await runPipeline(config, store, localStore, logFile, notifyClient, agentMailClient, registeredReadStore, registeredProjectId);");
    expect(source).toContain("const registeredObservabilityWriter: PipelineObservabilityWriter | undefined = registeredReadStore");
    expect(source).toContain("await registeredReadStore.updateRunProgress(config.runId, progress);");
    expect(source).toContain("await registeredReadStore.logEvent(registeredProjectId!, eventType, data, config.runId);");
    expect(source).toContain("observabilityWriter: registeredObservabilityWriter,");
    expect(pipelineSource).toContain('logEvent?: (eventType: "phase-start" | "complete" | "heartbeat", data: Record<string, unknown>) => Promise<void> | void;');
    expect(pipelineSource).toContain("ctx.heartbeatManager?.setSeedId(seedId);");
    expect(pipelineSource).toContain("createHeartbeatManager(heartbeatConfig, store, config.projectId, config.runId, config.vcsBackend, worktreePath, ctx.observabilityWriter)");
    expect(source).toContain("if (observabilityWriter?.updateProgress) {");
    expect(source).toContain("void Promise.resolve(observabilityWriter.updateProgress(progress));");
    expect(source).toContain("pipeline-observability");
  });

  it("routes registered rate-limit telemetry through the dual-write store before local fallback", () => {
    const sourcePath = fileURLToPath(new URL("../agent-worker.ts", import.meta.url));
    const source = readFileSync(sourcePath, "utf8");

    expect(source).toContain("import { createDualWriteStore } from \"./rate-limit-dual-write.js\";");
    expect(source).toContain("const registeredProjectId = await resolveRegisteredProjectIdForPath(storeProjectPath, databaseUrl);");
    expect(source).toContain("createDualWriteStore(localStore, pgStore, true, log)");
    expect(source).not.toContain("store.logRateLimitEvent(config.projectId, model, phase, error, retryAfterSeconds, config.runId);");
    expect(source).toContain("sendMail(agentMailClient, \"foreman\", \"rate-limit-alert\",");
  });
});
