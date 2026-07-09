---
name: foreman-workflow-pipeline
description: "Use when editing or diagnosing Foreman workflow YAML, bundled prompts, pipeline executor behavior, phase artifacts, retries, command/bash/builtin phases, PR gates, or stale runtime prompt/workflow copies."
---

# Foreman Workflow Pipeline

## When to Use

Use this skill for changes in `src/defaults/workflows/**`, `src/defaults/prompts/**`, `src/lib/workflow-loader.ts`, or `src/orchestrator/pipeline-executor.ts`.

## Workflow Source of Truth

- Workflow YAML owns phases, models, setup, setup cache, tools, artifacts, mail hooks, retries, PR gates, and merge phases.
- Top-level `merge:` and `pr:` tags are invalid; PR behavior is explicit phases (`create-pr`, `pr-wait`, `merge`) plus `checkpointPr: true` on mutating phases.
- A task type may be declared by at most one workflow via `task_type`.

## Phase Shape Rules

- Exactly one of `prompt`, `bash`, or `command` is allowed unless `builtin: true` is used.
- `command:` is a Pi prompt/skill invocation, not a shell command; `bash:` is shell execution.
- `retryOnly: true` phases do not run sequentially; they activate only through `retryWith` or `retryWithByReason`.
- Prefer focused retry targets (`repair`, `cicd-developer`, `cr-developer`, `merge-resolver`) over broad re-running when the reason is known.

## Artifact Contract

- Runtime phase reports belong under `{task.projectReportsDir}` / `{{reportDir}}`, not repository root.
- `artifact`, `skipIfArtifact`, `verdict`, `retryWith`, `retryOnFail`, and `mail.forwardArtifactTo` are load-bearing fields.
- Stale prompts that write root `DOCUMENTATION_REPORT.md`, `QA_REPORT.md`, `DEVELOPER_REPORT.md`, or `FINALIZE_VALIDATION.md` are errors for report-dir artifacts.

## Runtime Copies

- After editing bundled source workflows or prompts, run `npm run build` then `foreman init --force` before dispatch validation.
- `foreman run`, `foreman run --watch`, and direct worker startup fail fast when installed runtime prompts/workflows are stale.

## Verification

- For workflow loader changes: targeted `npx vitest run src/lib/__tests__/workflow-loader.test.ts` if that file exists; otherwise use the nearest workflow-loader/pipeline tests found by glob/read before implementation.
- For prompt/artifact contract changes: targeted prompt/pipeline tests and a dry run or `foreman doctor` check for stale installed assets.
