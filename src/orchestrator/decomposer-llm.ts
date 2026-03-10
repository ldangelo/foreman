import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import type { DecompositionPlan, SprintPlan, StoryPlan, TaskPlan } from "./types.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

/**
 * LLM-powered TRD decomposer.
 *
 * Sends the TRD content to Claude Code with a structured decomposition prompt.
 * Returns a validated DecompositionPlan with epic → sprint → story → task hierarchy.
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
    "You are a senior technical lead decomposing a TRD into a hierarchical work breakdown.",
    "CRITICAL: Your ENTIRE response must be a single JSON object. No text before or after.",
    "Do NOT explain your thinking. Do NOT say 'here is the JSON'. Start with { and end with }.",
    "The JSON must have an 'epic' object (title + description) and a 'sprints' array.",
    "Each sprint has: title, goal, stories array.",
    "Each story has: title, description, priority, tasks array.",
    "Each task has: title, description, type (task|spike|test), priority, estimatedComplexity, dependencies.",
    "Keep descriptions concise (1 sentence). This keeps the JSON compact.",
  ].join(" ");

  // Call Claude Code in non-interactive mode
  const claudePath = findClaude();
  const args = [
    "--permission-mode", "bypassPermissions",
    "--print",
    "--output-format", "text",
    "--max-turns", "1",
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
 * Attempts to repair truncated JSON if the response was cut off.
 */
function parseResponse(raw: string): DecompositionPlan {
  // Strip markdown code fences
  let json = raw;
  const fenceMatch = raw.match(/```(?:json)?\s*\n?([\s\S]*?)\n?\s*```/);
  if (fenceMatch) {
    json = fenceMatch[1];
  }

  // Try to find the JSON object if there's extra text before it
  if (!json.trim().startsWith("{")) {
    const objStart = json.indexOf("{");
    if (objStart >= 0) {
      json = json.slice(objStart);
    }
  }

  // Trim any trailing text after the JSON (e.g., "Note: ..." after the closing brace)
  json = json.trim();

  // First attempt: parse as-is
  try {
    return JSON.parse(json);
  } catch {
    // noop — try repair
  }

  // Second attempt: repair truncated JSON
  const repaired = repairTruncatedJson(json);
  try {
    return JSON.parse(repaired);
  } catch (err) {
    throw new Error(
      `Failed to parse LLM response as JSON: ${err instanceof Error ? err.message : String(err)}\n\nRaw response (first 500 chars):\n${raw.slice(0, 500)}`,
    );
  }
}

/**
 * Attempt to repair truncated JSON by closing open brackets/braces.
 * Works by tracking the nesting stack and appending missing closers.
 */
function repairTruncatedJson(json: string): string {
  // Find the last valid position by scanning for unclosed structures
  const stack: string[] = [];
  let inString = false;
  let escaped = false;

  for (let i = 0; i < json.length; i++) {
    const ch = json[i];

    if (escaped) {
      escaped = false;
      continue;
    }

    if (ch === "\\") {
      escaped = true;
      continue;
    }

    if (ch === '"') {
      inString = !inString;
      continue;
    }

    if (inString) continue;

    if (ch === "{") stack.push("}");
    else if (ch === "[") stack.push("]");
    else if (ch === "}" || ch === "]") stack.pop();
  }

  if (stack.length === 0) return json; // Already balanced

  // Truncate to the last complete value boundary
  // Find the last comma, closing bracket, or colon that indicates a complete value
  let truncateAt = json.length;

  // Walk back to find a safe truncation point (last complete key-value pair)
  if (inString) {
    // We're inside an unclosed string — find the opening quote and remove from there
    const lastQuote = json.lastIndexOf('"');
    if (lastQuote >= 0) {
      truncateAt = lastQuote;
      // Also remove the key if we're in a key:value pair
      const beforeQuote = json.slice(0, truncateAt).trimEnd();
      if (beforeQuote.endsWith(",")) {
        truncateAt = beforeQuote.length - 1;
      } else if (beforeQuote.endsWith(":")) {
        // Remove the entire key:"... fragment
        const keyStart = json.lastIndexOf('"', truncateAt - 2);
        if (keyStart >= 0) {
          truncateAt = keyStart;
          const beforeKey = json.slice(0, truncateAt).trimEnd();
          if (beforeKey.endsWith(",")) {
            truncateAt = beforeKey.length - 1;
          }
        }
      }
    }
  } else {
    // Not in a string — find the last complete element
    const trimmed = json.trimEnd();
    const lastChar = trimmed[trimmed.length - 1];
    if (lastChar !== "}" && lastChar !== "]" && lastChar !== '"' &&
        lastChar !== "e" && lastChar !== "l" && // true/false/null endings
        !/\d/.test(lastChar)) {
      // Last char isn't a complete value — find the last comma
      const lastComma = trimmed.lastIndexOf(",");
      if (lastComma >= 0) {
        truncateAt = lastComma;
      }
    }
  }

  // Rebuild the stack for the truncated portion
  let result = json.slice(0, truncateAt);
  const repairStack: string[] = [];
  inString = false;
  escaped = false;

  for (let i = 0; i < result.length; i++) {
    const ch = result[i];
    if (escaped) { escaped = false; continue; }
    if (ch === "\\") { escaped = true; continue; }
    if (ch === '"') { inString = !inString; continue; }
    if (inString) continue;
    if (ch === "{") repairStack.push("}");
    else if (ch === "[") repairStack.push("]");
    else if (ch === "}" || ch === "]") repairStack.pop();
  }

  // Remove any trailing comma before closing
  result = result.trimEnd();
  if (result.endsWith(",")) {
    result = result.slice(0, -1);
  }

  // Close all open structures
  result += repairStack.reverse().join("");

  return result;
}

