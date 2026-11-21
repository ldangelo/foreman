---
Document ID: PRD-2026-b9e27ab5
Label: prd-per-project-queues
Version: 1.0.1
Status: Locked
Date: 2026-11-19
Scale Depth: STANDARD
Total Requirements: 18
Readiness Score: 4.75 / 5 (PASS; was 4.0 at create-prd, refine pass 1)
---

# PRD: Per-project dispatch queues (retire the global run-slot queue)

> Operator request (2026-11-19): change the dispatch queue mechanics so each project has
> its own queue, each allowing at most 3 running tasks per project. Ideally there is no
> global queue anymore.

## PRD Health

- Risk flags: REQ-005, REQ-007, REQ-009, REQ-017
- Dependencies: 16 cross-requirement dependencies (see Dependency Map)
- Open clarifications: 0 (see "Open Questions")
- Constitution compliance: passed

## Product Summary

**Problem.** Run admission today is gated twice: first by one global gate that allows
3 concurrent runs across *all* projects, then by a per-project reservation. One busy
project that holds the 3 global slots makes every other project wait, even when that
other project is idle and within its own limits.

**Solution.** Replace the global gate with an independent queue per project. Each project
may have up to 3 runs in flight (configurable per project) and queues the rest in
arrival order. Projects never compete with each other for admission. No global queue,
global cap or cross-project queue view remains.

**Value.** A backlog in one project can no longer delay work in another. Concurrency
becomes something an operator reasons about per project, in one place.

## User Analysis

- **Operator** (runs Foreman, owns projects): wants predictable, per-project
  concurrency and a clear per-project view of what is running and waiting.
- **Project coordinator / agents that submit work** (indirect): submit tasks and expect
  them to start when their own project has room, regardless of other projects.

**Pain today:** one busy project starves the others.

**Success metrics (agreed):**
- A project with a backlog never delays another project's run start because of that backlog.
- Each project runs at most its limit (default 3) of runs at once.
- No global queue or global cap remains.

## Goals and Non-Goals

**Goals**
- Per-project admission and queueing with a default limit of 3 concurrent runs.
- Project isolation: one project's load has no effect on another's admission.
- Removal of the global queue and global concurrency cap.
- Per-project (only) visibility of running, waiting and limit.

**Non-Goals**
- No machine-wide or provider-wide concurrency ceiling (explicitly declined: total
  concurrency is the sum of per-project limits).
- No cross-project aggregate queue view.
- No change to the daily thread cap, paused/archived project behaviour, or Beads
  database single-writer serialization.
- No priority scheduling within a queue (arrival order only).
- Jobsites are out of scope: they keep their current behaviour, including their own
  global jobsite cap, because jobsites are being removed and folded into run queues
  by separate work. This PRD covers workflow runs only.
- The reviewer-analysis limit (a separate machine-wide control that bounds reviewer
  agents) is unchanged: reviews are not runs.
- No maximum wait, alert or auto-cancel for a run waiting in a full queue; the wait is
  only made visible.

## Requirements by Feature Area

### Feature Area A: Per-project admission

### REQ-001: Each project admits runs independently
**Priority:** Must
A run's admission depends only on its own project's running count and limit, never on
any other project's activity.
- AC-001-1: Given project A has 3 runs running and a backlog, when project B starts a
  run, then B's run starts immediately (B being under its own limit).
- AC-001-2: Given projects A and B each submit 3 runs while idle, when all are
  submitted, then all 6 run concurrently.
- AC-001-3: Given project A is at its limit and project B is at its limit, when a run of
  A finishes, then only A's queue advances; B's queue is unaffected.

### REQ-002: Default limit of 3 concurrent runs per project
**Priority:** Must
A project with no explicit limit setting runs at most 3 runs at once.
- AC-002-1: Given a project with no limit setting, when 4 runs are submitted together,
  then 3 run and 1 waits.
- AC-002-2: Given 3 running and 1 waiting, when one running run finishes, then the
  waiting run starts.

### REQ-003: The project's concurrency setting overrides the default in both directions
**Priority:** Must
The existing per-project concurrency setting replaces the default of 3, higher or lower,
with no ceiling imposed by any global value.
- AC-003-1: Given a project setting of 5, when 6 runs are submitted, then 5 run and 1 waits.
- AC-003-2: Given a project setting of 1, when 2 runs are submitted, then 1 runs and 1 waits.
- AC-003-3: Given a project's setting changes while runs wait, when the new limit is
  higher than the running count, then waiting runs start up to the new limit without
  operator action.
- AC-003-4: Given a setting lowered below the current running count, when runs finish,
  then no waiting run starts until the running count falls below the new limit
  (running runs are never killed by a limit change).

### REQ-004: Jobsites are unchanged by this work
**Priority:** Won't (this release)
Jobsites do not use the run-slot queue today: they have their own global cap and are
refused, not queued, when it is full. That behaviour is out of scope and stays as is,
because separate work removes jobsites and folds sandboxes into run queues. Supersedes
the create-prd draft's "shared budget" requirement.
- AC-004-1: Given the delivered change, when a jobsite is started, then it is admitted
  or refused exactly as before this change.
