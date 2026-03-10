import type { DecompositionPlan, TaskPlan, TaskComplexity } from "./types.js";

/**
 * Heuristic PRD decomposer.
 *
 * Extracts structure from a markdown PRD by looking for:
 * - H1/H2 headers as epic title and section boundaries
 * - Task lists (- [ ] items) as explicit tasks
 * - Numbered lists as ordered steps
 * - Ordering-based dependency inference
 */
export async function decomposePrd(
  prdContent: string,
  _projectPath: string,
): Promise<DecompositionPlan> {
  const lines = prdContent.split("\n");

  const epicTitle = extractEpicTitle(lines);
  const epicDescription = extractEpicDescription(lines);
  const tasks = extractTasks(lines);

  if (tasks.length === 0) {
    throw new Error(
      "No tasks found in PRD. Expected task lists (- [ ] items), numbered lists, or ## sections with content.",
    );
  }

  return {
    epic: { title: epicTitle, description: epicDescription },
    tasks,
  };
}

// ── Extractors ──────────────────────────────────────────────────────────

function extractEpicTitle(lines: string[]): string {
  for (const line of lines) {
    const h1 = line.match(/^#\s+(.+)/);
    if (h1) return h1[1].trim();
  }
  // Fallback: first non-empty line
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed) return trimmed;
  }
  return "Untitled Epic";
}

function extractEpicDescription(lines: string[]): string {
  // Grab text between the H1 and the first H2
  let started = false;
  const descLines: string[] = [];

  for (const line of lines) {
    if (/^#\s+/.test(line)) {
      started = true;
      continue;
    }
    if (started && /^##\s+/.test(line)) break;
    if (started) descLines.push(line);
  }

  const desc = descLines.join("\n").trim();
  return desc || "No description provided.";
}

function extractTasks(lines: string[]): TaskPlan[] {
  const tasks: TaskPlan[] = [];

  // Pass 1: Extract checklist items (- [ ] ...)
  const checklistTasks = extractChecklistTasks(lines);

  // Pass 2: Extract numbered list items (1. ...)
  const numberedTasks = extractNumberedTasks(lines);

  // Pass 3: Extract H2 sections as tasks (if no checklist/numbered items found within them)
  const sectionTasks = extractSectionTasks(lines);

  // Prefer checklist items; fall back to numbered; fall back to sections
  if (checklistTasks.length > 0) {
    tasks.push(...checklistTasks);
  } else if (numberedTasks.length > 0) {
    tasks.push(...numberedTasks);
  } else {
    tasks.push(...sectionTasks);
  }

  // Infer dependencies from ordering: each task depends on the previous one
  inferSequentialDependencies(tasks);

  return tasks;
}

function extractChecklistTasks(lines: string[]): TaskPlan[] {
  const tasks: TaskPlan[] = [];
  let currentSection = "";

  for (let i = 0; i < lines.length; i++) {
    const sectionMatch = lines[i].match(/^##\s+(.+)/);
    if (sectionMatch) {
      currentSection = sectionMatch[1].trim();
      continue;
    }

    const checkMatch = lines[i].match(/^[-*]\s+\[[ x]\]\s+(.+)/i);
    if (checkMatch) {
      const title = checkMatch[1].trim();
      const description = collectIndentedDescription(lines, i + 1);
      tasks.push({
        title,
        description: description || `Task from section: ${currentSection || "root"}`,
        priority: inferPriority(title, tasks.length),
        dependencies: [],
        estimatedComplexity: inferComplexity(title, description),
      });
    }
  }

  return tasks;
}

function extractNumberedTasks(lines: string[]): TaskPlan[] {
  const tasks: TaskPlan[] = [];
  let currentSection = "";

  for (let i = 0; i < lines.length; i++) {
    const sectionMatch = lines[i].match(/^##\s+(.+)/);
    if (sectionMatch) {
      currentSection = sectionMatch[1].trim();
      continue;
    }

    const numMatch = lines[i].match(/^\d+\.\s+(.+)/);
    if (numMatch) {
      const title = numMatch[1].trim();
      const description = collectIndentedDescription(lines, i + 1);
      tasks.push({
        title,
        description: description || `Step from section: ${currentSection || "root"}`,
        priority: inferPriority(title, tasks.length),
        dependencies: [],
        estimatedComplexity: inferComplexity(title, description),
      });
    }
  }

  return tasks;
}

function extractSectionTasks(lines: string[]): TaskPlan[] {
  const tasks: TaskPlan[] = [];
  let currentTitle = "";
  const bodyLines: string[] = [];

  const flushSection = () => {
    if (!currentTitle) return;
    // Skip non-task sections
    const skip = /^(overview|introduction|summary|background|goals|scope|references|appendix)/i;
    if (skip.test(currentTitle)) return;

    const description = bodyLines.join("\n").trim();
    if (!description) return;

    tasks.push({
      title: currentTitle,
      description,
      priority: inferPriority(currentTitle, tasks.length),
      dependencies: [],
      estimatedComplexity: inferComplexity(currentTitle, description),
    });
  };

  for (const line of lines) {
    const h2 = line.match(/^##\s+(.+)/);
    if (h2) {
      flushSection();
      currentTitle = h2[1].trim();
      bodyLines.length = 0;
      continue;
    }
    // Skip H1 and H3+ for section body
    if (/^#+\s+/.test(line)) continue;
    bodyLines.push(line);
  }
  flushSection();

  return tasks;
}

// ── Helpers ─────────────────────────────────────────────────────────────

function collectIndentedDescription(lines: string[], startIndex: number): string {
  const desc: string[] = [];
  for (let i = startIndex; i < lines.length; i++) {
    const line = lines[i];
    // Stop at next list item, header, or blank line after content
    if (/^[-*]\s+\[[ x]\]/i.test(line)) break;
    if (/^\d+\.\s+/.test(line)) break;
    if (/^##?\s+/.test(line)) break;
    if (line.trim() === "" && desc.length > 0) break;
    if (line.trim() === "") continue;
    desc.push(line.trim());
  }
  return desc.join(" ");
}

function inferPriority(
  title: string,
  index: number,
): TaskPlan["priority"] {
  const lower = title.toLowerCase();
  if (lower.includes("critical") || lower.includes("security") || lower.includes("auth")) {
    return "critical";
  }
  if (lower.includes("core") || lower.includes("database") || lower.includes("schema")) {
    return "high";
  }
  // Earlier tasks tend to be foundational
  if (index < 2) return "high";
  if (lower.includes("test") || lower.includes("doc") || lower.includes("deploy")) {
    return "low";
  }
  return "medium";
}

function inferComplexity(title: string, description: string): TaskComplexity {
  const text = `${title} ${description}`.toLowerCase();
  const complexIndicators = ["database", "migration", "auth", "integration", "api", "schema", "security"];
  const simpleIndicators = ["config", "readme", "doc", "rename", "env", "setup"];

  const complexScore = complexIndicators.filter((w) => text.includes(w)).length;
  const simpleScore = simpleIndicators.filter((w) => text.includes(w)).length;

  if (complexScore >= 2) return "high";
  if (simpleScore >= 2 || (simpleScore > 0 && complexScore === 0)) return "low";
  return "medium";
}

function inferSequentialDependencies(tasks: TaskPlan[]): void {
  for (let i = 1; i < tasks.length; i++) {
    // Each task depends on the one before it (simple sequential chain)
    tasks[i].dependencies.push(tasks[i - 1].title);
  }
}
