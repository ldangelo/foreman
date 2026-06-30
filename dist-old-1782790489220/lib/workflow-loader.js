/**
 * Workflow configuration loader.
 *
 * Loads and validates workflow YAML files from:
 *   1. Explicit absolute or project-relative YAML path
 *   2. ~/.foreman/workflows/{name}.yaml              (global override)
 *   3. Bundled defaults in src/defaults/workflows/{name}.yaml
 *
 * Workflow files define the ordered phase sequence for a pipeline run,
 * along with per-phase configuration (model, maxTurns, retryOnFail, etc.).
 *
 * @example
 * ```yaml
 * name: default
 * phases:
 *   - name: explorer
 *     prompt: explorer.md
 *     model: haiku
 *     maxTurns: 30
 *     skipIfArtifact: EXPLORER_REPORT.md
 *   - name: developer
 *     prompt: developer.md
 *     model: sonnet
 *     maxTurns: 80
 *   - name: qa
 *     prompt: qa.md
 *     model: sonnet
 *     maxTurns: 30
 *     retryOnFail: 2
 *   - name: reviewer
 *     prompt: reviewer.md
 *     model: sonnet
 *     maxTurns: 20
 *   - name: finalize
 *     builtin: true
 * ```
 */
import { readFileSync, existsSync, mkdirSync, copyFileSync, readdirSync, } from "node:fs";
import { join, dirname, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";
import { load as yamlLoad } from "js-yaml";
import { getForemanHomePath } from "./foreman-paths.js";
// ── Constants ─────────────────────────────────────────────────────────────────
/** Bundled workflow defaults directory (relative to this source file). */
const BUNDLED_WORKFLOWS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "defaults", "workflows");
/** Known workflow names with bundled defaults. */
export const BUNDLED_WORKFLOW_NAMES = [
    "default",
    "quick",
    "smoke",
    "epic",
    "bug",
    "task",
    "feature",
    "chore",
    "docs",
    "question",
];
// ── Validation ────────────────────────────────────────────────────────────────
/**
 * Error thrown when a workflow config file is missing or invalid.
 */
export class WorkflowConfigError extends Error {
    workflowName;
    reason;
    constructor(workflowName, reason) {
        super(`Workflow config error for '${workflowName}': ${reason}. ` +
            `Run 'foreman init' or 'foreman doctor --fix' to reinstall.`);
        this.workflowName = workflowName;
        this.reason = reason;
        this.name = "WorkflowConfigError";
    }
}
function isRecord(v) {
    return typeof v === "object" && v !== null && !Array.isArray(v);
}
/**
 * Validate and coerce raw YAML parse output into a WorkflowConfig.
 *
 * @throws WorkflowConfigError if the YAML is structurally invalid.
 */
