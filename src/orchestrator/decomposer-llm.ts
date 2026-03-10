import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import type { DecompositionPlan, TaskPlan } from "./types.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

/**
 * LLM-powered TRD decomposer.
 *
 * Sends the TRD content to Claude Code with a structured decomposition prompt.
 * Returns a validated DecompositionPlan with tasks, dependencies, and complexity.
 */
export async function decomposePrdWithLlm(
  trdContent: string,
  model?: string,
): Promise<DecompositionPlan> {
  // Load the prompt template
  const templatePath = resolve(__dirname, "../../templates/decomposer-prompt.md");
  const template = readFileSync(templatePath, "utf-8");

  // Inject TRD content
  const prompt = template.replace("{{TRD_CONTENT}}", trdContent);

  // Build the system instruction
  const systemPrompt = [
    "You are a senior technical lead decomposing a TRD into development tasks.",
    "Respond with ONLY valid JSON matching the schema in the prompt.",
    "No markdown fences, no explanation, no commentary — just the JSON object.",
    "The JSON must have an 'epic' object (title + description) and a 'tasks' array.",
    "Each task needs: title, description, priority, estimatedComplexity, dependencies (array of task titles).",
  ].join(" ");

  // Call Claude Code in non-interactive mode
  // Use stdin pipe for large prompts (TRDs can exceed OS arg limits)
  const claudePath = findClaude();
  const args = [
    "--permission-mode", "bypassPermissions",
    "--print",
    "--output-format", "text",
    ...(model ? ["--model", model] : []),
    "--system-prompt", systemPrompt,
    "-", // read prompt from stdin
  ];

  let stdout: string;
  try {
    stdout = execFileSync(claudePath, args, {
      input: prompt,
      encoding: "utf-8",
      timeout: 600_000, // 10 minutes for large TRDs
      maxBuffer: 10 * 1024 * 1024,
      env: {
        ...process.env,
        PATH: `/opt/homebrew/bin:${process.env.PATH}`,
      },
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new Error(`Claude decomposition failed: ${msg}`);
  }

  // Extract JSON from response (handle potential markdown fences)
  const plan = parseResponse(stdout.trim());

  // Validate the plan
  validatePlan(plan);

  return plan;
}

/**
 * Find the claude CLI binary.
 */
function findClaude(): string {
  const candidates = [
    "/opt/homebrew/bin/claude",
    `${process.env.HOME}/.local/bin/claude`,
  ];

  for (const path of candidates) {
    try {
      execFileSync("test", ["-x", path]);
      return path;
    } catch {
      // not found, try next
    }
  }

  // Fall back to PATH
  try {
    return execFileSync("which", ["claude"], { encoding: "utf-8" }).trim();
  } catch {
    throw new Error(
      "Claude CLI not found. Install it: brew install claude-code",
    );
  }
}

/**
 * Parse the LLM response, stripping markdown fences if present.
 */
function parseResponse(raw: string): DecompositionPlan {
  // Strip markdown code fences
  let json = raw;
  const fenceMatch = raw.match(/```(?:json)?\s*\n?([\s\S]*?)\n?\s*```/);
  if (fenceMatch) {
    json = fenceMatch[1];
  }

  // Try to find the JSON object if there's extra text
  if (!json.trim().startsWith("{")) {
    const objStart = json.indexOf("{");
    if (objStart >= 0) {
      json = json.slice(objStart);
    }
  }

  try {
    return JSON.parse(json);
  } catch (err) {
    throw new Error(
      `Failed to parse LLM response as JSON: ${err instanceof Error ? err.message : String(err)}\n\nRaw response:\n${raw.slice(0, 500)}`,
    );
  }
}

/**
 * Validate the decomposition plan structure and constraints.
 */
function validatePlan(plan: DecompositionPlan): void {
  if (!plan.epic?.title) {
    throw new Error("Plan missing epic.title");
  }
  if (!plan.epic?.description) {
    throw new Error("Plan missing epic.description");
  }
  if (!Array.isArray(plan.tasks)) {
    throw new Error("Plan missing tasks array");
  }
  if (plan.tasks.length === 0) {
    throw new Error("Plan has zero tasks — TRD may be too vague or empty");
  }

  const validPriorities = new Set(["critical", "high", "medium", "low"]);
  const validComplexities = new Set(["low", "medium", "high"]);
  const taskTitles = new Set(plan.tasks.map((t) => t.title));

  for (const task of plan.tasks) {
    if (!task.title) {
      throw new Error("Task missing title");
    }
    if (!task.description) {
      throw new Error(`Task "${task.title}" missing description`);
    }
    if (!validPriorities.has(task.priority)) {
      // Fix invalid priority silently
      task.priority = "medium";
    }
    if (!validComplexities.has(task.estimatedComplexity)) {
      task.estimatedComplexity = "medium";
    }
    if (!Array.isArray(task.dependencies)) {
      task.dependencies = [];
    }

    // Validate dependency references exist
    task.dependencies = task.dependencies.filter((dep) => {
      if (!taskTitles.has(dep)) {
        // Silently drop invalid dependency references
        return false;
      }
      return true;
    });

    // Strip acceptanceCriteria (not in our type, but LLM may include it)
    delete (task as unknown as Record<string, unknown>).acceptanceCriteria;
  }

  // Detect circular dependencies
  detectCycles(plan.tasks);
}

/**
 * Detect circular dependencies via DFS.
 * Throws if a cycle is found.
 */
function detectCycles(tasks: TaskPlan[]): void {
  const taskMap = new Map(tasks.map((t) => [t.title, t]));
  const visited = new Set<string>();
  const inStack = new Set<string>();

  function dfs(title: string): void {
    if (inStack.has(title)) {
      throw new Error(`Circular dependency detected involving "${title}"`);
    }
    if (visited.has(title)) return;

    inStack.add(title);
    const task = taskMap.get(title);
    if (task) {
      for (const dep of task.dependencies) {
        dfs(dep);
      }
    }
    inStack.delete(title);
    visited.add(title);
  }

  for (const task of tasks) {
    dfs(task.title);
  }
}
