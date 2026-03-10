import { Hono } from "hono";
import { cors } from "hono/cors";
import { serve } from "@hono/node-server";
import type { Server } from "node:http";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { ForemanStore } from "../lib/store.js";
import { BeadsClient } from "../lib/beads.js";
import { Dispatcher } from "../orchestrator/dispatcher.js";
import { Refinery } from "../orchestrator/refinery.js";
import { attachWebSocket, broadcast, shutdownWs } from "./ws.js";

// ── Hono app ─────────────────────────────────────────────────────────────

const app = new Hono();
app.use("*", cors());

const store = new ForemanStore();

// ── Static files ─────────────────────────────────────────────────────────

const __dirname = fileURLToPath(new URL(".", import.meta.url));
const publicDir = join(__dirname, "public");

app.get("/", async (c) => {
  try {
    const html = await readFile(join(publicDir, "index.html"), "utf-8");
    return c.html(html);
  } catch {
    return c.text("Foreman Dashboard — public/index.html not found", 404);
  }
});

// ── API: Projects ────────────────────────────────────────────────────────

app.get("/api/projects", async (c) => {
  const projects = store.listProjects();
  const results = await Promise.all(
    projects.map(async (project) => {
      let taskStats = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
      try {
        const beads = new BeadsClient(project.path);
        if (await beads.isInitialized()) {
          const allBeads = await beads.list();
          const readyBeads = await beads.ready();
          const readyIds = new Set(readyBeads.map((b) => b.id));
          taskStats.total = allBeads.length;
          for (const b of allBeads) {
            if (b.status === "closed" || b.status === "completed") taskStats.completed++;
            else if (b.status === "in-progress" || b.status === "active") taskStats.inProgress++;
            else if (readyIds.has(b.id)) taskStats.ready++;
            else taskStats.blocked++;
          }
        }
      } catch {
        // beads not available — leave zeros
      }

      const activeRuns = store.getActiveRuns(project.id);
      const costs = store.getCosts(project.id);
      const totalCost = costs.reduce((sum, c) => sum + c.estimated_cost, 0);
      const progress =
        taskStats.total > 0
          ? Math.round((taskStats.completed / taskStats.total) * 100)
          : 0;

      return {
        id: project.id,
        name: project.name,
        path: project.path,
        status: project.status,
        taskStats,
        activeAgents: activeRuns.length,
        totalCost,
        progress,
      };
    }),
  );
  return c.json(results);
});

app.get("/api/projects/:id", async (c) => {
  const project = store.getProject(c.req.param("id"));
  if (!project) return c.json({ error: "Project not found" }, 404);

  let beads: unknown[] = [];
  let graph = { nodes: [] as unknown[], edges: [] as unknown[] };
  try {
    const client = new BeadsClient(project.path);
    if (await client.isInitialized()) {
      beads = await client.list();
      graph = await client.getGraph();
    }
  } catch {
    // beads unavailable
  }

  const runs = store.getActiveRuns(project.id);
  const events = store.getEvents(project.id, 50);

  return c.json({ project, beads, graph, runs, events });
});

// ── API: Runs ────────────────────────────────────────────────────────────

app.get("/api/projects/:id/runs", (c) => {
  const id = c.req.param("id");
  const active = store.getActiveRuns(id);
  const completed = store.getRunsByStatus("completed", id);
  const failed = store.getRunsByStatus("failed", id);
  const recent = [...completed, ...failed]
    .sort((a, b) => (b.completed_at ?? "").localeCompare(a.completed_at ?? ""))
    .slice(0, 20);
  return c.json({ active, recent });
});

// ── API: Events ──────────────────────────────────────────────────────────

app.get("/api/projects/:id/events", (c) => {
  const id = c.req.param("id");
  const limit = Number(c.req.query("limit") ?? "50");
  const typeParam = c.req.query("type");

  if (typeParam) {
    // Support comma-separated event types by fetching all and filtering
    const types = new Set(typeParam.split(",").map((t) => t.trim()));
    const allEvents = store.getEvents(id, limit * 3); // fetch extra to filter
    const filtered = allEvents.filter((e) => types.has(e.event_type)).slice(0, limit);
    return c.json(filtered);
  }

  return c.json(store.getEvents(id, limit));
});

// ── API: Costs ───────────────────────────────────────────────────────────

app.get("/api/projects/:id/costs", (c) => {
  const id = c.req.param("id");
  const costs = store.getCosts(id);

  const total = costs.reduce((sum, co) => sum + co.estimated_cost, 0);

  // Cost by runtime: join costs with runs to get agent_type
  const byRuntime: Record<string, number> = {};
  for (const co of costs) {
    const run = store.getRun(co.run_id);
    if (run) {
      byRuntime[run.agent_type] = (byRuntime[run.agent_type] ?? 0) + co.estimated_cost;
    }
  }

  // Cost by day
  const byDayMap = new Map<string, number>();
  for (const co of costs) {
    const date = co.recorded_at.split("T")[0];
    byDayMap.set(date, (byDayMap.get(date) ?? 0) + co.estimated_cost);
  }
  const byDay = [...byDayMap.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, cost]) => ({ date, cost }));

  return c.json({ total, byRuntime, byDay });
});