/**
 * Validate the decomposition plan hierarchy.
 */
function validatePlan(plan: DecompositionPlan): void {
  if (!plan.epic?.title) {
    throw new Error("Plan missing epic.title");
  }
  if (!plan.epic?.description) {
    throw new Error("Plan missing epic.description");
  }
  if (!Array.isArray(plan.sprints)) {
    throw new Error("Plan missing sprints array");
  }
  if (plan.sprints.length === 0) {
    throw new Error("Plan has zero sprints — TRD may be too vague or empty");
  }

  const validPriorities = new Set(["critical", "high", "medium", "low"]);
  const validComplexities = new Set(["low", "medium", "high"]);
  const validTypes = new Set(["task", "spike", "test"]);

  // Collect all task titles for dependency validation
  const allTaskTitles = new Set<string>();
  for (const sprint of plan.sprints) {
    for (const story of sprint.stories) {
      for (const task of story.tasks) {
        allTaskTitles.add(task.title);
      }
    }
  }

  for (const sprint of plan.sprints) {
    if (!sprint.title) throw new Error("Sprint missing title");
    if (!sprint.goal) sprint.goal = sprint.title;
    if (!Array.isArray(sprint.stories)) {
      throw new Error(`Sprint "${sprint.title}" missing stories array`);
    }

    for (const story of sprint.stories) {
      validateStory(story, allTaskTitles, validPriorities, validComplexities, validTypes);
    }
  }

  // Detect circular dependencies across all tasks
  const allTasks: TaskPlan[] = [];
  for (const sprint of plan.sprints) {
    for (const story of sprint.stories) {
      allTasks.push(...story.tasks);
    }
  }
  detectCycles(allTasks);
}

function validateStory(
  story: StoryPlan,
  allTaskTitles: Set<string>,
  validPriorities: Set<string>,
  validComplexities: Set<string>,
  validTypes: Set<string>,
): void {
  if (!story.title) throw new Error("Story missing title");
  if (!story.description) story.description = story.title;
  if (!validPriorities.has(story.priority)) {
    story.priority = "medium";
  }
  if (!Array.isArray(story.tasks)) {
    throw new Error(`Story "${story.title}" missing tasks array`);
  }

  for (const task of story.tasks) {
    if (!task.title) throw new Error("Task missing title");
    if (!task.description) throw new Error(`Task "${task.title}" missing description`);
    if (!validTypes.has(task.type)) task.type = "task";
    if (!validPriorities.has(task.priority)) task.priority = "medium";
    if (!validComplexities.has(task.estimatedComplexity)) task.estimatedComplexity = "medium";
    if (!Array.isArray(task.dependencies)) task.dependencies = [];

    // Validate dependency references exist
    task.dependencies = task.dependencies.filter((dep) => allTaskTitles.has(dep));

    // Strip extra fields the LLM may include
    delete (task as unknown as Record<string, unknown>).acceptanceCriteria;
  }
}

/**
 * Detect circular dependencies via DFS.
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
