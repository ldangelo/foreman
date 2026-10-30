# Decision: `project delete` is archive-only (no hard delete)

Status: accepted (E1-S8). The operator may veto this in review.

## Context

Foreman is event-sourced. A project's stream (`project:<id>`) is referenced by id
from its runs, tasks, jobsites, review archives (`<repo>/.foreman/sessions/`) and,
later, memory/library files. `Aggregates.Task` requires a project projection, and
`ProjectionStore.init/1` rebuilds every read model by replaying the whole event log.

## Decision

- `foreman project delete` **archives** (`project.archive`). It is the only delete.
  It is rejected while the project has active runs, hides the project from default
  lists (`GET /api/projects` excludes archived unless `include_archived=true`),
  refuses new work (`{:project_archived, id}`), keeps the project readable by id,
  and is reversed with `foreman project reactivate <id>`.
- There is **no** operator command that deletes event data. `project.delete` and
  `project.purge` are not in the operator allowlist
  (`CommandGateway`, `CommandController`); a test pins this.
- On-disk artifacts (`.foreman/sessions`, memory, library) are **not** removed on
  archive.
- `pause` (reversible, new admissions refused, in-flight work continues) and
  `archive` (hidden, refuses new work, needs no active runs) are distinct states.

## Archive while a jobsite runs

Status: accepted (owner decision, `foreman-msgf8` closed as not a bug); verified live on 2026-10-30.

### Context

`project.archive` is refused only while workflow runs hold a run reservation
(`Aggregates.Project`). A jobsite holds no run reservation, so archiving a project
whose jobsite is running is accepted.

### Decision

- The archive is accepted while a jobsite runs. That jobsite keeps running and
  completes normally inside the archived project, exactly as in-flight work does
  for a pause.
- Only NEW jobsites are refused (`POST /api/jobsites` answers 422
  `spec_project_unavailable`); after `foreman project reactivate <id>` a new
  jobsite starts again.
- Pinned by `test/foreman_server/jobsite/project_archive_test.exs` and run live on
  2026-10-30 (`scripts/e2e/project_archive_flow.sh`, `docs/acceptance/e2e-live-verify-2026-10-30.md`):
  the archive was accepted, the jobsite stayed `running` with its agent alive, a
  second jobsite was refused 422 `spec_project_unavailable`, the released jobsite
  completed, and a jobsite started after the reactivate completed.
- The stricter reading (an archive needs no active work at all, jobsites
  included) was considered and rejected by the owner.
- Not covered: a multi-iteration jobsite's later iterations or PR creation inside an
  archived project (`foreman-7p068`).

## Alternatives considered

1. **Hard delete (drop the stream).** Orphans every run/task/jobsite referencing the
   project id, breaks replay of other streams that read project data, and violates
   the event-log immutability the rebuild relies on. Rejected.
2. **Tombstone event with cascading cleanup.** Still needs every consumer to cope
   with a missing project forever; the benefit (disk) is achievable separately.
   Rejected for now.
3. **Archive plus an explicit purge of files.** Kept as the future path below.

## Future path (not built)

An explicit, separately confirmed `foreman project purge-files <id>` may remove
on-disk artifacts only when: the project is archived, it has no active runs, the
operator confirms by typing the project id, and it never touches anything outside
the project's own `.foreman/` directory. Event data is never purged.
