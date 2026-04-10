# PRD: Multi-Agent Coding Orchestrator (Foreman)

**Author:** Leo D'Angelo / Jarvis
**Created:** 2026-03-10
**Status:** Draft
**Priority:** High
**Project:** Fortium / Ensemble

---

## Current-checkout note

This document captures the product direction, not a claim that every roadmap surface is already shipped in the current branch.

- Public day-to-day task tracking is still beads-first in this checkout: `br` / `.beads/` remain canonical.
- `foreman task` is currently bounded to transitional `import --from-beads` behavior rather than a full replacement task CLI.
- Treat newer PRDs (`PRD-2026-005`, `PRD-2026-006`, `PRD-2026-007`) and current code as the source of truth for recovery-era architecture details when this older document conflicts with them.

---

## 1. Executive Summary

Foreman is a multi-project orchestration service built on OpenClaw and task-tracking backends that ingests planning artifacts, decomposes work into executable backlogs, schedules AI agents across many projects, and coordinates validation and promotion through a shared control plane. Each project supplies a subordinate execution plane that isolates work in worktrees or workspaces, runs agent pipelines, and prepares completed work for integration.

Unlike Gastown or similar tools, Foreman is designed around a durable separation of concerns: the control plane decides what to run, where to run it, and when work is ready for approval; the execution plane handles the mechanics of implementation inside a single project. That separation is what makes the system client-deployable, multi-project, and runtime-agnostic rather than just a local agent runner.

### Key Differentiators
- Runtime-agnostic: Claude Code, Pi, Codex, Gemini — pick per task or project
- Built on OpenClaw (maintained platform, not a greenfield orchestrator)
- Multi-project control plane with shared scheduling, visibility, and approval flows
- Integration-branch validation before promotion to the default branch
- Client-ready via Ensemble

---

## 2. Problem Statement

### Current Pain Points
1. **No shared control plane** — Agents may run inside a repo, but there is no durable scheduler coordinating work across many active projects
2. **No unified visibility** — Operators cannot see fleet-wide work, validation status, and approval backlog in one place
3. **No planning-to-execution bridge** — PRD/TRD decomposition and executable work queues are disconnected from cross-project scheduling
4. **Git coordination drift** — Without explicit integration-branch semantics, completed work can land on the wrong branch boundary
5. **No cost/time tracking per task** — Can't measure ROI of multi-agent work across the fleet
6. **Client readiness** — A project-local runner is less deployable than a true orchestration service

### Who Is This For
- **Leo (primary)** — Run multi-project AI engineering workflows across personal and client projects
- **Fortium clients** — Deploy Foreman as part of Ensemble engagements
- **Solo developers / tech leads** — Coordinate several repositories without losing validation and approval truth

---

## 3. Goals & Success Criteria

| Goal | Success Metric |
|---|---|
| Decompose PRD into executable project work | PRD → TRD → task backlog in <2 minutes |
| Schedule agents across projects with isolation | N agents running across N project workspaces with zero cross-project conflicts |
| Validate on integration before promotion | Completed work lands on integration, passes validation, then becomes eligible for promotion |
| Real-time multi-project dashboard | See all projects, all agents, validation state, and approval backlog live |
| Cost tracking | Per-task and per-project token usage with estimated cost |
| Client deployable | Install + configure in <30 minutes |

---

## 4. Architecture

### 4.1 System Overview

