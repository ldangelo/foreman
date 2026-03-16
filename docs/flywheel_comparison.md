# Foreman vs The Agentic Coding Flywheel

## Overview

| Aspect | Foreman | Flywheel |
|--------|---------|----------|
| **Author** | Fortium / ldangelo | Jeff Emanuel (Dicklesworthstone) |
| **Architecture** | Monolithic orchestrator (TypeScript) | Ecosystem of 14 independent tools |
| **Philosophy** | Single binary that owns the full pipeline | Loosely-coupled tools that amplify each other |
| **Language** | TypeScript | Rust, Go, Bash, Python, TypeScript |
| **Agent runtime** | Claude Agent SDK (`query()`) | Claude Code + tmux orchestration (NTM) |
| **Task tracking** | Seeds (sd) — git-tracked JSONL | Beads Rust — git-tracked local issue tracking |
| **Started** | ~2025 | October 2025 |

## Core Comparison

### Task Tracking & Prioritization

| Feature | Foreman | Flywheel |
|---------|---------|----------|
| Backend | Seeds (sd) — JSONL in `.seeds/` | Beads Rust — local git-integrated tracking |
| Prioritization | Manual P0-P4 priorities | PageRank-weighted automatic prioritization |
| UI | CLI (`foreman status`, `sd list`) | Beads Viewer — keyboard-driven terminal UI |
| Dependencies | Explicit `blocks` dep type | Structural via PageRank graph |
| Decomposition | LLM-powered (`foreman decompose`, `foreman plan`) | Implicit through beads prioritization |

**Takeaway**: Flywheel's PageRank prioritization is more sophisticated — tasks bubble up based on graph centrality rather than manual priority assignment. Foreman has stronger LLM-powered decomposition (PRD → TRD → task hierarchy).

### Agent Orchestration

| Feature | Foreman | Flywheel |
|---------|---------|----------|
| Execution model | Detached processes in git worktrees | tmux panes via NTM |
| Pipeline | TypeScript-orchestrated phases (Explorer → Developer → QA → Reviewer → Finalize) | Loose agent coordination via mail |
| Inter-agent comms | Report files (EXPLORER_REPORT.md, DEVELOPER_REPORT.md, QA_REPORT.md, REVIEW.md) | MCP Agent Mail — Gmail-like messaging with file leases |
| Parallelism | Multiple worktrees, concurrent agents | Multi-pane tmux with animated dashboards |
| Budget control | `maxBudgetUsd` per phase | Not explicitly documented |
| Retry logic | Dev ⇄ QA loop (2 retries), Reviewer feedback loop | Not explicitly documented |

**Takeaway**: Foreman has a more structured pipeline with explicit quality gates and retry loops. Flywheel's agent-mail approach is more flexible — agents are organizational units with communication protocols rather than phases in a fixed pipeline. Flywheel's file leasing prevents conflicts; foreman uses git worktree isolation instead.

### Quality & Safety

| Feature | Foreman | Flywheel |
|---------|---------|----------|
| Code review | Automated Reviewer phase (PASS/FAIL verdicts) | Not built-in (relies on external tooling) |
| QA/Testing | Dedicated QA phase runs tests, writes QA_REPORT.md | UBS — 1,000+ pattern pre-commit bug scanner |
| Destructive command guard | Not built-in | DCG — SIMD-accelerated blocker for `rm -rf`, `git reset --hard` |
| Two-person rule | Not built-in | SLB — enforces peer approval for dangerous operations |
| Pre-commit hooks | Not built-in | UBS runs before every commit |

**Takeaway**: Flywheel is significantly stronger on safety guardrails (DCG, SLB, UBS). Foreman is stronger on automated quality assessment (structured QA + Review phases with verdict-driven retry loops). These are complementary — foreman could benefit from adopting safety guardrails.

### Session & Memory

| Feature | Foreman | Flywheel |
|---------|---------|----------|
| Session persistence | SDK session IDs, resume capability | CASS — unified search across 11+ AI tool histories |
| Memory | SQLite run tracking + seeds | CASS Memory — 3-layer cognitive architecture (episodic, working, procedural) |
| Cross-session learning | None | Meta Skill — mines successful patterns from past sessions |
| Skill discovery | None | Agents build capability libraries from past operations |

