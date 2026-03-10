import type { DecompositionPlan, SprintPlan, StoryPlan, TaskPlan, TaskComplexity, IssueType } from "./types.js";

/**
 * Heuristic PRD decomposer.
 *
 * Extracts structure from a markdown PRD/TRD by looking for:
 * - H1 as epic title
 * - H2 sections as stories (grouped into a single sprint)
 * - Task lists (- [ ] items) or numbered lists as tasks within stories
 * - Ordering-based dependency inference within each story
 *
 * Produces: epic → sprint → story → task hierarchy.
 */
export async function decomposePrd(
  prdContent: string,
  _projectPath: string,
): Promise<DecompositionPlan> {
  const lines = prdContent.split("\n");

  const epicTitle = extractEpicTitle(lines);
  const epicDescription = extractEpicDescription(lines);
  const stories = extractStories(lines);

  if (stories.length === 0) {
    throw new Error(
      "No tasks found in PRD. Expected task lists (- [ ] items), numbered lists, or ## sections with content.",
    );
  }

  // Group stories into sprints heuristically:
  // - Stories with critical/high priority go into Sprint 1 (Foundation)
  // - Remaining go into Sprint 2 (Implementation)
  const sprint1Stories: StoryPlan[] = [];
  const sprint2Stories: StoryPlan[] = [];

  for (const story of stories) {
    if (story.priority === "critical" || story.priority === "high") {
      sprint1Stories.push(story);
    } else {
      sprint2Stories.push(story);
    }
  }

  // If everything ended up in one bucket, just use one sprint
  const sprints: SprintPlan[] = [];
  if (sprint1Stories.length > 0 && sprint2Stories.length > 0) {
    sprints.push({
      title: "Sprint 1: Foundation",
      goal: "Core infrastructure and high-priority features",
      stories: sprint1Stories,
    });
    sprints.push({
      title: "Sprint 2: Implementation",
      goal: "Secondary features and refinements",
      stories: sprint2Stories,
    });
  } else {
    sprints.push({
      title: "Sprint 1: Implementation",
      goal: "All planned work items",
      stories: stories,
    });
  }

  return {
    epic: { title: epicTitle, description: epicDescription },
    sprints,
  };
}

// ── Extractors ──────────────────────────────────────────────────────────

function extractEpicTitle(lines: string[]): string {
  for (const line of lines) {
    const h1 = line.match(/^#\s+(.+)/);
    if (h1) return h1[1].trim();
  }
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed) return trimmed;
  }
  return "Untitled Epic";
}

