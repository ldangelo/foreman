import { runWithPiSdk } from "./pi-sdk-runner.js";
function getRuntimeMode() {
    return process.env.FOREMAN_RUNTIME_MODE?.trim().toLowerCase() || "normal";
}
async function loadConfiguredRunner() {
    const runtimeMode = getRuntimeMode();
    if (runtimeMode !== "test") {
        return (opts) => runWithPiSdk(opts);
    }
    const modulePath = process.env.FOREMAN_PHASE_RUNNER_MODULE;
    if (!modulePath) {
        throw new Error("FOREMAN_RUNTIME_MODE=test requires FOREMAN_PHASE_RUNNER_MODULE to be set");
    }
    const exportName = process.env.FOREMAN_PHASE_RUNNER_EXPORT || "runDeterministicPhase";
    const loaded = await import(modulePath);
    const runner = loaded[exportName];
    if (typeof runner !== "function") {
        throw new Error(`Configured phase runner export '${exportName}' was not found in ${modulePath}`);
    }
    return runner;
}
export async function runPhaseSession(opts) {
    const runner = await loadConfiguredRunner();
    return runner(opts);
}
//# sourceMappingURL=phase-runner.js.map