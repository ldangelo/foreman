import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { readFile } from "node:fs/promises";
import { ForemanStore } from "../../lib/store.js";

/**
 * We rebuild the Hono app routes in-test using a real in-memory SQLite store,
 * avoiding side effects from importing server.ts (which auto-creates a store
 * at ~/.foreman and starts listening).
 */
function createTestApp(store: ForemanStore, publicDir: string) {
  const app = new Hono();
  app.use("*", cors());

  // Static files
  app.get("/", async (c) => {
    try {
      const html = await readFile(join(publicDir, "index.html"), "utf-8");
      return c.html(html);
    } catch {
      return c.text("Foreman Dashboard — public/index.html not found", 404);
    }
  });

  // API: Projects list
  app.get("/api/projects", (c) => {
    const projects = store.listProjects();
    const results = projects.map((project) => {
      const activeRuns = store.getActiveRuns(project.id);
      const costs = store.getCosts(project.id);
      const totalCost = costs.reduce((sum, co) => sum + co.estimated_cost, 0);
      return {
        id: project.id,
        name: project.name,
        path: project.path,
        status: project.status,
        activeAgents: activeRuns.length,
        totalCost,
      };
    });
    return c.json(results);
  });

  // API: Project detail
  app.get("/api/projects/:id", (c) => {
    const project = store.getProject(c.req.param("id"));
    if (!project) return c.json({ error: "Project not found" }, 404);
    const runs = store.getActiveRuns(project.id);
    const events = store.getEvents(project.id, 50);
    return c.json({ project, runs, events });
  });

  // API: Metrics
  app.get("/api/metrics", (c) => {
    const since = c.req.query("since");
    const projectId = c.req.query("projectId");
    const metrics = store.getMetrics(projectId ?? undefined, since ?? undefined);

    const costByRuntime: Record<string, number> = {};
    for (const entry of metrics.costByRuntime) {
      const run = store.getRun(entry.run_id);
      if (run) {
        costByRuntime[run.agent_type] =
          (costByRuntime[run.agent_type] ?? 0) + entry.cost;
      }
    }

    const todayStr = new Date().toISOString().split("T")[0];
    const completedRuns = store.getRunsByStatus("completed", projectId ?? undefined);
    const completedToday = completedRuns.filter(
      (r) => r.completed_at && r.completed_at.startsWith(todayStr),
    ).length;

    return c.json({
      totalCost: metrics.totalCost,
      totalTokens: metrics.totalTokens,
      tasksByStatus: metrics.tasksByStatus,
      costByRuntime,
      completedToday,
    });
  });

  // API: Agents
  app.get("/api/agents", (c) => {
    const activeRuns = store.getActiveRuns();
    const agents = activeRuns.map((run) => {
      const project = store.getProject(run.project_id);
      return {
        run,
        project: project ? { id: project.id, name: project.name } : null,
        bead: run.bead_id,
      };
    });
    return c.json(agents);
  });

  return app;
}

describe("Dashboard Server", () => {
  let store: ForemanStore;
  let tmpDir: string;
  let publicDir: string;
  let app: Hono;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-dash-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));

    publicDir = join(tmpDir, "public");
    mkdirSync(publicDir);
    writeFileSync(join(publicDir, "index.html"), "<html><body>Foreman</body></html>");

    app = createTestApp(store, publicDir);
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("GET /api/projects returns 200 with array", async () => {
    store.registerProject("proj-a", "/proj/a");
    const res = await app.request("/api/projects");
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(Array.isArray(data)).toBe(true);
    expect(data).toHaveLength(1);
    expect(data[0].name).toBe("proj-a");
  });

  it("GET /api/projects/:id returns project data", async () => {
    const project = store.registerProject("proj-b", "/proj/b");
    const res = await app.request(`/api/projects/${project.id}`);
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.project.id).toBe(project.id);
    expect(data.project.name).toBe("proj-b");
    expect(Array.isArray(data.runs)).toBe(true);
    expect(Array.isArray(data.events)).toBe(true);
  });

  it("GET /api/projects/:id returns 404 for unknown project", async () => {
    const res = await app.request("/api/projects/nonexistent-id");
    expect(res.status).toBe(404);
    const data = await res.json();
    expect(data.error).toBe("Project not found");
  });

  it("GET /api/metrics returns 200 with metrics object", async () => {
    const project = store.registerProject("proj-m", "/proj/m");
    const run = store.createRun(project.id, "bd-1", "claude-code");
    store.recordCost(run.id, 1000, 500, 0, 0.05);

    const res = await app.request("/api/metrics");
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(typeof data.totalCost).toBe("number");
    expect(typeof data.totalTokens).toBe("number");
    expect(data.tasksByStatus).toBeDefined();
    expect(data.costByRuntime).toBeDefined();
  });

  it("GET /api/agents returns 200 with array", async () => {
    const project = store.registerProject("proj-ag", "/proj/ag");
    store.createRun(project.id, "bd-1", "claude-code");

    const res = await app.request("/api/agents");
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(Array.isArray(data)).toBe(true);
    expect(data).toHaveLength(1);
    expect(data[0].bead).toBe("bd-1");
    expect(data[0].project.name).toBe("proj-ag");
  });

  it("GET / returns 200 with HTML content", async () => {
    const res = await app.request("/");
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).toContain("<html>");
    expect(text).toContain("Foreman");
  });
});