export function validateWorkflowConfig(raw, workflowName) {
    if (!isRecord(raw)) {
        throw new WorkflowConfigError(workflowName, "must be a YAML object");
    }
    const name = typeof raw["name"] === "string" ? raw["name"] : workflowName;
    // ── Parse optional setup block ─────────────────────────────────────────────
    let setup;
    if (raw["setup"] !== undefined) {
        if (!Array.isArray(raw["setup"])) {
            throw new WorkflowConfigError(workflowName, "'setup' must be an array");
        }
        setup = [];
        for (let i = 0; i < raw["setup"].length; i++) {
            const s = raw["setup"][i];
            if (!isRecord(s)) {
                throw new WorkflowConfigError(workflowName, `setup[${i}] must be an object`);
            }
            if (typeof s["command"] !== "string" || !s["command"]) {
                throw new WorkflowConfigError(workflowName, `setup[${i}].command must be a non-empty string`);
            }
            const step = { command: s["command"] };
            if (typeof s["failFatal"] === "boolean")
                step.failFatal = s["failFatal"];
            if (typeof s["description"] === "string")
                step.description = s["description"];
            setup.push(step);
        }
    }
    // ── Parse optional setupCache block ──────────────────────────────────────────
    let setupCache;
    if (isRecord(raw["setupCache"])) {
        const c = raw["setupCache"];
        if (typeof c["key"] !== "string" || !c["key"]) {
            throw new WorkflowConfigError(workflowName, "setupCache.key must be a non-empty string");
        }
        if (typeof c["path"] !== "string" || !c["path"]) {
            throw new WorkflowConfigError(workflowName, "setupCache.path must be a non-empty string");
        }
        setupCache = { key: c["key"], path: c["path"] };
    }
    if (!Array.isArray(raw["phases"])) {
        throw new WorkflowConfigError(workflowName, "missing required 'phases' array");
    }
    const phases = [];
    for (let i = 0; i < raw["phases"].length; i++) {
        const p = raw["phases"][i];
        if (!isRecord(p)) {
            throw new WorkflowConfigError(workflowName, `phases[${i}] must be an object`);
        }
        if (typeof p["name"] !== "string" || !p["name"]) {
            throw new WorkflowConfigError(workflowName, `phases[${i}].name must be a non-empty string`);
        }
        const phase = { name: p["name"] };
        if (typeof p["prompt"] === "string")
            phase.prompt = p["prompt"];
        if (typeof p["model"] === "string")
            phase.model = p["model"];
        // Parse priority-based models map (takes precedence over single model field)
        if (isRecord(p["models"])) {
            const modelsRaw = p["models"];
            const models = {};
            const validKeys = new Set(["default", "P0", "P1", "P2", "P3", "P4"]);
            for (const [key, value] of Object.entries(modelsRaw)) {
                if (!validKeys.has(key)) {
                    throw new WorkflowConfigError(workflowName, `phases[${i}].models key '${key}' is invalid; must be 'default' or 'P0'–'P4'`);
                }
                if (typeof value !== "string" || !value) {
                    throw new WorkflowConfigError(workflowName, `phases[${i}].models.${key} must be a non-empty string`);
                }
                models[key] = value;
            }
            if (Object.keys(models).length > 0) {
                phase.models = models;
            }
        }
        if (typeof p["maxTurns"] === "number")
            phase.maxTurns = p["maxTurns"];
        if (typeof p["timeoutSecs"] === "number")
            phase.timeoutSecs = p["timeoutSecs"];
        if (typeof p["skipIfArtifact"] === "string")
            phase.skipIfArtifact = p["skipIfArtifact"];
        if (typeof p["retryOnly"] === "boolean")
            phase.retryOnly = p["retryOnly"];
        if (typeof p["artifact"] === "string")
            phase.artifact = p["artifact"];
        if (typeof p["verdict"] === "boolean")
            phase.verdict = p["verdict"];
        if (typeof p["retryWith"] === "string")
            phase.retryWith = p["retryWith"];
        if (typeof p["retryOnFail"] === "number")
            phase.retryOnFail = p["retryOnFail"];
        if (typeof p["retryAfterCooldown"] === "boolean")
            phase.retryAfterCooldown = p["retryAfterCooldown"];
        if (typeof p["cooldownSeconds"] === "number")
            phase.cooldownSeconds = p["cooldownSeconds"];
        if (typeof p["builtin"] === "boolean")
            phase.builtin = p["builtin"];
        if (typeof p["bash"] === "string")
            phase.bash = p["bash"];
        if (typeof p["command"] === "string")
            phase.command = p["command"];
        if (isRecord(p["tools"])) {
            const toolsRaw = p["tools"];
            const allowedRaw = toolsRaw["allowed"];
            if (allowedRaw !== undefined) {
                if (!Array.isArray(allowedRaw)) {
                    throw new WorkflowConfigError(workflowName, `phases[${i}].tools.allowed must be an array of strings`);
                }
                const allowed = allowedRaw.map((tool, toolIndex) => {
                    if (typeof tool !== "string" || !tool.trim()) {
                        throw new WorkflowConfigError(workflowName, `phases[${i}].tools.allowed[${toolIndex}] must be a non-empty string`);
                    }
                    return tool;
                });
                phase.tools = { allowed };
            }
        }
        // Exactly one of bash, command, or prompt must be set (unless builtin: true)
        const hasPrompt = typeof p["prompt"] === "string";
        const hasBash = typeof p["bash"] === "string";
        const hasCommand = typeof p["command"] === "string";
        const isBuiltin = typeof p["builtin"] === "boolean" && p["builtin"];
        if (hasBash && hasPrompt) {
            throw new WorkflowConfigError(workflowName, `phases[${i}].${p["name"]} has both 'bash:' and 'prompt:' — only one is allowed`);
        }
        if (hasBash && hasCommand) {
            throw new WorkflowConfigError(workflowName, `phases[${i}].${p["name"]} has both 'bash:' and 'command:' — only one is allowed`);
        }
        if (hasCommand && hasPrompt) {
            throw new WorkflowConfigError(workflowName, `phases[${i}].${p["name"]} has both 'command:' and 'prompt:' — only one is allowed`);
        }
        // builtin: true phases don't need a prompt/bash/command field
        if (!hasPrompt && !hasBash && !hasCommand && !isBuiltin) {
            throw new WorkflowConfigError(workflowName, `phases[${i}].${p["name"]} must have one of 'prompt:', 'bash:', or 'command:'`);
        }
        // Parse mail hooks
        if (isRecord(p["mail"])) {
            const m = p["mail"];
            phase.mail = {};
            if (typeof m["onStart"] === "boolean")
                phase.mail.onStart = m["onStart"];
            if (typeof m["onComplete"] === "boolean")
                phase.mail.onComplete = m["onComplete"];
            if (typeof m["onFail"] === "string")
                phase.mail.onFail = m["onFail"];
            if (typeof m["forwardArtifactTo"] === "string")
                phase.mail.forwardArtifactTo = m["forwardArtifactTo"];
        }
        // Parse file reservation config
        if (isRecord(p["files"])) {
            const f = p["files"];
            phase.files = {};
            if (typeof f["reserve"] === "boolean")
                phase.files.reserve = f["reserve"];
            if (typeof f["leaseSecs"] === "number")
                phase.files.leaseSecs = f["leaseSecs"];
        }
        phases.push(phase);
    }
    if (phases.length === 0) {
        throw new WorkflowConfigError(workflowName, "phases array must not be empty");
    }
    const config = { name, phases };
    if (setup !== undefined)
        config.setup = setup;
    if (setupCache !== undefined)
        config.setupCache = setupCache;
    // ── Parse optional vcs block ───────────────────────────────────────────────
    if (isRecord(raw["vcs"])) {
        const vcsRaw = raw["vcs"];
        const backend = vcsRaw["backend"];
        if (backend === "git" || backend === "jujutsu" || backend === "auto") {
            config.vcs = { backend };
        }
        else if (backend !== undefined) {
            throw new WorkflowConfigError(workflowName, `vcs.backend must be 'git', 'jujutsu', or 'auto' (got: ${String(backend)})`);
        }
    }
    // ── Parse optional onFailure block ────────────────────────────────────────
    if (isRecord(raw["onFailure"])) {
        const of_ = raw["onFailure"];
        if (typeof of_["name"] !== "string" || !of_["name"]) {
            throw new WorkflowConfigError(workflowName, "onFailure.name must be a non-empty string");
        }
        const onFailure = {
            name: of_["name"],
            prompt: typeof of_["prompt"] === "string" ? of_["prompt"] : `${of_["name"]}.md`,
        };
        if (typeof of_["maxTurns"] === "number")
            onFailure.maxTurns = of_["maxTurns"];
        if (typeof of_["artifact"] === "string")
            onFailure.artifact = of_["artifact"];
        if (isRecord(of_["models"])) {
            const models = {};
            for (const [k, v] of Object.entries(of_["models"])) {
                if (typeof v === "string")
                    models[k] = v;
            }
            onFailure.models = models;
        }
        config.onFailure = onFailure;
    }
    // ── Parse optional epic mode fields (taskPhases, finalPhases) ──────────
    if (raw["taskPhases"] !== undefined) {
        if (!Array.isArray(raw["taskPhases"])) {
            throw new WorkflowConfigError(workflowName, "'taskPhases' must be an array of phase names");
        }
        const taskPhases = [];
        for (let j = 0; j < raw["taskPhases"].length; j++) {
            const pName = raw["taskPhases"][j];
            if (typeof pName !== "string" || !pName) {
                throw new WorkflowConfigError(workflowName, `taskPhases[${j}] must be a non-empty string`);
            }
            // Validate that referenced phase exists in the phases array
            if (!phases.some((p) => p.name === pName)) {
                throw new WorkflowConfigError(workflowName, `taskPhases[${j}] references phase '${pName}' which is not defined in phases`);
            }
            taskPhases.push(pName);
        }
        if (taskPhases.length > 0) {
            config.taskPhases = taskPhases;
        }
    }
    if (raw["finalPhases"] !== undefined) {
        if (!Array.isArray(raw["finalPhases"])) {
            throw new WorkflowConfigError(workflowName, "'finalPhases' must be an array of phase names");
        }
        const finalPhases = [];
        for (let j = 0; j < raw["finalPhases"].length; j++) {
            const pName = raw["finalPhases"][j];
            if (typeof pName !== "string" || !pName) {
                throw new WorkflowConfigError(workflowName, `finalPhases[${j}] must be a non-empty string`);
            }
            if (!phases.some((p) => p.name === pName)) {
                throw new WorkflowConfigError(workflowName, `finalPhases[${j}] references phase '${pName}' which is not defined in phases`);
            }
            finalPhases.push(pName);
        }
        if (finalPhases.length > 0) {
            config.finalPhases = finalPhases;
        }
    }
    // ── Parse optional taskTimeout ─────────────────────────────────────────
    if (raw["taskTimeout"] !== undefined) {
        if (typeof raw["taskTimeout"] !== "number" || raw["taskTimeout"] <= 0) {
            throw new WorkflowConfigError(workflowName, "taskTimeout must be a positive number (seconds)");
        }
        config.taskTimeout = raw["taskTimeout"];
    }
    // ── Parse optional onError strategy ─────────────────────────────────────
    if (raw["onError"] !== undefined) {
        const onError = raw["onError"];
        if (onError === "stop" || onError === "continue") {
            config.onError = onError;
        }
        else {
            throw new WorkflowConfigError(workflowName, `onError must be 'stop' or 'continue' (got: ${String(onError)})`);
        }
    }
    // ── Parse optional merge strategy ────────────────────────────────────────
    if (raw["merge"] !== undefined) {
        const merge = raw["merge"];
        if (merge === "auto" || merge === "pr" || merge === "none") {
            config.merge = merge;
        }
        else {
            throw new WorkflowConfigError(workflowName, `merge must be 'auto', 'pr', or 'none' (got: ${String(merge)})`);
        }
    }
    // ── Parse optional pr.timing ───────────────────────────────────────────
    if (isRecord(raw["pr"])) {
        const prRaw = raw["pr"];
        config.pr = {};
        if (typeof prRaw["timing"] === "string") {
            const timing = prRaw["timing"];
            if (timing === "draft-after-developer" || timing === "create-at-finalize" || timing === "never") {
                config.pr.timing = timing;
            }
            else {
                throw new WorkflowConfigError(workflowName, `pr.timing must be 'draft-after-developer', 'create-at-finalize', or 'never' (got: ${timing})`);
            }
        }
    }
    // ── Parse optional sandbox block (Backlog-011: Container Sandboxing) ───
    if ("sandbox" in raw && !isRecord(raw["sandbox"])) {
        throw new WorkflowConfigError(workflowName, "'sandbox' must be an object");
    }
    if (isRecord(raw["sandbox"])) {
        const sandboxRaw = raw["sandbox"];
        const sandboxConfig = {};
        if ("backend" in sandboxRaw) {
            const backend = sandboxRaw["backend"];
            if (backend !== undefined && backend !== "docker" && backend !== "podman" && backend !== "auto") {
                throw new WorkflowConfigError(workflowName, `'sandbox.backend' must be 'docker', 'podman', or 'auto' (got: ${String(backend)})`);
            }
            sandboxConfig.backend = backend;
        }
        if ("image" in sandboxRaw) {
            if (typeof sandboxRaw["image"] !== "string" || !sandboxRaw["image"].trim()) {
                throw new WorkflowConfigError(workflowName, "'sandbox.image' must be a non-empty string");
            }
            sandboxConfig.image = sandboxRaw["image"];
        }
        if ("limits" in sandboxRaw && !isRecord(sandboxRaw["limits"])) {
            throw new WorkflowConfigError(workflowName, "'sandbox.limits' must be an object");
        }
        if (isRecord(sandboxRaw["limits"])) {
            const limitsRaw = sandboxRaw["limits"];
            sandboxConfig.limits = {};
            if ("cpu" in limitsRaw && (typeof limitsRaw["cpu"] !== "string" || !limitsRaw["cpu"].trim())) {
                throw new WorkflowConfigError(workflowName, "'sandbox.limits.cpu' must be a non-empty string");
            }
            sandboxConfig.limits.cpu = limitsRaw["cpu"];
            if ("memory" in limitsRaw && (typeof limitsRaw["memory"] !== "string" || !limitsRaw["memory"].trim())) {
                throw new WorkflowConfigError(workflowName, "'sandbox.limits.memory' must be a non-empty string");
            }
            sandboxConfig.limits.memory = limitsRaw["memory"];
            if ("cpuset" in limitsRaw && (typeof limitsRaw["cpuset"] !== "string" || !limitsRaw["cpuset"].trim())) {
                throw new WorkflowConfigError(workflowName, "'sandbox.limits.cpuset' must be a non-empty string");
            }
            sandboxConfig.limits.cpuset = limitsRaw["cpuset"];
            if ("memorySwap" in limitsRaw && (typeof limitsRaw["memorySwap"] !== "string" || !limitsRaw["memorySwap"].trim())) {
                throw new WorkflowConfigError(workflowName, "'sandbox.limits.memorySwap' must be a non-empty string");
            }
            sandboxConfig.limits.memorySwap = limitsRaw["memorySwap"];
        }
        if ("network" in sandboxRaw && typeof sandboxRaw["network"] !== "boolean") {
            throw new WorkflowConfigError(workflowName, "'sandbox.network' must be a boolean");
        }
        sandboxConfig.network = sandboxRaw["network"];
        if ("cleanup" in sandboxRaw) {
            const cleanup = sandboxRaw["cleanup"];
            if (cleanup !== undefined && cleanup !== "remove" && cleanup !== "keep") {
                throw new WorkflowConfigError(workflowName, `'sandbox.cleanup' must be 'remove' or 'keep' (got: ${String(cleanup)})`);
            }
            sandboxConfig.cleanup = cleanup;
        }
        config.sandbox = sandboxConfig;
        const hostPhases = config.phases.filter((phase) => !phase.bash).map((phase) => phase.name);
        if (hostPhases.length > 0) {
            throw new WorkflowConfigError(workflowName, `sandbox is only supported for bash phases; host-executed phases are not isolated: ${hostPhases.join(", ")}`);
        }
    }
    return config;
}
// ── Loader ────────────────────────────────────────────────────────────────────
/**
 * Load and validate a workflow config.
 *
 * Resolution order:
 *   1. ~/.foreman/workflows/{name}.yaml              (global override)
 *   2. Bundled default: src/defaults/workflows/{name}.yaml
 *
 * @param workflowName - Workflow name (e.g. "default", "smoke").
 * @param projectRoot  - Absolute path to the project root.
 * @throws WorkflowConfigError if not found or invalid.
 */
