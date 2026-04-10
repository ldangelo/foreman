# Foreman Operator Index

Start here when orienting yourself in this repository.

## Authoritative operator context
- Read `CLAUDE.md` first. It is the primary maintainer/operator guide for current architecture, workflow, and constraints.
- Read `README.md` for the user-facing product and CLI overview.
- Read `CHANGELOG.md` for released changes only. Do not treat it as the current design source of truth.

## Canonical product model
- Foreman is a multi-project control plane that ingests planning artifacts and tasks, schedules work across registered projects, and coordinates validation and promotion flows.
- Each project supplies a subordinate execution plane: worktree/workspace isolation, worker pipelines, merge/refinery mechanics, and project-local runtime state.
- Completed work should land on a project-specific integration branch for validation and approval before promotion. Default-branch merge is not the intended product contract.

## Current implementation truth
- The current checkout still carries project-local execution-first behavior in important places: `foreman run` is project-scoped, task tracking is still beads-first (`br` / `.beads/`), and pipeline details are more mature than the top-level scheduler.
- Native task store, project registry, and grouped/epic execution work exist in the repo, but they are not yet the sole canonical operator path.
- `foreman task` is not a parallel native-task CRUD surface in this checkout. It currently exposes beads-first approval (`foreman task approve <bead-id>`) plus the transitional `foreman task import --from-beads` migration helper.
- Foreman-created beads now start in a backlog gate (`foreman:backlog`) and require approval before dispatch.


- Workflow YAML drives phase order and retry behavior inside the execution plane, but shipped workflows must match implemented executor/store capabilities.
- VCS abstraction exists, but some orchestration paths still contain backend-specific assumptions. Treat VCS-related claims in docs as aspirational unless verified in code.
- Mid-pipeline rebase and shared-worktree/grouped execution appear in roadmap docs, but they are not fully implemented end-to-end in this checkout.

## Active roadmap documents
- `docs/PRD/PRD-2026-005-mid-pipeline-rebase-and-shared-worktree.md`
- `docs/PRD/PRD-2026-006-multi-project-native-task-management.md`
- `docs/PRD/PRD-2026-007-epic-execution-mode.md`
- `docs/TRD/TRD-2026-005-mid-pipeline-rebase.md`

## Review guidance
- Prefer current repo code over memory, session notes, or old roadmap text when they disagree.
- Treat `CLAUDE.md` as the current-state guide and the PRD/TRD files as roadmap intent unless the code proves otherwise.
- `CHANGELOG.md` is release output; do not edit it manually.
