# Agent Task

## Task Details
<<<<<<< HEAD:.foreman/reports/TASK-foreman-29fc.md
**Seed ID:** foreman-cbfc
**Title:** Extract maxBudgetUsd values to environment variables
||||||| parent of cca0fe7 (Extract dispatcher maxTurns and model to configuration (foreman-1d9d)):TASK.md
**Bead ID:** foreman-fe78
**Title:** Replace maxTurns with maxBudgetUsd for pipeline phase limits
=======
**Seed ID:** foreman-1d9d
**Title:** Extract dispatcher maxTurns and model to configuration
>>>>>>> cca0fe7 (Extract dispatcher maxTurns and model to configuration (foreman-1d9d)):TASK.md
**Description:** (no description provided)
<<<<<<< HEAD:.foreman/reports/TASK-foreman-29fc.md
**Model:** claude-sonnet-4-6
**Worktree:** /Users/ldangelo/Development/Fortium/foreman/.foreman-worktrees/foreman-cbfc
||||||| parent of cca0fe7 (Extract dispatcher maxTurns and model to configuration (foreman-1d9d)):TASK.md
**Model:** claude-sonnet-4-6
**Worktree:** /Users/ldangelo/Development/Fortium/foreman/.foreman-worktrees/foreman-fe78
=======
**Model:** claude-haiku-4-5-20251001
**Worktree:** /Users/ldangelo/Development/Fortium/foreman/.foreman-worktrees/foreman-1d9d
>>>>>>> cca0fe7 (Extract dispatcher maxTurns and model to configuration (foreman-1d9d)):TASK.md

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