```
┌───────────────────────────────────────────────────────────────┐
│                    Foreman Control Plane                     │
│   project registry • intake • scheduler • dashboard         │
│   validation policy • approval/promotion • fleet metrics    │
└────────────────────────────┬──────────────────────────────────┘
                             │
               dispatch / status / validation events
                             │
         ┌───────────────────┼───────────────────┐
         │                   │                   │
┌────────▼────────┐ ┌────────▼────────┐ ┌────────▼────────┐
│ Project A       │ │ Project B       │ │ Project C       │
│ execution plane │ │ execution plane │ │ execution plane │
│ dispatcher      │ │ dispatcher      │ │ dispatcher      │
│ workers         │ │ workers         │ │ workers         │
│ pipeline        │ │ pipeline        │ │ pipeline        │
│ merge/refinery  │ │ merge/refinery  │ │ merge/refinery  │
│ → integration   │ │ → integration   │ │ → integration   │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

### 4.2 Component Breakdown

#### 4.2.1 Foreman Control Plane (`foreman`)
The top-level CLI/service is responsible for:

- registering and describing projects
- ingesting PRDs, TRDs, and task backlogs
- selecting which project/task should consume the next unit of agent capacity
- aggregating dashboard/status signal across all active projects
- enforcing validation and approval policy before promotion

#### 4.2.2 Per-Project Execution Plane
Each project-local execution engine is responsible for:

- turning ready work into isolated worktrees or workspaces
- spawning agents and running the configured workflow
- recording run state, mail, and artifacts
- merging completed work onto the project's integration branch
- surfacing validation/promotion outcomes back to the control plane

#### 4.2.3 Dashboard
The dashboard is a control-plane surface, not just a local project viewer. It should show active projects, queue state, validation state, approval backlog, and cost/performance metrics in one place.


#### 4.2.4 State Stores
- **Global control-plane state** tracks project metadata, scheduling, and fleet-level visibility.
- **Per-project execution state** tracks runs, merge queues, artifacts, and local runtime history.

### 4.3 Integration Branch Model

Completed work should merge onto a project-specific integration branch first. Validation happens there. Promotion to the default branch is a distinct, auditable control-plane decision rather than an implicit side effect of worker completion.

---

## 5. Dashboard Specification

### 5.1 Views

#### Projects Overview (Home)
Multi-project view showing all registered Foreman projects at a glance.

```
┌─────────────────────────────────────────────────────────┐
│  Foreman Dashboard                              [Settings] │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌─── claude-metrics ──────────────────────────────┐    │
│  │ ● Active    3/5 tasks done    2 agents running  │    │
│  │ ████████████████░░░░░░░  60%   $4.20 spent      │    │
│  │ Est. completion: ~25 min       [View] [Pause]   │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  ┌─── oneplatform-agents ──────────────────────────┐    │
│  │ ● Active    1/8 tasks done    3 agents running  │    │
│  │ ██░░░░░░░░░░░░░░░░░░░░  12%   $1.80 spent      │    │
│  │ Est. completion: ~1h 10min    [View] [Pause]    │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  ┌─── ensemble ────────────────────────────────────┐    │
│  │ ○ Idle      Last run: 2h ago   12/12 done       │    │
│  │ ██████████████████████  100%   $8.60 total      │    │
│  │                                [View] [New Run] │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  ┌─── Totals ──────────────────────────────────────┐    │
│  │ 5 agents active │ $14.60 today │ 16/25 tasks    │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

#### Project Detail (Drill-Down)
Clicking a project shows its full bead graph, agent assignments, and live status.

