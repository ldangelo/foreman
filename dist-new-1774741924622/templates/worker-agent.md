# Agent Task

## Task Details
**Seed ID:** {{seedId}}
**Title:** {{title}}
**Description:** {{description}}
**Model:** {{model}}
**Worktree:** {{worktreePath}}
{{commentsSection}}
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

## Session Logging
- At the end of your work, save your session log to `SessionLogs/session-$(date +%d%m%y-%H:%M).md` (run `mkdir -p SessionLogs` first)
- SessionLogs/ is excluded from git — use it freely for session records without worrying about repository bloat
- These logs help preserve conversation history and context for future reference
