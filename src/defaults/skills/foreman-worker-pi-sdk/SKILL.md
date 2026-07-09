---
name: foreman-worker-pi-sdk
description: "Use when changing Foreman's Node/Pi worker bridge, detached worker config/env, Pi SDK sessions, custom tools, tool policy, observability, worker terminal events, or sandboxed Pi resource paths."
---

# Foreman Worker Pi SDK

## When to Use

Use this skill for changes in `src/orchestrator/dispatcher.ts`, `src/orchestrator/agent-worker.ts`, `src/orchestrator/pi-sdk-runner.ts`, `src/orchestrator/pi-sdk-tools.ts`, `packages/foreman-pi-extensions/**`, or worker env/config surfaces.

## Process Boundary

- Dispatcher writes worker config under `~/.foreman/tmp/worker-<runId>.json`, spawns a detached worker with `cwd = worktreePath`, strips `CLAUDECODE`, removes `DATABASE_URL`, and propagates `FOREMAN_VCS_BACKEND`.
- Worker code treats Elixir as authoritative for registered project/run/task state and must not open a direct database pool.
- Worktree path and project path differ; do not collapse them.

## Pi Session Boundary

- `runPhaseSession()` builds guarded built-in tools, custom Foreman tools, tool policy, observability, and in-memory Pi sessions.
- `allowedTools` controls built-in tools; custom Foreman tools (`send_mail`, `mail_read`, `mail_send`, `phase_handoff`, `artifact_write`, `validation_result`, `task_block`, `progress_update`, `safe_command_run`, VCS/PR helpers) have their own flow and policy checks.
- Tool policy denial is a tool result/error payload, not a thrown process exception.

## Sandboxed Resources

- Default `FOREMAN_PI_EXTENSIONS` mode disables user skills and prompt templates; Foreman must explicitly pass bundled skill paths through `additionalSkillPaths`.
- New bundled required skills must be included in `getSandboxedPiResourcePaths()` through a shared list, not hardcoded one-by-one.

## Terminal Semantics

- Preserve authoritative terminal run/task events; launcher process-exit inference is fallback diagnostics only.
- Do not mark a task complete just because a worker process exited zero if required phase artifacts/events are missing.

## Verification

- Target `src/orchestrator/__tests__/pi-sdk-runner.test.ts` for resource path/sandbox changes.
- Target worker/phase tests for custom tool or terminal status changes.