export function loadWorkflowConfig(workflowName, projectRoot) {
    const directPath = workflowName.endsWith(".yaml") || workflowName.endsWith(".yml")
        ? isAbsolute(workflowName) ? workflowName : join(projectRoot, workflowName)
        : null;
    if (directPath && existsSync(directPath)) {
        try {
            const raw = yamlLoad(readFileSync(directPath, "utf-8"));
            return { ...validateWorkflowConfig(raw, workflowName), sourcePath: directPath };
        }
        catch (err) {
            if (err instanceof WorkflowConfigError)
                throw err;
            const msg = err instanceof Error ? err.message : String(err);
            throw new WorkflowConfigError(workflowName, `failed to parse ${directPath}: ${msg}`);
        }
    }
    // Tier 1: global override
    const globalPath = getForemanHomePath("workflows", `${workflowName}.yaml`);
    if (existsSync(globalPath)) {
        try {
            const raw = yamlLoad(readFileSync(globalPath, "utf-8"));
            return { ...validateWorkflowConfig(raw, workflowName), sourcePath: globalPath };
        }
        catch (err) {
            if (err instanceof WorkflowConfigError)
                throw err;
            const msg = err instanceof Error ? err.message : String(err);
            throw new WorkflowConfigError(workflowName, `failed to parse ${globalPath}: ${msg}`);
        }
    }
    // Tier 2: bundled default
    const bundledPath = join(BUNDLED_WORKFLOWS_DIR, `${workflowName}.yaml`);
    if (existsSync(bundledPath)) {
        try {
            const raw = yamlLoad(readFileSync(bundledPath, "utf-8"));
            return { ...validateWorkflowConfig(raw, workflowName), sourcePath: bundledPath };
        }
        catch (err) {
            if (err instanceof WorkflowConfigError)
                throw err;
            const msg = err instanceof Error ? err.message : String(err);
            throw new WorkflowConfigError(workflowName, `failed to parse bundled default ${bundledPath}: ${msg}`);
        }
    }
    throw new WorkflowConfigError(workflowName, `no workflow config found at ${globalPath} or bundled defaults`);
}
/**
 * Get the path to a bundled workflow YAML file.
 *
 * @returns Absolute path, or null if not found.
 */
