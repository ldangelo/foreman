import { describe, it, expect } from "vitest";
import { decomposePrd } from "../decomposer.js";

describe("decomposePrd", () => {
  it("produces epic → sprint → story → task hierarchy from sections with checklists", async () => {
    const prd = `# My Epic
Some description.

## Authentication
- [ ] Build the auth API
- [ ] Create the user database

## Dashboard
- [ ] Build dashboard UI
`;
    const plan = await decomposePrd(prd, "/tmp");
    expect(plan.epic.title).toBe("My Epic");
    expect(plan.sprints.length).toBeGreaterThanOrEqual(1);

    // Flatten all stories
    const stories = plan.sprints.flatMap((s) => s.stories);
    expect(stories.length).toBe(2);
    expect(stories[0].title).toBe("Authentication");
    expect(stories[0].tasks).toHaveLength(2);
    expect(stories[0].tasks[0].title).toBe("Build the auth API");
    expect(stories[0].tasks[0].type).toBe("task");
    expect(stories[1].title).toBe("Dashboard");
    expect(stories[1].tasks).toHaveLength(1);
  });

  it("extracts tasks from numbered lists within sections", async () => {
    const prd = `# My Epic
Description here.

## Setup Steps
1. Initialize the project
2. Add dependencies
3. Write the code
`;
    const plan = await decomposePrd(prd, "/tmp");
    const stories = plan.sprints.flatMap((s) => s.stories);
    expect(stories).toHaveLength(1);
    expect(stories[0].tasks).toHaveLength(3);
    expect(stories[0].tasks[0].title).toBe("Initialize the project");
    expect(stories[0].tasks[2].title).toBe("Write the code");
  });

  it("creates stories from H2 sections with body content (no task lists)", async () => {
    const prd = `# My Epic
Overview text.

## Authentication Module
Implement JWT-based auth with refresh tokens.

## Data Layer
Set up Prisma ORM with PostgreSQL.
`;
    const plan = await decomposePrd(prd, "/tmp");
    const stories = plan.sprints.flatMap((s) => s.stories);
    expect(stories).toHaveLength(2);
    expect(stories[0].title).toBe("Authentication Module");
    // Section body becomes a single task within the story
    expect(stories[0].tasks).toHaveLength(1);
    expect(stories[0].tasks[0].title).toBe("Authentication Module");
  });

  it("infers priority from keywords (critical/high/medium/low)", async () => {
    const prd = `# Epic

## Security
- [ ] Fix critical security vulnerability
- [ ] Update core database schema

## Extras
- [ ] Add logging middleware
- [ ] Improve error messages
- [ ] Optimize queries
- [ ] Write test suite
`;
    const plan = await decomposePrd(prd, "/tmp");
    const stories = plan.sprints.flatMap((s) => s.stories);
    const securityTasks = stories.find((s) => s.title === "Security")!.tasks;
    const extraTasks = stories.find((s) => s.title === "Extras")!.tasks;

    expect(securityTasks[0].priority).toBe("critical"); // "critical" + "security"
    expect(securityTasks[1].priority).toBe("high"); // "core" + "database" + "schema"
    // Keywords take precedence over index heuristic
    expect(extraTasks[0].priority).toBe("high"); // index 0, no keyword match
    expect(extraTasks[3].priority).toBe("low"); // "test" keyword
  });

  it("infers complexity from keywords", async () => {
    const prd = `# Epic

## Work
- [ ] Set up database migration and auth integration
- [ ] Update config and readme
- [ ] Add a new button
`;
    const plan = await decomposePrd(prd, "/tmp");
    const tasks = plan.sprints.flatMap((s) => s.stories).flatMap((s) => s.tasks);
    expect(tasks[0].estimatedComplexity).toBe("high");
    expect(tasks[1].estimatedComplexity).toBe("low");
    expect(tasks[2].estimatedComplexity).toBe("medium");
  });

  it("chains sequential dependencies within a story", async () => {
    const prd = `# Epic

## Steps
- [ ] Step one
- [ ] Step two
- [ ] Step three
`;
    const plan = await decomposePrd(prd, "/tmp");
    const tasks = plan.sprints[0].stories[0].tasks;
    expect(tasks[0].dependencies).toEqual([]);
    expect(tasks[1].dependencies).toEqual(["Step one"]);
    expect(tasks[2].dependencies).toEqual(["Step two"]);
  });

  it("throws on empty input", async () => {
    await expect(decomposePrd("", "/tmp")).rejects.toThrow("No tasks found");
  });

  it("throws on markdown with no extractable tasks", async () => {
    const prd = `# My Epic
Just some prose with no lists or actionable sections.
`;
    await expect(decomposePrd(prd, "/tmp")).rejects.toThrow("No tasks found");
  });

  it("sets epic title from first H1 heading", async () => {
    const prd = `# Build a Spaceship
Some text.

## Tasks
- [ ] Gather materials
`;
    const plan = await decomposePrd(prd, "/tmp");
    expect(plan.epic.title).toBe("Build a Spaceship");
  });

  it("groups stories across sections into sprints", async () => {
    const prd = `# Multi-Section Epic
Description.

## Phase 1
- [ ] Create project scaffold
- [ ] Set up CI pipeline

## Phase 2
- [ ] Implement auth flow
- [ ] Add rate limiting
`;
    const plan = await decomposePrd(prd, "/tmp");
    const stories = plan.sprints.flatMap((s) => s.stories);
    expect(stories).toHaveLength(2);
    expect(stories[0].tasks).toHaveLength(2);
    expect(stories[1].tasks).toHaveLength(2);
  });

  it("infers spike type from title keywords", async () => {
    const prd = `# Epic

## Research
- [ ] Spike on database options
- [ ] Investigate caching strategies
`;
    const plan = await decomposePrd(prd, "/tmp");
    const tasks = plan.sprints.flatMap((s) => s.stories).flatMap((s) => s.tasks);
    expect(tasks[0].type).toBe("spike");
    expect(tasks[1].type).toBe("spike");
  });

  it("infers test type from title keywords", async () => {
    const prd = `# Epic

## Testing
- [ ] Write integration test suite for auth
- [ ] Create e2e test for checkout flow
`;
    const plan = await decomposePrd(prd, "/tmp");
    const tasks = plan.sprints.flatMap((s) => s.stories).flatMap((s) => s.tasks);
    expect(tasks[0].type).toBe("test");
    expect(tasks[1].type).toBe("test");
  });

  it("all tasks default to type 'task'", async () => {
    const prd = `# Epic

## Work
- [ ] Build the API
- [ ] Create the frontend
`;
    const plan = await decomposePrd(prd, "/tmp");
    const tasks = plan.sprints.flatMap((s) => s.stories).flatMap((s) => s.tasks);
    for (const task of tasks) {
      expect(task.type).toBe("task");
    }
  });

  it("puts all stories in one sprint when priorities are similar", async () => {
    const prd = `# Epic
Desc.

## Core Auth
- [ ] Fix critical auth vulnerability
- [ ] Update core database schema

## Polish
- [ ] Improve error messages
- [ ] Clean up output formatting
`;
    const plan = await decomposePrd(prd, "/tmp");
    // Both stories have high-priority tasks (index < 2 heuristic)
    // so they both land in a single sprint
    expect(plan.sprints.length).toBe(1);
    const stories = plan.sprints[0].stories;
    expect(stories).toHaveLength(2);
  });

  it("splits stories into two sprints when priorities differ", async () => {
    const prd = `# Epic
Desc.

## Core Auth
- [ ] Fix critical auth vulnerability
- [ ] Update core database schema

## Documentation
- [ ] Write the API docs
- [ ] Write the deployment docs
- [ ] Write the test plan docs
`;
    const plan = await decomposePrd(prd, "/tmp");
    // Core Auth → critical/high → Sprint 1
    // Documentation → all "low" (doc keyword overrides index) → Sprint 2
    expect(plan.sprints.length).toBe(2);
    expect(plan.sprints[0].title).toContain("Foundation");
    expect(plan.sprints[1].title).toContain("Implementation");
  });
});
