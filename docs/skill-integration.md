# Skill Integration Guide for Foreman

This document describes Foreman's Pi skills: bundled runtime guidance installed by Foreman, plus project-local/manual skills kept for development workflows.

## Overview

Foreman uses two skill paths:

1. **Runtime-bundled skills** ship inside `@oftheangels/foreman` under `src/defaults/skills/`. `npm run build` copies them to `dist/defaults/skills/`, and `foreman init` / `foreman doctor --fix` installs them to `~/.pi/agent/skills/`.
2. **Manual/local skills** remain available by passing explicit Pi skill paths, but they are not installed by `foreman init`.

There is no separate `@oftheangels/foreman-skills` package in the current repository metadata.

## Current Skills and Impact

| Skill | Location | Purpose | Integration / Impact |
|-------|----------|---------|----------------------|
| `send-mail` | `src/defaults/skills/send-mail/` | Structured Agent Mail helper | Required pipeline communication compatibility; command-style skill with `disable-model-invocation: true` |
| `foreman-elixir-backend` | `src/defaults/skills/foreman-elixir-backend/` | Elixir/OTP backend guidance | **High** — prevents direct projection edits, duplicate schedulers, worker protocol drift, incorrect PR merge state, and unsafe test storage |
| `foreman-workflow-pipeline` | `src/defaults/skills/foreman-workflow-pipeline/` | Workflow YAML, prompts, phases, artifacts, retries, and PR gates | **High** — prevents malformed workflow YAML, wrong report locations, bad retry loops, and stale runtime asset dispatch failures |
| `foreman-worker-pi-sdk` | `src/defaults/skills/foreman-worker-pi-sdk/` | Node/Pi worker bridge and sandboxed Pi resources | **High** — reduces detached-worker failures from wrong cwd/env/backend, missing skills/tools, and incorrect terminal state |
| `foreman-pipeline-diagnosis` | `src/defaults/skills/foreman-pipeline-diagnosis/` | Stuck/missing-artifact run diagnosis | **High** — faster root-cause analysis, fewer unsafe retries, and fewer false stuck/missing-artifact diagnoses |
| `foreman-safe-recovery` | `src/defaults/skills/foreman-safe-recovery/` | Safe retry/reset/worktree/cleanup recovery decisions | **High** — reduces data loss, avoids retry loops, and improves recovery auditability |
| `foreman-vcs-backend` | `src/defaults/skills/foreman-vcs-backend/` | Git/Jujutsu backend abstraction guidance | **Medium-High** — prevents hidden direct-git regressions for Jujutsu users and keeps worker/finalize behavior backend-consistent |
| `foreman-doc-gate` | `src/defaults/skills/foreman-doc-gate/` | Documentation decision guidance | **Medium** — fewer missed doc updates, less doc churn, and accurate skill/operator guidance |
| `jj` | `skills/jj/` | Jujutsu reference skill | Manual/development skill path; not bundled by `foreman init` |
| `mulch` | `.opencode/skill/mulch/` | OpenCode-local project memory skill | OpenCode-local discovery; not bundled by `foreman init` |

## Runtime Packaging

Bundled skills live under:

```text
src/defaults/skills/
├── send-mail/
├── foreman-elixir-backend/
├── foreman-workflow-pipeline/
├── foreman-worker-pi-sdk/
├── foreman-pipeline-diagnosis/
├── foreman-safe-recovery/
├── foreman-vcs-backend/
└── foreman-doc-gate/
```

`scripts/build-atomic.js` copies `src/defaults/` to `dist/defaults/` during `npm run build`. The CLI installs bundled skills from the runtime defaults directory into `~/.pi/agent/skills/`.

## Sandboxed Worker Availability

Foreman worker sessions sandbox Pi skills by default. In that mode, user Pi skills are disabled and Foreman explicitly passes required bundled skill paths through `getSandboxedPiResourcePaths()` in `src/orchestrator/pi-sdk-runner.ts`.

The required bundled skill names are listed in `REQUIRED_SKILLS` in `src/lib/prompt-loader.ts`. `foreman init` and `foreman doctor --fix` use the same list to validate/install required skills.

## Local Development Examples

Runtime-bundled guidance skill:

```bash
pi --skill src/defaults/skills/foreman-elixir-backend
```

Existing manual skill:

```bash
pi --skill skills/jj
```

OpenCode-local skill:

```text
.opencode/skill/mulch/
```

Do not assume `foreman init` installs manual or OpenCode-local skills.

## Skill Naming Conventions

Each skill has a name defined in `SKILL.md` frontmatter:

```markdown
---
name: foreman-workflow-pipeline
description: "Use when editing or diagnosing Foreman workflow YAML..."
---
```

Invoke explicitly when needed with Pi skill syntax, for example `/skill:foreman-workflow-pipeline`.

## Adding a New Bundled Skill

1. Add `src/defaults/skills/<name>/SKILL.md`.
2. Add `<name>` to `REQUIRED_SKILLS`.
3. Ensure `getSandboxedPiResourcePaths()` exposes all required skill paths.
4. Add/update tests.
5. Update `docs/skill-integration.md` and any affected operator docs.
6. Run `npm run build` and `foreman init --force` before dispatch.

## Best Practices

1. **Skill Scope**: Each skill should focus on a single operational domain.
2. **Documentation**: Include concise rules, source-of-truth modules, and verification commands.
3. **When to Use**: Make activation conditions explicit in the skill description and body.
4. **Runtime Safety**: Keep guidance skills loadable by model invocation unless they are command-style skills like `send-mail`.
5. **No Speculation**: Document only behavior supported by the current source tree.