```
┌─────────────────────────────────────────────────────────┐
│  ← Back    claude-metrics                    [Actions ▾]│
├──────────────────────┬──────────────────────────────────┤
│  Task Graph          │  Agent Activity                  │
│                      │                                  │
│  ● bd-x7k2m (Epic)  │  ┌─ Claude Code [worker-1] ──┐  │
│  ├── ✅ bd-x7k2m.1   │  │ Task: bd-x7k2m.4          │  │
│  │   JWT tokens      │  │ Status: implementing       │  │
│  ├── ✅ bd-x7k2m.2   │  │ Runtime: 12m 34s          │  │
│  │   Session MW      │  │ Tokens: 45.2k in / 12.1k  │  │
│  ├── 🔄 bd-x7k2m.3   │  │ Cost: $1.20               │  │
│  │   RBAC (blocked   │  │ [Peek] [Steer] [Kill]     │  │
│  │   by .4)          │  └────────────────────────────┘  │
│  ├── 🔄 bd-x7k2m.4   │                                  │
│  │   API routes      │  ┌─ Pi [worker-2] ────────────┐  │
│  │   → worker-1      │  │ Task: bd-x7k2m.5           │  │
│  └── 🔄 bd-x7k2m.5   │  │ Status: implementing       │  │
│      Tests           │  │ Runtime: 3m 12s            │  │
│      → worker-2      │  │ Tokens: 8.1k in / 4.2k    │  │
│                      │  │ Cost: $0.15                │  │
│  Dependencies:       │  │ [Peek] [Steer] [Kill]      │  │
│  .3 blocked by .4    │  └────────────────────────────┘  │
│  .4, .5 in progress  │                                  │
│                      │  ┌─ Refinery ─────────────────┐  │
│  Merge Queue:        │  │ Waiting for completions     │  │
│  ✅ bd-x7k2m.1 merged │  │ Merged: 2 / Pending: 3    │  │
│  ✅ bd-x7k2m.2 merged │  └────────────────────────────┘  │
│  ⏳ bd-x7k2m.4 ready │                                  │
├──────────────────────┴──────────────────────────────────┤
│  Event Log                                    [Filter ▾]│
│  08:12:34  bd-x7k2m.1 merged to main (0 conflicts)     │
│  08:12:20  bd-x7k2m.1 completed by worker-1            │
│  08:10:45  bd-x7k2m.5 claimed by worker-2 (Pi)         │
│  08:10:44  bd-x7k2m.4 claimed by worker-1 (Claude)     │
│  08:10:02  Dispatched 2 agents for ready tasks          │
│  08:09:15  PRD decomposed into 5 beads                  │
└─────────────────────────────────────────────────────────┘
```

#### Metrics View
Aggregate cost, token usage, and performance across all projects.

```
┌─────────────────────────────────────────────────────────┐
│  Metrics                          [Today] [Week] [All] │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  Cost by Runtime          Tasks by Status               │
│  ┌────────────────┐      ┌────────────────┐            │
│  │ Claude  $42.30 │      │ Completed  127 │            │
│  │ Pi       $3.20 │      │ In Progress  5 │            │
│  │ Codex    $8.10 │      │ Blocked      2 │            │
│  │ Total   $53.60 │      │ Failed       3 │            │
│  └────────────────┘      └────────────────┘            │
│                                                         │
│  Avg Time per Task        Merge Success Rate            │
│  Claude: 18m              Clean: 89%                    │
│  Pi: 4m                   Conflict: 8%                  │
│  Codex: 12m               Failed: 3%                   │
│                                                         │
│  Token Usage (7-day trend)                              │
│  ┌──────────────────────────────────────────┐           │
│  │    ╭─╮                                   │           │
│  │   ╭╯ ╰╮  ╭──╮                           │           │
│  │  ╭╯    ╰──╯  ╰╮  ╭╮                     │           │
│  │──╯             ╰──╯╰──                   │           │
│  │  M   T   W   T   F   S   S              │           │
│  └──────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────┘
```

### 5.2 Dashboard Technical Stack

| Component | Technology | Rationale |
|---|---|---|
| Frontend | Svelte + Tailwind | Lightweight, fast, good for real-time UIs |
| Backend | Node.js (Express or Hono) | Simple REST + WebSocket server |
| Database | SQLite (via better-sqlite3) | Zero config, single file, fast reads |
| Real-time | WebSocket | Live agent status, event streaming |
| Charts | Chart.js or Recharts | Cost/token visualization |
| Process | Single `foreman dashboard` command | No Docker, no build step for dev |

Alternative: **Elixir/Phoenix LiveView** — would be more aligned with Leo's claude-metrics stack and handles real-time natively. Heavier initial setup but more robust for production.

### 5.3 Dashboard API

```
GET  /api/projects                    # List all projects
GET  /api/projects/:id                # Project detail + beads
GET  /api/projects/:id/runs           # Active/completed runs
GET  /api/projects/:id/events         # Event log
GET  /api/projects/:id/costs          # Cost breakdown
POST /api/projects/:id/dispatch       # Trigger dispatch
POST /api/projects/:id/pause          # Pause all agents
POST /api/projects/:id/merge          # Trigger refinery
GET  /api/agents                      # All active agents
GET  /api/agents/:session/peek        # Peek at agent output
POST /api/agents/:session/steer       # Send message to agent
POST /api/agents/:session/kill        # Kill agent
GET  /api/metrics                     # Aggregate metrics
WS   /ws/events                       # Real-time event stream
```