export function getBundledWorkflowPath(workflowName) {
    const p = join(BUNDLED_WORKFLOWS_DIR, `${workflowName}.yaml`);
    return existsSync(p) ? p : null;
}
/**
 * Returns true when a workflow YAML exists either in ~/.foreman/workflows/
 * or in the bundled defaults directory.
 */
export function hasWorkflowConfig(workflowName) {
    const globalPath = getForemanHomePath("workflows", `${workflowName}.yaml`);
    return existsSync(globalPath) || getBundledWorkflowPath(workflowName) !== null;
}
/**
 * Install bundled workflow configs to ~/.foreman/workflows/.
 *
 * Copies all bundled workflow YAML files. Existing files are skipped unless
 * force=true.
 *
 * @param projectRoot - Absolute path to the project root.
 * @param force       - Overwrite existing workflow files (default: false).
 * @returns Summary of installed/skipped files.
 */
export function installBundledWorkflows(_projectRoot, force = false) {
    const installed = [];
    const skipped = [];
    const destDir = getForemanHomePath("workflows");
    mkdirSync(destDir, { recursive: true });
    let files;
    try {
        files = readdirSync(BUNDLED_WORKFLOWS_DIR).filter((f) => f.endsWith(".yaml"));
    }
    catch {
        // Bundled workflows directory doesn't exist (e.g. non-dist environment)
        return { installed, skipped };
    }
    for (const file of files) {
        const destPath = join(destDir, file);
        if (existsSync(destPath) && !force) {
            skipped.push(file);
        }
        else {
            copyFileSync(join(BUNDLED_WORKFLOWS_DIR, file), destPath);
            installed.push(file);
        }
    }
    return { installed, skipped };
}
/**
 * List all workflow names available to the loader: bundled defaults plus any
 * YAML files installed in ~/.foreman/workflows/. Sorted and deduplicated.
 */