**Takeaway**: Flywheel's memory and session systems are far more advanced. CASS provides cross-tool session search, and the three-layer memory architecture enables agents to learn and improve over time. Foreman tracks runs in SQLite but has no cross-session learning.

### Git & Infrastructure

| Feature | Foreman | Flywheel |
|---------|---------|----------|
| Isolation | Git worktrees per task | File leases via Agent Mail |
| Branch management | Auto-creates `foreman/<bead-id>` branches | Standard git workflow |
| Merge | `foreman merge` command | Manual / RU for multi-repo sync |
| Multi-repo | Not supported | RU — sync hundreds of repos at once |
| Deployment | Local CLI tool | Flywheel Setup — zero-to-configured VPS in 30 min |

**Takeaway**: Foreman has tighter git integration (worktrees, auto-branching, merge command). Flywheel targets multi-repo and cloud deployment scenarios that foreman doesn't address.

## Feature Gap Analysis

### Features Foreman Should Adopt from Flywheel

| # | Feature | Flywheel Tool | Priority | Rationale |
|---|---------|---------------|----------|-----------|
| 1 | Destructive command guard | DCG | P1 | Agents run with `bypassPermissions` — a guardrail against `rm -rf` etc. is critical |
| 2 | Pre-commit bug scanning | UBS | P2 | Pattern-based scanning before finalize phase would catch classes of bugs QA misses |
| 3 | Cross-session memory | CASS Memory | P2 | Three-layer memory would help agents learn from past runs on the same codebase |
| 4 | PageRank task prioritization | Beads Viewer | P3 | Auto-prioritization based on dependency graph centrality vs manual P0-P4 |
| 5 | Agent messaging system | MCP Agent Mail | P3 | More flexible than report files for complex multi-agent workflows |
| 6 | Skill mining from history | Meta Skill | P3 | Agents should progressively learn what works in each codebase |
| 7 | Multi-repo orchestration | RU | P4 | Useful for monorepo-adjacent workflows |

### Features Flywheel Should Adopt from Foreman

| # | Feature | Foreman Component | Rationale |
|---|---------|-------------------|-----------|
| 1 | Structured pipeline phases | agent-worker.ts | Explicit Explorer → Developer → QA → Reviewer flow with retry loops |
| 2 | LLM-powered decomposition | `foreman decompose` / `foreman plan` | PRD → TRD → task hierarchy with dependency wiring |
| 3 | Budget-based phase limits | `maxBudgetUsd` per role | Cost control per phase rather than just turn limits |
| 4 | Git worktree isolation | `foreman run` | True filesystem isolation per task vs file leasing |
| 5 | Automated code review verdicts | Reviewer phase | PASS/FAIL with CRITICAL/WARNING/NOTE issue classification |
| 6 | Per-phase report rotation | rotateReport() | Timestamped report history for debugging across retries |

## Architectural Differences

### Foreman: Integrated Orchestrator
```
foreman CLI → dispatcher → agent-worker (detached)
                              ↓
                    Explorer → Developer ⇄ QA → Reviewer → Finalize
                              ↓
                    Git worktree isolation + SQLite state + Seeds tracking
```
- **Strength**: Single tool, predictable pipeline, built-in quality gates
- **Weakness**: Less flexible, no cross-session learning, no safety guardrails

### Flywheel: Tool Ecosystem
```
NTM (tmux orchestrator) → Agent panes
                              ↓
              MCP Agent Mail ← → File leases
                              ↓
         DCG + UBS + SLB (safety) + CASS (memory) + Meta Skill (learning)
```
- **Strength**: Modular, safety-first, cross-session intelligence, agent autonomy
- **Weakness**: Complex setup (14 tools), less structured quality pipeline, requires tmux

## Summary

Foreman and Flywheel solve the same problem (multi-agent software development) from opposite directions:

- **Foreman** is a **vertical integration** — one tool that owns the pipeline end-to-end with structured phases and quality gates. It excels at predictable, auditable agent workflows.

- **Flywheel** is a **horizontal ecosystem** — 14 independent tools that create emergent coordination. It excels at safety, memory, and agent autonomy.

The most impactful features foreman could adopt are **destructive command guards** (DCG), **pre-commit scanning** (UBS), and **cross-session memory** (CASS Memory). The most impactful thing flywheel could adopt from foreman is the **structured pipeline with retry loops** and **LLM-powered task decomposition**.