---

## 6. Task Breakdown

### Phase 1: Foundation (Week 1-2)

#### P1.1 — Project Setup & CLI Skeleton
**Priority:** P0 | **Estimate:** 4h | **Runtime:** Manual
- [ ] Create `~/Development/Fortium/foreman/` project
- [ ] Initialize with `bd init`
- [ ] Set up Node.js project (`package.json`, TypeScript config)
- [ ] Create `foreman` CLI entry point with subcommands (commander.js)
- [ ] Implement `foreman init` — registers project in `~/.foreman/foreman.db`
- [ ] Implement `foreman status` — reads beads + shows summary

#### P1.2 — SQLite State Store
**Priority:** P0 | **Estimate:** 3h | **Runtime:** Claude Code
- [ ] Design schema (projects, runs, costs, events tables)
- [ ] Create migration system (simple versioned SQL files)
- [ ] Implement data access layer (better-sqlite3)
- [ ] Write tests for CRUD operations

#### P1.3 — Beads Integration Layer
**Priority:** P0 | **Estimate:** 4h | **Runtime:** Claude Code
- [ ] Wrapper module around `bd` CLI (`exec` → parse JSON output)
- [ ] Functions: `createBead`, `listReady`, `claim`, `close`, `listAll`, `getGraph`
- [ ] Handle bead hierarchies (epic → task → subtask)
- [ ] Dependency resolution (`bd dep add`)
- [ ] Error handling for Dolt/Beads edge cases

#### P1.4 — Git Worktree Manager
**Priority:** P0 | **Estimate:** 3h | **Runtime:** Pi
- [ ] Create worktree for a given bead ID (`git worktree add`)
- [ ] Branch naming convention: `foreman/<bead-id>`
- [ ] Cleanup worktree on task completion
- [ ] List active worktrees
- [ ] Handle worktree conflicts gracefully

### Phase 2: Orchestration (Week 2-3)

#### P2.1 — PRD Decomposer
**Priority:** P0 | **Estimate:** 6h | **Runtime:** Claude Code
- [ ] Accept PRD as markdown file or inline text
- [ ] Use LLM (via OpenClaw `sessions_spawn`) to decompose into bead hierarchy
- [ ] Prompt engineering for good task granularity
- [ ] Auto-detect dependencies between tasks
- [ ] Create beads via `bd create` with proper hierarchy
- [ ] Human review step before dispatch (show plan, confirm)
- [ ] Implement `foreman plan <prd.md>`

#### P2.2 — Agent Dispatcher
**Priority:** P0 | **Estimate:** 6h | **Runtime:** Claude Code
- [ ] Query `bd ready --json` for dispatchable tasks
- [ ] Runtime selection logic (task complexity → Claude Code vs Pi vs Codex)
- [ ] Create worktree per task
- [ ] Generate agent instructions (AGENTS.md with task context, bead ID, bd commands)
- [ ] Spawn via OpenClaw `sessions_spawn` (runtime: "acp")
- [ ] Record run in SQLite (session_key, worktree, bead_id, started_at)
- [ ] Configurable max concurrent agents
- [ ] Implement `foreman run`

#### P2.3 — Agent Monitor
**Priority:** P1 | **Estimate:** 4h | **Runtime:** Claude Code
- [ ] Poll active runs for completion (via OpenClaw `subagents list`)
- [ ] Detect stuck agents (no progress for configurable timeout)
- [ ] Auto-restart stuck agents (with retry count limit)
- [ ] On completion: update bead status, record costs, trigger merge check
- [ ] Event logging to SQLite
- [ ] Implement as background process or cron-triggered