export function listAvailableWorkflows() {
    const names = new Set();
    try {
        for (const file of readdirSync(BUNDLED_WORKFLOWS_DIR)) {
            if (file.endsWith(".yaml") || file.endsWith(".yml")) {
                names.add(file.replace(/\.ya?ml$/, ""));
            }
        }
    }
    catch {
        // Bundled workflows directory missing (e.g. partial install) — non-fatal
    }
    try {
        for (const file of readdirSync(getForemanHomePath("workflows"))) {
            if (file.endsWith(".yaml") || file.endsWith(".yml")) {
                names.add(file.replace(/\.ya?ml$/, ""));
            }
        }
    }
    catch {
        // ~/.foreman/workflows/ not created yet — non-fatal
    }
    return [...names].sort();
}
/**
 * Ensure all bundled workflows are installed in ~/.foreman/workflows/.
 *
 * Installs any missing bundled workflow YAML (never overwrites existing
 * files), then returns the names that are still missing (e.g. when the
 * bundled defaults directory is unavailable). Used by the `foreman run`
 * preflight so that newly added bundled workflows (e.g. quick.yaml) are
 * installed on the fly instead of blocking dispatch for existing installs.
 *
 * @param projectRoot - Absolute path to the project root.
 * @returns Array of workflow names still missing after the install attempt.
 */
