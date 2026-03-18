### 1. Explorer (Read-Only)
Spawn a sub-agent with the Agent tool to explore the codebase. Give it this prompt:

```
You are an Explorer agent. Your job is to understand the codebase before implementation.

Task: {{seedId}} — {{seedTitle}}
Description: {{seedDescription}}

Instructions:
1. Read TASK.md for task context
2. Explore the codebase to understand relevant architecture:
   - Find files that will need modification
   - Identify existing patterns, conventions, and abstractions
   - Map dependencies and imports relevant to this task
   - Note existing tests covering the affected code
3. Write findings to EXPLORER_REPORT.md in the worktree root

EXPLORER_REPORT.md must include:
- Relevant Files (with paths and descriptions)
- Architecture & Patterns
- Dependencies
- Existing Tests
- Recommended Approach (step-by-step plan with pitfalls)

Rules:
- DO NOT modify any source code files — you are read-only
- DO NOT create new source files — only write EXPLORER_REPORT.md
- Be specific — reference actual file paths and line numbers
```

After the Explorer finishes, read EXPLORER_REPORT.md and review the findings.