#### P2.4 — Refinery (Merge Manager)
**Priority:** P1 | **Estimate:** 8h | **Runtime:** Claude Code
- [ ] Detect completed tasks ready for merge
- [ ] Merge worktree branch into main (or integration branch)
- [ ] Run test suite after merge
- [ ] On conflict: spawn a "resolver" agent or flag for human review
- [ ] On test failure: spawn a "fixer" agent or flag
- [ ] Clean up worktree after successful merge
- [ ] Update beads status
- [ ] Optional: blind validation step (spawn review agent that hasn't seen implementation)
- [ ] Implement `foreman merge`

### Phase 3: Dashboard (Week 3-4)

#### P3.1 — Dashboard Backend
**Priority:** P1 | **Estimate:** 6h | **Runtime:** Claude Code
- [ ] Express/Hono server on port 3850
- [ ] REST API endpoints (see §5.3)
- [ ] WebSocket server for real-time events
- [ ] SQLite queries for project/run/cost data
- [ ] Beads CLI integration for live bead graph
- [ ] OpenClaw integration for agent status
- [ ] Implement `foreman dashboard`

#### P3.2 — Projects Overview Page
**Priority:** P1 | **Estimate:** 6h | **Runtime:** Claude Code
- [ ] Project cards with status, progress bar, cost, agent count
- [ ] Auto-refresh via WebSocket
- [ ] Action buttons: View, Pause, New Run
- [ ] Totals bar (active agents, daily cost, task completion)
- [ ] Responsive layout

#### P3.3 — Project Detail Page
**Priority:** P1 | **Estimate:** 8h | **Runtime:** Claude Code
- [ ] Task graph visualization (dependency tree with status icons)
- [ ] Agent activity panel (live status, runtime, tokens, cost per agent)
- [ ] Agent controls: Peek (view output), Steer (send message), Kill
- [ ] Merge queue status
- [ ] Event log with filtering
- [ ] Dependency visualization (which tasks block which)

#### P3.4 — Metrics Page
**Priority:** P2 | **Estimate:** 6h | **Runtime:** Claude Code
- [ ] Cost breakdown by runtime (Claude/Pi/Codex)
- [ ] Task completion stats
- [ ] Average time per task by runtime
- [ ] Merge success rate
- [ ] Token usage trend chart (7-day)
- [ ] Date range filtering (today, week, all time)

### Phase 4: OpenClaw Skill (Week 4)

#### P4.1 — Foreman Skill (SKILL.md)
**Priority:** P0 | **Estimate:** 4h | **Runtime:** Manual
- [ ] Write SKILL.md with full instructions for Jarvis
- [ ] Natural language interface: "Run Foreman on this PRD"
- [ ] Integration with morning brief (report overnight Foreman runs)
- [ ] Error handling guidance
- [ ] Examples and edge cases

#### P4.2 — Worker Agent Templates
**Priority:** P1 | **Estimate:** 3h | **Runtime:** Manual
- [ ] AGENTS.md template for spawned coding agents
- [ ] Instructions for using `bd` within the worktree
- [ ] "Land the plane" protocol (push, close bead, clean up)
- [ ] Runtime-specific templates (Claude Code vs Pi vs Codex differences)

#### P4.3 — Refinery Agent Template
**Priority:** P1 | **Estimate:** 3h | **Runtime:** Manual
- [ ] AGENTS.md for the merge/review agent
- [ ] Merge strategy instructions
- [ ] Test running protocol
- [ ] Conflict resolution guidelines
- [ ] Blind validation instructions (optional)

### Phase 5: Polish & Client Readiness (Week 5)

#### P5.1 — Installation & Setup Script
**Priority:** P2 | **Estimate:** 3h | **Runtime:** Pi
- [ ] `foreman install` or setup script
- [ ] Check dependencies (Beads, Dolt, OpenClaw, Node.js)
- [ ] Auto-configure OpenClaw skill
- [ ] Generate default config file (`~/.foreman/config.toml`)

#### P5.2 — Documentation
**Priority:** P2 | **Estimate:** 4h | **Runtime:** Claude Code
- [ ] README.md with quickstart
- [ ] Architecture docs
- [ ] Configuration reference
- [ ] Troubleshooting guide
- [ ] Blog post draft for blog.oftheangels.org

#### P5.3 — Ensemble Integration
**Priority:** P2 | **Estimate:** 4h | **Runtime:** Claude Code
- [ ] Package as Ensemble module
- [ ] Client onboarding guide
- [ ] Configuration templates per client type
- [ ] Claude-Metrics integration (report Foreman metrics to analytics)

---

## 7. Configuration

```toml
# ~/.foreman/config.toml

[general]
max_concurrent_agents = 5
default_runtime = "claude-code"     # claude-code | pi | codex
dashboard_port = 3850

[runtimes]
# Task complexity thresholds for auto-selection
[runtimes.pi]
max_complexity = "low"              # Quick fixes, tests, docs, small features
model = "anthropic/claude-sonnet-4-20250514"

[runtimes.claude-code]
max_complexity = "high"             # Complex features, refactoring, architecture
model = "anthropic/claude-opus-4-6"

[runtimes.codex]
max_complexity = "medium"           # When OpenAI models preferred
model = "openai/o3"

[monitor]
poll_interval_seconds = 30
stuck_timeout_minutes = 15
max_retries = 2

[refinery]
auto_merge = true                   # Auto-merge when tests pass
run_tests = true                    # Run test suite after merge
blind_validation = false            # Spawn review agent (slower but safer)
test_command = "npm test"           # Override per project

[notifications]
channel = "telegram"                # Where to send completion reports
notify_on_complete = true
notify_on_failure = true
```

---

## 8. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Agents produce conflicting code | Merge failures | Medium | Git worktree isolation, one task per agent |
| Beads/Dolt instability | Data loss | Low | Dolt is version-controlled, regular backups |
| Agent token runaway | Cost overrun | Medium | Model ceilings in config, monitor kill switch |
| Dashboard scope creep | Timeline slip | High | MVP dashboard first, iterate after dogfooding |
| Decomposer creates bad tasks | Wasted agent time | Medium | Human review step before dispatch |
| OpenClaw API changes | Breaking changes | Low | Pin OpenClaw version, abstract API layer |

---

## 9. Timeline

| Week | Phase | Deliverable |
|---|---|---|
| Week 1 | Foundation | CLI skeleton, SQLite store, Beads integration, Git worktree manager |
| Week 2 | Orchestration (pt 1) | PRD decomposer, Agent dispatcher |
| Week 3 | Orchestration (pt 2) + Dashboard start | Monitor, Refinery, Dashboard backend |
| Week 4 | Dashboard + Skill | Dashboard UI (all 3 pages), OpenClaw skill, Agent templates |
| Week 5 | Polish | Install script, docs, Ensemble integration, blog post |

**Total estimate:** 5 weeks of part-time work (~80-90 hours)

---

## 10. Future Enhancements (Post-MVP)

- **Blind validation mode** — Zeroshot-style independent review agents
- **Babysitter integration** — Process enforcement for regulated clients (healthcare)
- **Claude-Metrics integration** — Push Foreman metrics to analytics dashboard
- **GitHub/GitLab integration** — Auto-create PRs per completed epic
- **Cost optimization engine** — Learn which runtime is best per task type over time
- **Team mode** — Multiple humans + Foreman on same project
- **Template library** — Pre-built decomposition templates for common patterns (auth, CRUD, API, etc.)
- **Replay mode** — Re-run failed tasks with different runtime/model
- **Webhook notifications** — Slack/Discord/Teams integration for enterprise clients

---

## 11. Decision Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-03-10 | Use Beads over TaskNotes for agent work tracking | Beads is purpose-built for agent workflows (atomic claiming, dependency graph, context compaction). TaskNotes stays for human task management. |
| 2026-03-10 | Build on OpenClaw rather than forking Gastown | Already running OpenClaw, runtime-agnostic, integrated with existing workflows, maintained platform |
| 2026-03-10 | SQLite for dashboard state (not Dolt) | Dashboard needs fast reads for real-time UI. Beads/Dolt handles work tracking. SQLite handles operational state (runs, costs, events). |
| 2026-03-10 | Svelte + Node for dashboard (not Phoenix) | Faster to prototype, lower barrier for client deployment. Can migrate to Phoenix later if needed. |

---

*See also:*
- [[Multi-Agent Coding Orchestration - Comparison Matrix]]
- [[OpenClaw + Beads - Multi-Agent Coding Orchestration Architecture]]

*Tags:* #prd #ai #multi-agent #openclaw #fortium #ensemble #foreman
