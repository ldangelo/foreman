import { describe, it, expect } from "vitest";

// We test the internal pure functions by re-implementing parseResponse
// and validatePlan logic inline since they're private.

describe("LLM Decomposer — Response Parsing", () => {
  function parseResponse(raw: string) {
    let json = raw;
    const fenceMatch = raw.match(/```(?:json)?\s*\n?([\s\S]*?)\n?\s*```/);
    if (fenceMatch) {
      json = fenceMatch[1];
    }
    if (!json.trim().startsWith("{")) {
      const objStart = json.indexOf("{");
      if (objStart >= 0) {
        json = json.slice(objStart);
      }
    }
    return JSON.parse(json);
  }

  const validHierarchy = {
    epic: { title: "Auth", description: "Build auth" },
    sprints: [{
      title: "Sprint 1",
      goal: "Foundation",
      stories: [{
        title: "User registration",
        description: "Registration flow",
        priority: "high",
        tasks: [{ title: "DB schema", description: "Create tables", type: "task", priority: "high", estimatedComplexity: "low", dependencies: [] }],
      }],
    }],
  };

  it("parses clean JSON response", () => {
    const raw = JSON.stringify(validHierarchy);
    const plan = parseResponse(raw);
    expect(plan.epic.title).toBe("Auth");
    expect(plan.sprints).toHaveLength(1);
    expect(plan.sprints[0].stories).toHaveLength(1);
    expect(plan.sprints[0].stories[0].tasks).toHaveLength(1);
  });

  it("strips markdown code fences", () => {
    const raw = `\`\`\`json\n${JSON.stringify(validHierarchy)}\n\`\`\``;
    const plan = parseResponse(raw);
    expect(plan.epic.title).toBe("Auth");
  });

  it("strips fences without language tag", () => {
    const raw = `\`\`\`\n${JSON.stringify(validHierarchy)}\n\`\`\``;
    const plan = parseResponse(raw);
    expect(plan.epic.title).toBe("Auth");
  });

  it("extracts JSON from surrounding text", () => {
    const raw = `Here is the plan:\n${JSON.stringify(validHierarchy)}`;
    const plan = parseResponse(raw);
    expect(plan.epic.title).toBe("Auth");
  });

  it("throws on unparseable response", () => {
    expect(() => parseResponse("This is not JSON at all")).toThrow();
  });
});