export function ensureBundledWorkflowsInstalled(projectRoot) {
    try {
        installBundledWorkflows(projectRoot, false);
    }
    catch {
        // Install failure (e.g. read-only home) — fall through to report missing
    }
    return findMissingWorkflows(projectRoot);
}
/**
 * Find missing workflow config files for a project.
 *
 * @param projectRoot - Absolute path to the project root.
 * @returns Array of missing workflow names (e.g. ["default", "smoke"]).
 */
export function findMissingWorkflows(_projectRoot) {
    const missing = [];
    for (const name of BUNDLED_WORKFLOW_NAMES) {
        const p = getForemanHomePath("workflows", `${name}.yaml`);
        if (!existsSync(p)) {
            missing.push(name);
        }
    }
    return missing;
}
/**
 * Find locally installed workflow configs that are stale (missing critical
 * verdict/retry fields that exist in the bundled default).
 *
 * A workflow is considered stale when any phase in the bundled version has
 * `verdict: true` but the corresponding local phase is missing `verdict`,
 * `retryWith`, or `retryOnFail`.
 *
 * This catches the class of bugs where `foreman init` installs an older copy
 * of a workflow YAML and subsequent updates to the bundled default (adding
 * verdict/retry config) are never propagated to the project-local copy.
 *
 * @param projectRoot - Absolute path to the project root.
 * @returns Array of stale workflow names (present but outdated).
 */
