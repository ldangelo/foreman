import { describe, it, expect } from "vitest";
import { decomposePrd } from "../decomposer.js";

describe("decomposePrd", () => {
  it("extracts tasks from checkbox lists", async () => {
    const prd = `# My Epic
Some description.

## Tasks
- [ ] Build the API
- [ ] Create the database
`;
    const plan = await decomposePrd(prd, "/tmp");
    expect(plan.tasks).toHaveLength(2);
    expect(plan.tasks[0].title).toBe("Build the API");
    expect(plan.tasks[1].title).toBe("Create the database");
  });

  it("extracts tasks from numbered lists", async () => {
    const prd = `# My Epic
Description here.

## Steps
1. Initialize the project
2. Add dependencies
3. Write the code
`;
    const plan = await decomposePrd(prd, "/tmp");
    expect(plan.tasks).toHaveLength(3);
    expect(plan.tasks[0].title).toBe("Initialize the project");
    expect(plan.tasks[2].title).toBe("Write the code");
  });

  it("extracts tasks from H2 sections with body content", async () => {
    const prd = `# My Epic
Overview text.

## Authentication Module
Implement JWT-based auth with refresh tokens.

## Data Layer
Set up Prisma ORM with PostgreSQL.
`;
    const plan = await decomposePrd(prd, "/tmp");
    expect(plan.tasks).toHaveLength(2);
    expect(plan.tasks[0].title).toBe("Authentication Module");
    expect(plan.tasks[1].title).toBe("Data Layer");
  });

  it("infers priority from keywords (critical/high/medium/low)", async () => {
    const prd = `# Epic
## Tasks
- [ ] Fix critical security vulnerability
- [ ] Update core database schema
- [ ] Add logging middleware
- [ ] Write test suite
`;
    const plan = await decomposePrd(prd, "/tmp");
    expect(plan.tasks[0].priority).toBe("critical"); // "critical" + "security"
    expect(plan.tasks[1].priority).toBe("high"); // "core" + "database" + "schema"
    expect(plan.tasks[2].priority).toBe("medium");
    expect(plan.tasks[3].priority).toBe("low"); // "test"
  });

  it("infers complexity from keywords", async () => {
    const prd = `# Epic
## Tasks
- [ ] Set up database migration and auth integration
- [ ] Update config and readme
- [ ] Add a new button
`;
    const plan = await decomposePrd(prd, "/tmp");
    expect(plan.tasks[0].estimatedComplexity).toBe("high"); // database + migration + auth + integration
    expect(plan.tasks[1].estimatedComplexity).toBe("low"); // config + readme
    expect(plan.tasks[2].estimatedComplexity).toBe("medium");
  });

  it("chains sequential dependencies within task list", async () => {
    const prd = `# Epic
## Tasks
- [ ] Step one
- [ ] Step two
- [ ] Step three
`;
    const plan = await decomposePrd(prd, "/tmp");
    expect(plan.tasks[0].dependencies).toEqual([]);
    expect(plan.tasks[1].dependencies).toEqual(["Step one"]);
    expect(plan.tasks[2].dependencies).toEqual(["Step two"]);
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

  it("handles multiple sections with different task types", async () => {
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
    // Checklist items across sections are all collected
    expect(plan.tasks).toHaveLength(4);
    expect(plan.tasks[0].title).toBe("Create project scaffold");
    expect(plan.tasks[3].title).toBe("Add rate limiting");
    // Sequential deps chain across all tasks
    expect(plan.tasks[3].dependencies).toEqual(["Implement auth flow"]);
  });
});