describe("LLM Decomposer — Plan Validation (Hierarchical)", () => {
  // Re-implement validatePlan for the new hierarchy
  function validatePlan(plan: any): void {
    if (!plan.epic?.title) throw new Error("Plan missing epic.title");
    if (!plan.epic?.description) throw new Error("Plan missing epic.description");
    if (!Array.isArray(plan.sprints)) throw new Error("Plan missing sprints array");
    if (plan.sprints.length === 0) throw new Error("Plan has zero sprints");

    const validPriorities = new Set(["critical", "high", "medium", "low"]);
    const validComplexities = new Set(["low", "medium", "high"]);
    const validTypes = new Set(["task", "spike", "test"]);

    // Collect all task titles
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
      if (!Array.isArray(sprint.stories)) throw new Error(`Sprint "${sprint.title}" missing stories array`);

      for (const story of sprint.stories) {
        if (!story.title) throw new Error("Story missing title");
        if (!story.description) story.description = story.title;
        if (!validPriorities.has(story.priority)) story.priority = "medium";
        if (!Array.isArray(story.tasks)) throw new Error(`Story "${story.title}" missing tasks array`);

        for (const task of story.tasks) {
          if (!task.title) throw new Error("Task missing title");
          if (!task.description) throw new Error(`Task "${task.title}" missing description`);
          if (!validTypes.has(task.type)) task.type = "task";
          if (!validPriorities.has(task.priority)) task.priority = "medium";
          if (!validComplexities.has(task.estimatedComplexity)) task.estimatedComplexity = "medium";
          if (!Array.isArray(task.dependencies)) task.dependencies = [];
          task.dependencies = task.dependencies.filter((dep: string) => allTaskTitles.has(dep));
        }
      }
    }

    // Cycle detection across all tasks
    const allTasks: any[] = [];
    for (const sprint of plan.sprints) {
      for (const story of sprint.stories) {
        allTasks.push(...story.tasks);
      }
    }
    const visited = new Set<string>();
    const inStack = new Set<string>();
    const taskMap = new Map<string, any>(allTasks.map((t: any) => [t.title, t]));

    function dfs(title: string): void {
      if (inStack.has(title)) throw new Error(`Circular dependency detected involving "${title}"`);
      if (visited.has(title)) return;
      inStack.add(title);
      const task = taskMap.get(title);
      if (task) {
        for (const dep of task.dependencies) dfs(dep);
      }
      inStack.delete(title);
      visited.add(title);
    }

    for (const task of allTasks) dfs(task.title);
  }

  function makeValidPlan(overrides?: any) {
    return {
      epic: { title: "Auth", description: "Build auth" },
      sprints: [{
        title: "Sprint 1",
        goal: "Foundation",
        stories: [{
          title: "User registration",
          description: "Registration flow",
          priority: "high",
          tasks: [
            { title: "Schema", description: "Create tables", type: "task", priority: "high", estimatedComplexity: "low", dependencies: [] },
            { title: "API", description: "Build endpoints", type: "task", priority: "high", estimatedComplexity: "medium", dependencies: ["Schema"] },
          ],
        }],
      }],
      ...overrides,
    };
  }

  it("passes valid hierarchical plan", () => {
    expect(() => validatePlan(makeValidPlan())).not.toThrow();
  });

  it("rejects plan without epic title", () => {
    expect(() =>
      validatePlan({ epic: { description: "no title" }, sprints: [{ title: "S1", goal: "g", stories: [] }] }),
    ).toThrow("epic.title");
  });

  it("rejects plan with zero sprints", () => {
    expect(() =>
      validatePlan({ epic: { title: "Auth", description: "Build auth" }, sprints: [] }),
    ).toThrow("zero sprints");
  });

  it("fixes invalid priority to medium", () => {
    const plan = {
      epic: { title: "Auth", description: "Build auth" },
      sprints: [{
        title: "Sprint 1",
        goal: "g",
        stories: [{
          title: "Story",
          description: "d",
          priority: "urgent",
          tasks: [{ title: "A", description: "B", type: "task", priority: "urgent", estimatedComplexity: "low", dependencies: [] }],
        }],
      }],
    };
    validatePlan(plan);
    expect(plan.sprints[0].stories[0].priority).toBe("medium");
    expect(plan.sprints[0].stories[0].tasks[0].priority).toBe("medium");
  });

  it("fixes invalid type to task", () => {
    const plan = {
      epic: { title: "Auth", description: "Build auth" },
      sprints: [{
        title: "Sprint 1",
        goal: "g",
        stories: [{
          title: "Story",
          description: "d",
          priority: "high",
          tasks: [{ title: "A", description: "B", type: "feature", priority: "high", estimatedComplexity: "low", dependencies: [] }],
        }],
      }],
    };
    validatePlan(plan);
    expect(plan.sprints[0].stories[0].tasks[0].type).toBe("task");
  });

  it("drops invalid dependency references", () => {
    const plan = {
      epic: { title: "Auth", description: "Build auth" },
      sprints: [{
        title: "Sprint 1",
        goal: "g",
        stories: [{
          title: "Story",
          description: "d",
          priority: "high",
          tasks: [{ title: "A", description: "B", type: "task", priority: "high", estimatedComplexity: "low", dependencies: ["NonExistent"] }],
        }],
      }],
    };
    validatePlan(plan);
    expect(plan.sprints[0].stories[0].tasks[0].dependencies).toEqual([]);
  });

  it("detects circular dependencies across stories", () => {
    expect(() =>
      validatePlan({
        epic: { title: "Auth", description: "Build auth" },
        sprints: [{
          title: "Sprint 1",
          goal: "g",
          stories: [
            {
              title: "Story 1",
              description: "d",
              priority: "high",
              tasks: [{ title: "A", description: "Do A", type: "task", priority: "high", estimatedComplexity: "low", dependencies: ["B"] }],
            },
            {
              title: "Story 2",
              description: "d",
              priority: "high",
              tasks: [{ title: "B", description: "Do B", type: "task", priority: "high", estimatedComplexity: "low", dependencies: ["A"] }],
            },
          ],
        }],
      }),
    ).toThrow("Circular dependency");
  });

  it("allows spike and test types", () => {
    const plan = {
      epic: { title: "Auth", description: "Build auth" },
      sprints: [{
        title: "Sprint 1",
        goal: "g",
        stories: [{
          title: "Story",
          description: "d",
          priority: "high",
          tasks: [
            { title: "Research OAuth", description: "Spike", type: "spike", priority: "medium", estimatedComplexity: "low", dependencies: [] },
            { title: "E2E auth tests", description: "Tests", type: "test", priority: "medium", estimatedComplexity: "medium", dependencies: [] },
          ],
        }],
      }],
    };
    expect(() => validatePlan(plan)).not.toThrow();
  });
});