// ── API: Dispatch ────────────────────────────────────────────────────────

app.post("/api/projects/:id/dispatch", async (c) => {
  const project = store.getProject(c.req.param("id"));
  if (!project) return c.json({ error: "Project not found" }, 404);

  const body = await c.req.json().catch(() => ({}));
  const beads = new BeadsClient(project.path);
  const dispatcher = new Dispatcher(beads, store, project.path);

  const result = await dispatcher.dispatch({
    maxAgents: body.maxAgents,
    runtime: body.runtime,
    projectId: project.id,
  });

  // Broadcast dispatched tasks
  for (const task of result.dispatched) {
    broadcast({ type: "dispatch", data: task });
  }

  return c.json(result);
});

// ── API: Pause / Resume ──────────────────────────────────────────────────

app.post("/api/projects/:id/pause", (c) => {
  const project = store.getProject(c.req.param("id"));
  if (!project) return c.json({ error: "Project not found" }, 404);
  store.updateProject(project.id, { status: "paused" });
  return c.json({ ok: true, status: "paused" });
});

app.post("/api/projects/:id/resume", (c) => {
  const project = store.getProject(c.req.param("id"));
  if (!project) return c.json({ error: "Project not found" }, 404);
  store.updateProject(project.id, { status: "active" });
  return c.json({ ok: true, status: "active" });
});

// ── API: Merge (Refinery) ────────────────────────────────────────────────

app.post("/api/projects/:id/merge", async (c) => {
  const project = store.getProject(c.req.param("id"));
  if (!project) return c.json({ error: "Project not found" }, 404);

  const body = await c.req.json().catch(() => ({}));
  const beads = new BeadsClient(project.path);
  const refinery = new Refinery(store, beads, project.path);

  const report = await refinery.mergeCompleted({
    targetBranch: body.targetBranch,
    runTests: body.runTests,
    testCommand: body.testCommand,
    projectId: project.id,
  });

  // Broadcast merge events
  for (const m of report.merged) {
    broadcast({ type: "merge", data: m });
  }

  return c.json(report);
});

// ── API: Agents (cross-project) ──────────────────────────────────────────

app.get("/api/agents", (c) => {
  const activeRuns = store.getActiveRuns();
  const now = Date.now();

  const agents = activeRuns.map((run) => {
    const project = store.getProject(run.project_id);
    const elapsed = run.started_at
      ? Math.round((now - new Date(run.started_at).getTime()) / 1000)
      : 0;
    return {
      run,
      project: project ? { id: project.id, name: project.name } : null,
      bead: run.bead_id,
      elapsed,
    };
  });

  return c.json(agents);
});

// ── API: Metrics ─────────────────────────────────────────────────────────

app.get("/api/metrics", (c) => {
  const since = c.req.query("since");
  const projectId = c.req.query("projectId");
  const metrics = store.getMetrics(projectId ?? undefined, since ?? undefined);

  // Compute costByRuntime keyed by agent_type
  const costByRuntime: Record<string, number> = {};
  for (const entry of metrics.costByRuntime) {
    const run = store.getRun(entry.run_id);
    if (run) {
      costByRuntime[run.agent_type] =
        (costByRuntime[run.agent_type] ?? 0) + entry.cost;
    }
  }

  // Count completed today
  const todayStr = new Date().toISOString().split("T")[0];
  const completedRuns = store.getRunsByStatus("completed", projectId ?? undefined);
  const completedToday = completedRuns.filter(
    (r) => r.completed_at && r.completed_at.startsWith(todayStr),
  ).length;

  // Average task duration from runs that have both started_at and completed_at
  const durations = metrics.costByRuntime
    .map((e) => e.duration_seconds)
    .filter((d): d is number => d !== null && d > 0);
  const avgTaskDuration =
    durations.length > 0
      ? Math.round(durations.reduce((a, b) => a + b, 0) / durations.length)
      : 0;

  return c.json({
    totalCost: metrics.totalCost,
    totalTokens: metrics.totalTokens,
    tasksByStatus: metrics.tasksByStatus,
    costByRuntime,
    completedToday,
    avgTaskDuration,
  });
});

// ── Server startup ───────────────────────────────────────────────────────

const PORT = 3850;

export function startServer(): { close: () => Promise<void> } {
  const server = serve({ fetch: app.fetch, port: PORT }) as unknown as Server;

  // Attach WebSocket upgrade handler
  attachWebSocket(server);

  console.log(`Foreman Dashboard running on http://localhost:${PORT}`);

  const close = async () => {
    await shutdownWs();
    await new Promise<void>((resolve, reject) => {
      server.close((err) => (err ? reject(err) : resolve()));
    });
    store.close();
  };

  return { close };
}

// Allow running directly: tsx src/dashboard/server.ts
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, "/"))) {
  const { close } = startServer();
  const shutdown = async () => {
    console.log("\nShutting down...");
    await close();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}