- AC-004-2: Given running jobsites, when a workflow run is requested, then the project's
  run limit counts workflow runs only and is unaffected by jobsites.

### Feature Area B: Per-project queueing

### REQ-005: Waiting runs queue first-in-first-out within their project
**Priority:** Must
[RISK: ordering must survive restart and promotion races]
- AC-005-1: Given three runs queued in order X, Y, Z in one project, when slots free up,
  then they start in the order X, Y, Z.
- AC-005-2: Given the server restarts while runs wait, when it comes back, then the
  waiting runs keep their original order and none is lost or duplicated.
- AC-005-3: Given a waiting run is cancelled or removed, when slots free up, then it is
  skipped and the next waiting run starts.

### REQ-006: A freed slot is given to the next waiting run of the same project only
**Priority:** Must
- AC-006-1: Given project A has a waiting run and project B has a waiting run, when an A
  run finishes, then A's waiting run starts and B's does not move.
- AC-006-2: Given a run finishes for any terminal reason (completed, failed, blocked,
  cancelled, flagged stuck, deleted), then its slot is released and the project's next
  waiting run is considered.

### REQ-007: No slot is leaked or double-granted
**Priority:** Must
[RISK: a leaked slot silently reduces a project's capacity; a double grant exceeds its limit]
- AC-007-1: Given a run holding a slot whose process dies abnormally, when the system
  detects it, then the slot is released and the next waiting run starts.
- AC-007-2: Given two slot requests for one free slot arriving at the same moment, then
  exactly one is granted and the other waits.
- AC-007-3: Given a run that is already queued or running, when the same run is
  requested again, then it holds at most one slot or one queue position.

### Feature Area C: Retiring the global queue

### REQ-008: No global run queue or global cap remains
**Priority:** Must
Admission never consults or writes a global run-slot queue, and the global concurrency
configuration is removed.
- AC-008-1: Given the upgraded system running a mix of projects, when runs are admitted,
  queued, promoted and released, then nothing is written to the legacy global queue record.
- AC-008-2: Given the configuration reference, when searched, then no global
  max-concurrent-runs setting is documented or read.
- AC-008-3: Given a configuration that still sets the retired global value, when the
  server boots, then it logs a warning that the value is ignored and starts normally.

### REQ-009: Upgrade preserves in-flight and waiting runs
**Priority:** Must
[RISK: stranded or reordered runs during upgrade]
- AC-009-1: Given runs running under the global queue at upgrade, when the new version
  starts, then those runs continue and count against their own project's limit.
- AC-009-2: Given runs waiting in the global queue at upgrade, when the new version
  starts, then each is queued in its own project's queue, keeping its original relative order.
- AC-009-3: Given the legacy global queue record, when upgrade completes, then it is
  retained for replay, never written again, and never deleted.
- AC-009-4: Given upgrade happens when a project is already over its new limit, then
  existing runs are not stopped and new runs wait until the count falls below the limit.

### Feature Area D: Visibility

### REQ-010: Per-project queue and slot visibility
**Priority:** Must
Each project reports its running count, waiting count, limit and the waiting runs in order.
- AC-010-1: Given a project with 3 running and 2 waiting, when its limits and queue are
  read, then they show running 3, waiting 2, limit 3 and the two waiting runs in order.
- AC-010-2: Given the queue is read for one project, then it never includes another
  project's runs.
- AC-010-3: Given a project's limit setting, when limits are read, then the reported
  limit is that setting (or 3), not a value lowered by any global cap.
- AC-010-4: Given a run has waited in a project's queue, when the queue is read, then
  each waiting run shows how long it has waited.

### REQ-011: No cross-project queue view
**Priority:** Must
- AC-011-1: Given any operator surface (API, CLI, dashboard, MCP tools), when searched,
  then none returns a combined queue across projects.
- AC-011-2: Given the queue endpoint is called without naming a project, then it is
  refused with an error that says to name a project. There is no deprecation period.

### Feature Area E: Cross-cutting

### REQ-012: Paused, archived and daily-capped projects keep their behaviour
**Priority:** Should
- AC-012-1: Given a paused project, when runs are requested, then they are refused or
  deferred exactly as before this change.
- AC-012-2: Given a project at its daily thread cap, then deferral and the UTC-midnight
  re-admission behave as before.
- AC-012-3: Given a deferred task, when its project's capacity frees, then the task is
  re-admitted into that project's queue.

### REQ-013: Admission decisions are reconstructible from recorded events
**Priority:** Must
Per the project constitution, queue and slot state derives from recorded events, so
history is self-describing and replay is deterministic.
- AC-013-1: Given a project's recorded events, when state is rebuilt from scratch, then
  running, waiting and limit match the live state.
- AC-013-2: Given the limit changes over time, when history is replayed, then each past
  decision is reproduced with the limit in force at the time.

### REQ-014: Observability of per-project admission
**Priority:** Should
- AC-014-1: Given a run is queued, granted or released, then telemetry records the
  project, running count and waiting count at that moment.
- AC-014-2: Given a run waits, then its time-in-queue is observable per project.

### REQ-015: Documentation reflects per-project queues only
**Priority:** Must
Per the constitution's documentation discipline.
- AC-015-1: Given the delivered change, when the architecture notes, user guide, CLI
  reference and configuration reference are read, then they describe per-project queues
  and contain no description of the global queue as current behaviour.
- AC-015-2: Given the operator guide, then it states that total concurrency is the sum
  of per-project limits and there is no machine-wide ceiling.

### REQ-016: The concurrency setting accepts positive integers only
**Priority:** Must
- AC-016-1: Given an operator sets a project's limit to 0 or a negative number, when the
  setting is saved, then it is rejected with an error naming the valid range and the
  previous value is kept.
- AC-016-2: Given an operator sets a limit of 1, then the project runs one run at a time.
- AC-016-3: Given an operator wants a project to start no work, then pausing the project
  is the supported way; no limit value means "start nothing".

### REQ-017: Waiting runs follow the project's lifecycle
**Priority:** Must
[RISK: moving or deleting a project with waiting runs can lose or reorder work]
- AC-017-1: Given a project is archived while runs wait, then the waiting runs stay
  queued and do not start, consistent with how an archived project refuses new work.
- AC-017-2: Given a project is deleted while runs wait, then its waiting runs are
  removed from the queue.
- AC-017-3: Given work is moved to another project, then its waiting runs join the
  destination project's queue behind the runs already waiting there, keeping their
  relative order, and stop counting against the source project.

### REQ-018: Each run holds exactly one slot
**Priority:** Must
- AC-018-1: Given a run that works in several repositories, then it holds one slot
  regardless of how many repositories it touches.
- AC-018-2: Given a fix thread started on a run's pull request, then it is its own run
  and takes its own slot in the project, queueing if the project is full.

## Approvals and Decision Ownership

- **Approver (role):** the Foreman operator.
- **Criteria they judge against:**
  - Two projects each reach 3 concurrent runs with neither blocking the other.
  - A project with a backlog never delays another project's run start.
  - Nothing is written to the legacy global queue record after upgrade.
- **Constitution approvals:** this is an architecture change and a breaking change to
  an operator-visible endpoint and setting; the operator's approval of this PRD is the
  explicit approval those rules require.

## Entry and Exit Criteria

**Entry**
- The current global gate behaviour is understood and covered by tests.
- The server test suite is green on `main`.

**Exit**
- Two projects each hold 3 concurrent runs (REQ-001, REQ-002).
- A backlogged project does not delay another project (REQ-001, REQ-006).
- No writes to the legacy global queue record after upgrade (REQ-008, REQ-009).
- The global concurrency setting is gone (REQ-008).
- Documentation describes per-project queues only (REQ-015).

## Dependency Map

- REQ-002 depends on REQ-001
- REQ-003 depends on REQ-002
- REQ-005 depends on REQ-001
- REQ-006 depends on REQ-005
- REQ-007 depends on REQ-006
- REQ-009 depends on REQ-005, REQ-008
- REQ-010 depends on REQ-005
- REQ-011 depends on REQ-010
- REQ-012 depends on REQ-001
- REQ-013 depends on REQ-005, REQ-006
- REQ-014 depends on REQ-005
- REQ-015 depends on REQ-008, REQ-011
- REQ-016 depends on REQ-003
- REQ-017 depends on REQ-005
- REQ-018 depends on REQ-001, REQ-002

REQ-004 (Won't) has no dependencies.

**Clusters (deliver together):** {REQ-001, REQ-002, REQ-003, REQ-005, REQ-006, REQ-007,
REQ-016, REQ-018} is the admission core. {REQ-008, REQ-009, REQ-017} is the retirement,
migration and lifecycle. {REQ-010, REQ-011, REQ-014} is visibility. No circular
dependencies.

## Open Questions

None. Findings 1-9 of refine pass 1 were resolved (see Version History).

## Readiness Scorecard

| Dimension | Score | Note |
|---|---|---|
| Completeness | 5 | Adds limit range, project lifecycle, slot-per-run, jobsite and reviewer-cap scope |
| Testability | 5 | Every Must/Should requirement has Given/When/Then ACs |
| Clarity | 5 | No open markers |
| Feasibility | 4 | Jobsite and reviewer caps stay; the per-project reservation already exists |

Overall 4.75 / 5: **PASS** (was 4.0).

## Version History

- **1.0.1 (2026-11-19), refine pass 1:**
  - REQ-004 rewritten: jobsites out of scope, Won't this release. Another worktree is
    removing jobsites, and the code shows they use a separate global cap, not run slots.
  - REQ-008: leftover global config is ignored with a warning, not refused at boot.
  - REQ-011: un-scoped queue endpoint is refused, with no deprecation period.
  - Non-Goals: added jobsites, the reviewer-analysis limit and no max wait or alert.
  - REQ-010: added AC-010-4 (wait time shown per waiting run).
  - Added REQ-016 (positive integers only), REQ-017 (project lifecycle) and REQ-018
    (one slot per run).
  - Dependency map extended to cover every requirement.
- **1.0.0 (2026-11-19):** create-prd draft.