function extractEpicDescription(lines: string[]): string {
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

/**
 * Extract stories from H2 sections.
 * Tasks within each section become the story's tasks.
 * If no H2 sections exist, creates a single story from all tasks.
 */
function extractStories(lines: string[]): StoryPlan[] {
  const sections = extractSections(lines);

  if (sections.length === 0) {
    // No H2 sections — try to extract tasks from the whole document
    const tasks = extractTasksFromLines(lines);
    if (tasks.length === 0) return [];
    return [{
      title: "Implementation",
      description: "Tasks extracted from document",
      priority: tasks[0].priority,
      tasks,
    }];
  }

  const stories: StoryPlan[] = [];
  for (const section of sections) {
    // Skip non-task sections
    const skip = /^(overview|introduction|summary|background|goals|scope|references|appendix)/i;
    if (skip.test(section.title)) continue;

    const tasks = extractTasksFromLines(section.bodyLines);
    if (tasks.length === 0) {
      // Section has content but no explicit tasks — make the section itself a single task
      const bodyText = section.bodyLines.join("\n").trim();
      if (!bodyText) continue;
      tasks.push({
        title: section.title,
        description: bodyText,
        type: inferIssueType(section.title),
        priority: inferPriority(section.title, 0),
        dependencies: [],
        estimatedComplexity: inferComplexity(section.title, bodyText),
      });
    }

    const storyPriority = tasks.length > 0
      ? tasks.reduce((highest, t) => priorityRank(t.priority) < priorityRank(highest) ? t.priority : highest, tasks[0].priority)
      : "medium" as const;

    stories.push({
      title: section.title,
      description: section.bodyLines.join("\n").trim() || `Story: ${section.title}`,
      priority: storyPriority,
      tasks,
    });
  }

  return stories;
}

interface Section {
  title: string;
  bodyLines: string[];
}

function extractSections(lines: string[]): Section[] {
  const sections: Section[] = [];
  let currentTitle = "";
  let bodyLines: string[] = [];

  const flush = () => {
    if (currentTitle) {
      sections.push({ title: currentTitle, bodyLines: [...bodyLines] });
    }
  };

  for (const line of lines) {
    const h2 = line.match(/^##\s+(.+)/);
    if (h2) {
      flush();
      currentTitle = h2[1].trim();
      bodyLines = [];
      continue;
    }
    if (/^#\s+/.test(line)) continue; // skip H1
    if (currentTitle) bodyLines.push(line);
  }
  flush();

  return sections;
}

/**
 * Extract tasks from a set of lines (checklist items, numbered items).
 */
function extractTasksFromLines(lines: string[]): TaskPlan[] {
  // Try checklist first, then numbered
  const checklist = extractChecklistTasks(lines);
  if (checklist.length > 0) {
    inferSequentialDependencies(checklist);
    return checklist;
  }

  const numbered = extractNumberedTasks(lines);
  if (numbered.length > 0) {
    inferSequentialDependencies(numbered);
    return numbered;
  }

  return [];
}

function extractChecklistTasks(lines: string[]): TaskPlan[] {
  const tasks: TaskPlan[] = [];

  for (let i = 0; i < lines.length; i++) {
    const checkMatch = lines[i].match(/^[-*]\s+\[[ x]\]\s+(.+)/i);
    if (checkMatch) {
      const title = checkMatch[1].trim();
      const description = collectIndentedDescription(lines, i + 1);
      tasks.push({
        title,
        description: description || title,
        type: inferIssueType(title),
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

  for (let i = 0; i < lines.length; i++) {
    const numMatch = lines[i].match(/^\d+\.\s+(.+)/);
    if (numMatch) {
      const title = numMatch[1].trim();
      const description = collectIndentedDescription(lines, i + 1);
      tasks.push({
        title,
        description: description || title,
        type: inferIssueType(title),
        priority: inferPriority(title, tasks.length),
        dependencies: [],
        estimatedComplexity: inferComplexity(title, description),
      });
    }
  }

  return tasks;
}

// ── Helpers ─────────────────────────────────────────────────────────────

function collectIndentedDescription(lines: string[], startIndex: number): string {
  const desc: string[] = [];
  for (let i = startIndex; i < lines.length; i++) {
    const line = lines[i];
    if (/^[-*]\s+\[[ x]\]/i.test(line)) break;
    if (/^\d+\.\s+/.test(line)) break;
    if (/^##?\s+/.test(line)) break;
    if (line.trim() === "" && desc.length > 0) break;
    if (line.trim() === "") continue;
    desc.push(line.trim());
  }
  return desc.join(" ");
}

function inferIssueType(title: string): IssueType {
  const lower = title.toLowerCase();
  if (lower.includes("spike") || lower.includes("research") || lower.includes("investigate")) {
    return "spike";
  }
  if (lower.includes("e2e test") || lower.includes("integration test") || lower.includes("load test") || lower.includes("test suite")) {
    return "test";
  }
  return "task";
}

function inferPriority(
  title: string,
  index: number,
): TaskPlan["priority"] {
  const lower = title.toLowerCase();
  // Keyword matches take precedence over index heuristic
  if (lower.includes("critical") || lower.includes("security") || lower.includes("auth")) {
    return "critical";
  }
  if (lower.includes("core") || lower.includes("database") || lower.includes("schema")) {
    return "high";
  }
  if (lower.includes("test") || lower.includes("doc") || lower.includes("deploy")) {
    return "low";
  }
  // Earlier tasks tend to be foundational
  if (index < 2) return "high";
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

function priorityRank(p: string): number {
  switch (p) {
    case "critical": return 0;
    case "high": return 1;
    case "medium": return 2;
    case "low": return 3;
    default: return 2;
  }
}

function inferSequentialDependencies(tasks: TaskPlan[]): void {
  for (let i = 1; i < tasks.length; i++) {
    tasks[i].dependencies.push(tasks[i - 1].title);
  }
}
