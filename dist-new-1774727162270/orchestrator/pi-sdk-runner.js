/**
 * pi-sdk-runner.ts — Run Pi agent sessions via the SDK (in-process).
 *
 * Replaces pi-runner.ts which spawned `pi --mode rpc` as a child process
 * and parsed JSONL events from stdout.  The SDK approach eliminates:
 *   - Child process spawning + JSONL parsing
 *   - Pi binary resolution (`which pi`, Homebrew fallback)
 *   - Env-var-based config passing (FOREMAN_ALLOWED_TOOLS, etc.)
 *   - EPIPE crashes on parent exit
 *
 * Each phase call creates a fresh AgentSession (in-memory, no persistence),
 * sends the prompt, awaits completion, and returns structured results.
 */
import { createAgentSession, SessionManager, SettingsManager, AuthStorage, getAgentDir, createReadTool, createBashTool, createEditTool, createWriteTool, createGrepTool, createFindTool, createLsTool, } from "@mariozechner/pi-coding-agent";
import { getModel } from "@mariozechner/pi-ai";
import { appendFile } from "node:fs/promises";
import { join } from "node:path";
const TOOL_FACTORIES = {
    Read: createReadTool,
    Bash: createBashTool,
    Edit: createEditTool,
    Write: createWriteTool,
    Grep: createGrepTool,
    Find: createFindTool,
    LS: createLsTool,
};
/**
 * Build the tool array from allowed tool names.
 * Unknown names are silently skipped (they may be custom tools registered separately).
 */
function buildTools(allowedNames, cwd) {
    const tools = [];
    for (const name of allowedNames) {
        const factory = TOOL_FACTORIES[name];
        if (factory)
            tools.push(factory(cwd));
    }
    return tools;
}
// ── Model resolution ────────────────────────────────────────────────────
/**
 * Parse a model string like "anthropic/claude-sonnet-4-6" into provider+modelId.
 * Supports any provider (anthropic, openai, google, etc.) — the Pi SDK's
 * getModel() handles provider-specific API resolution.
 */
function parseModelString(model) {
    const slash = model.indexOf("/");
    if (slash === -1)
        return { provider: "anthropic", modelId: model };
    return {
        provider: model.slice(0, slash),
        modelId: model.slice(slash + 1),
    };
}
// ── Main entry point ────────────────────────────────────────────────────
/**
 * Run a single Pi SDK session (awaits completion before resolving).
 *
 * Creates an in-memory AgentSession, sends the prompt, listens for events
 * to track tool calls / turns / cost, and resolves with structured results.
 */
export async function runWithPiSdk(opts) {
    // Resolve model — getModel is strictly typed for known providers/IDs;
    // use type assertions for dynamic values from workflow YAML.
    const { provider, modelId } = parseModelString(opts.model);
    const model = getModel(provider, modelId);
    // Build tool set from allowed names
    const tools = opts.allowedTools
        ? buildTools(opts.allowedTools, opts.cwd)
        : buildTools(["Read", "Bash", "Edit", "Write", "Grep", "Find", "LS"], opts.cwd);
    // Accumulators
    let totalTurns = 0;
    let totalToolCalls = 0;
    const toolBreakdown = {};
    let success = true;
    let errorMessage;
    const textChunks = [];
    const writeLog = (line) => {
        if (!opts.logFile)
            return;
        appendFile(opts.logFile, line + "\n").catch(() => { });
    };
    try {
        // Explicitly set agentDir and auth so detached worker processes find credentials.
        const agentDir = getAgentDir();
        const authStorage = AuthStorage.create(join(agentDir, "auth.json"));
        const { session } = await createAgentSession({
            cwd: opts.cwd,
            agentDir,
            authStorage,
            model,
            thinkingLevel: "medium",
            tools,
            customTools: opts.customTools,
            sessionManager: SessionManager.inMemory(),
            settingsManager: SettingsManager.inMemory(),
        });
        // Subscribe to events for tracking
        session.subscribe((event) => {
            switch (event.type) {
                case "turn_start":
                    totalTurns++;
                    break;
                case "turn_end":
                    opts.onTurnEnd?.(totalTurns);
                    break;
                case "message_update": {
                    // Capture assistant text deltas
                    const updateEvent = event;
                    const assistantEvent = updateEvent.assistantMessageEvent;
                    if (assistantEvent?.type === "text_delta") {
                        const delta = assistantEvent.delta;
                        if (delta) {
                            textChunks.push(delta);
                            opts.onText?.(delta);
                        }
                    }
                    break;
                }
                case "tool_execution_start": {
                    const toolName = event.toolName;
                    if (toolName) {
                        totalToolCalls++;
                        toolBreakdown[toolName] = (toolBreakdown[toolName] ?? 0) + 1;
                        const input = event.args;
                        opts.onToolCall?.(toolName, input ?? {});
                    }
                    break;
                }
                case "agent_end": {
                    const endEvent = event;
                    if (endEvent.success === false) {
                        success = false;
                        errorMessage = endEvent.message ?? "Agent ended without success";
                    }
                    break;
                }
            }
            writeLog(JSON.stringify(event));
        });
        // Send the prompt and await completion.
        // Prepend systemPrompt as role context since the Pi SDK manages its own
        // system prompt (from CLAUDE.md, extensions, etc.) and doesn't accept one directly.
        const fullPrompt = opts.systemPrompt
            ? `${opts.systemPrompt}\n\n${opts.prompt}`
            : opts.prompt;
        await session.prompt(fullPrompt);
        // Extract cost and token usage from session stats
        const stats = session.getSessionStats();
        const costUsd = stats.cost ?? 0;
        const tokensIn = stats.tokens?.input ?? 0;
        const tokensOut = stats.tokens?.output ?? 0;
        // Clean up
        session.dispose();
        writeLog(`[pi-sdk-runner] success=${success} turns=${totalTurns} tools=${totalToolCalls} cost=$${costUsd.toFixed(4)} tokensIn=${tokensIn} tokensOut=${tokensOut}`);
        return {
            success,
            costUsd,
            turns: totalTurns,
            toolCalls: totalToolCalls,
            toolBreakdown,
            tokensIn,
            tokensOut,
            errorMessage: success ? undefined : errorMessage,
            outputText: textChunks.length > 0 ? textChunks.join("") : undefined,
        };
    }
    catch (err) {
        const reason = err instanceof Error ? err.message : String(err);
        writeLog(`[pi-sdk-runner] ERROR: ${reason}`);
        return {
            success: false,
            costUsd: 0,
            turns: totalTurns,
            toolCalls: totalToolCalls,
            toolBreakdown,
            tokensIn: 0,
            tokensOut: 0,
            errorMessage: reason,
        };
    }
}
//# sourceMappingURL=pi-sdk-runner.js.map