export function findStaleWorkflows(_projectRoot) {
    const stale = [];
    for (const name of BUNDLED_WORKFLOW_NAMES) {
        const localPath = getForemanHomePath("workflows", `${name}.yaml`);
        if (!existsSync(localPath))
            continue; // missing, not stale
        const bundledPath = join(BUNDLED_WORKFLOWS_DIR, `${name}.yaml`);
        if (!existsSync(bundledPath))
            continue; // no bundled reference to compare against
        try {
            const localRaw = yamlLoad(readFileSync(localPath, "utf-8"));
            const bundledRaw = yamlLoad(readFileSync(bundledPath, "utf-8"));
            if (!Array.isArray(localRaw?.phases) || !Array.isArray(bundledRaw?.phases))
                continue;
            // Build a map from phase name → phase config for the local file
            const localPhaseMap = new Map();
            for (const p of localRaw.phases) {
                if (typeof p.name === "string") {
                    localPhaseMap.set(p.name, p);
                }
            }
            // Check each bundled verdict-phase exists locally with the required fields
            let isStale = false;
            for (const bundledPhase of bundledRaw.phases) {
                if (typeof bundledPhase.name !== "string")
                    continue;
                if (bundledPhase["verdict"] !== true)
                    continue; // only check verdict phases
                const localPhase = localPhaseMap.get(bundledPhase.name);
                if (!localPhase) {
                    isStale = true;
                    break;
                }
                // Stale if local phase is missing verdict, retryWith, or retryOnFail
                // that the bundled version defines
                if ((bundledPhase["verdict"] === true && localPhase["verdict"] !== true) ||
                    (bundledPhase["retryWith"] !== undefined && localPhase["retryWith"] === undefined) ||
                    (bundledPhase["retryOnFail"] !== undefined && localPhase["retryOnFail"] === undefined)) {
                    isStale = true;
                    break;
                }
            }
            if (isStale)
                stale.push(name);
        }
        catch {
            // Parse error in local or bundled file — skip, let checkWorkflows handle it
        }
    }
    return stale;
}
/**
 * Resolve the effective workflow name for a seed.
 *
 * Resolution order:
 *   1. First `workflow:<name>` label on the bead
 *   2. Bead type field mapped: "smoke" → "smoke", everything else → "default"
 *
 * @param seedType - The bead's type field (e.g. "feature", "smoke").
 * @param labels   - Optional list of labels on the bead.
 * @returns The resolved workflow name to use.
 */
/**
 * Resolve the workflow name for a seed/bead.
 *
 * Resolution order:
 *  1. `workflowOverride` — explicit override (e.g. `foreman run --workflow <name>`)
 *  2. `workflow:<name>` label on the task
 *  3. `taskTypeWorkflowMap[seedType]` — explicit config mapping
 *  4. `taskTypeWorkflowMap["default"]` — fallback for unknown types
 *  5. `{seedType}.yaml` in global (~/.foreman/workflows/) or bundled workflows
 *  6. "default" (hard fallback)
 *
 * When `taskTypeWorkflowMap` is not provided (undefined), steps 3–4 are skipped
 * and the resolution falls back to the file-existence check (backward compatible).
 *
 * The explicit override is trusted as-is — callers (the CLI) validate it
 * against loadable workflows before dispatch.
 */
