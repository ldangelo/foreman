# Agent Task

## Task Details
**Seed ID:** foreman-071f
**Title:** Cost tracking with per-agent and per-phase breakdowns
**Description:** (no description provided)
**Model:** claude-sonnet-4-6
**Worktree:** /Users/ldangelo/Development/Fortium/foreman/.foreman-worktrees/foreman-071f

## Agent Team
This task is handled by an Engineering Lead agent that orchestrates a team:
- **Explorer** — reads the codebase, produces EXPLORER_REPORT.md (read-only)
- **Developer** — implements changes and writes tests (read-write)
- **QA** — runs tests, verifies correctness, produces QA_REPORT.md (read-write)
- **Reviewer** — independent code review, produces REVIEW.md (read-only)

The Lead spawns sub-agents to handle each phase and coordinates their work.
Reports (EXPLORER_REPORT.md, QA_REPORT.md, REVIEW.md) are the communication
protocol between agents.

## Rules
- Stay focused on THIS task only
- Follow existing codebase patterns and conventions
- Do not modify files outside your scope
- If blocked, write a note to BLOCKED.md explaining why