export function resolveWorkflowName(seedType, labels, taskTypeWorkflowMap, workflowOverride) {
    // 0. Explicit override (e.g. `foreman run --workflow quick`) — top priority
    const override = workflowOverride?.trim();
    if (override) {
        return override;
    }
    // 1. workflow:<name> label override
    if (labels) {
        for (const label of labels) {
            if (label.startsWith("workflow:")) {
                return label.slice("workflow:".length);
            }
        }
    }
    // 2. Explicit taskTypeWorkflowMap mapping
    if (taskTypeWorkflowMap) {
        const mappedWorkflow = taskTypeWorkflowMap[seedType];
        if (mappedWorkflow && hasWorkflowConfig(mappedWorkflow)) {
            return mappedWorkflow;
        }
        // 3. Default fallback from config mapping
        const defaultWorkflow = taskTypeWorkflowMap["default"];
        if (defaultWorkflow && hasWorkflowConfig(defaultWorkflow)) {
            return defaultWorkflow;
        }
    }
    // 4. File-existence fallback (backward compatible with pre-config behavior)
    if (seedType) {
        const globalPath = getForemanHomePath("workflows", `${seedType}.yaml`);
        if (existsSync(globalPath)) {
            return seedType;
        }
        const bundledPath = join(BUNDLED_WORKFLOWS_DIR, `${seedType}.yaml`);
        if (existsSync(bundledPath)) {
            return seedType;
        }
    }
    // 5. Hard fallback to default
    return "default";
}
// ── Compatibility exports ─────────────────────────────────────────────────────
/**
 * Alias for BUNDLED_WORKFLOW_NAMES — required workflow names.
 * @deprecated Use BUNDLED_WORKFLOW_NAMES instead.
 */
export const REQUIRED_WORKFLOWS = BUNDLED_WORKFLOW_NAMES;
/**
 * Find a phase by name in a workflow config.
 *
 * @param workflow   - Loaded workflow config.
 * @param phaseName  - Phase name to look up.
 * @returns The matching phase config, or undefined if not found.
 */
export function getWorkflowPhase(workflow, phaseName) {
    return workflow.phases.find((p) => p.name === phaseName);
}
/**
 * Model shorthand to full model ID mapping.
 * Allows YAML to use readable aliases instead of full model strings.
 */
const MODEL_SHORTHANDS = {
    haiku: "anthropic/claude-haiku-4-5",
    sonnet: "anthropic/claude-sonnet-4-6",
    opus: "anthropic/claude-opus-4-6",
    MiniMax: "minimax/MiniMax-M2.7",
    "MiniMax-highspeed": "minimax/MiniMax-M2.7-highspeed",
    gpt5: "openai/gpt-5.2-chat-latest",
};
/**
 * Resolve a model string from workflow YAML to a full model ID.
 * Accepts shorthands ("haiku", "sonnet", "opus") or full model IDs.
 *
 * @param model - Model string from YAML, or undefined.
 * @returns Full model ID, or undefined if input is undefined.
 */
export function resolveWorkflowModel(model) {
    if (!model)
        return undefined;
    return MODEL_SHORTHANDS[model] ?? model;
}
/**
 * Resolve the effective model for a pipeline phase at runtime.
 *
 * Resolution order (first defined wins):
 *   1. `phase.models[priorityKey]`  — per-priority YAML override (e.g. "P0: opus")
 *   2. `phase.models.default`       — per-phase YAML default
 *   3. `phase.model`                — legacy single-model YAML field (backward compat)
 *   4. `fallbackModel`              — caller-supplied fallback (typically ROLE_CONFIGS value)
 *
 * @param phase         - Loaded workflow phase config.
 * @param priorityStr   - Bead priority string ("P0"–"P4", "0"–"4", or undefined).
 * @param fallbackModel - Model to use when no YAML config is present (e.g. ROLE_CONFIGS[role].model).
 * @returns Full model ID string.
 */
export function resolvePhaseModel(phase, priorityStr, fallbackModel) {
    if (phase.models) {
        // Normalise priority to "P0"–"P4" format
        const priorityKey = normalisePriorityKey(priorityStr);
        const priorityOverride = priorityKey ? phase.models[priorityKey] : undefined;
        const resolved = priorityOverride ?? phase.models["default"];
        if (resolved)
            return resolveWorkflowModel(resolved) ?? resolved;
    }
    // Legacy single-model field
    if (phase.model) {
        const resolved = resolveWorkflowModel(phase.model);
        if (resolved)
            return resolved;
    }
    return fallbackModel;
}
/**
 * Convert a priority string in any format ("P0"–"P4" or "0"–"4") to the
 * canonical "P0"–"P4" format used as YAML models map keys.
 *
 * Returns undefined for unrecognised inputs.
 */
function normalisePriorityKey(p) {
    if (!p)
        return undefined;
    const upper = p.trim().toUpperCase();
    // Already in "P0"–"P4" format
    if (/^P[0-4]$/.test(upper))
        return upper;
    // Numeric string "0"–"4"
    if (/^[0-4]$/.test(upper))
        return `P${upper}`;
    return undefined;
}
//# sourceMappingURL=workflow-loader.js.map