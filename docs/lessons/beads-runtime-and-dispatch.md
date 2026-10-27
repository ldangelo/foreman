# Beads runtime, dispatch partitioning, bv sidecar, task lifecycle, git policy

> Archived from the former monolithic `AGENTS.md` (2026-10-18), with accuracy corrections from the PR #561 review, to keep the always-loaded agent context small. Current Beads quickstart, label-gate dispatch partitioning, `bv` usage, session protocol, git policy.
> Section-number references inside (e.g. "section 4", "§5.4") point at the pre-split `AGENTS.md`; the §5 rules are summarised in `AGENTS.md` and full text is in `typed-boundaries-full.md`.

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`) for issue tracking and [beads_viewer](https://github.com/Dicklesworthstone/beads_viewer) (`bv`) for graph-aware triage. Issues are stored in `.beads/` and tracked in git. Current `br` workspaces normally export `.beads/issues.jsonl`; older `bd`/legacy workspaces may use `.beads/beads.jsonl`. `bv` auto-discovers the supported JSONL files, so agents should use `br`/`bv` commands instead of hard-coding a single filename.
**Beads is now this repo's primary task creation interface (TRD-2026-d99cd90d,
2026-09-13).** A bead that reaches `status: open` is the trigger for task
creation, but it dispatches only if it also carries the `foreman-exec` label
(label gate) and its `issue_type` maps to a workflow via a manifest's
`task_types:` (see the workflow-selection paragraph below): otherwise the
watcher skips it (`:skip_labels`) or holds it as `:unmapped` (telemetry bucket `:unmapped_type`)
and no task is created. When all gates pass, BeadsWatcher's status gate
(TRD-004), workflow-selection wiring (TRD-005), and
auto-approval (TRD-007) dispatch the internal `task.create` + `task.approve`
commands automatically; no CLI call is needed or possible. `foreman task
create`/`approve`/`retry`/`get`/`list`/`update` were deleted from the Go CLI
(TRD-018, the `task` dispatch case and its handlers were removed from
`packages/foreman_cli/cmd/foreman/task.go`, which still exists for shared
HTTP helpers used by other command files) — invoking any of them
produces the CLI's standard "unknown command" error. `foreman run
list/get/cancel/pause/resume/remove/reset` are unaffected and remain the way to inspect or
control a dispatched run.

**Workflow-selection (TRD-005) coverage is currently narrow — most issue
types are inert under BeadsWatcher.** `Catalog.type_to_workflow/1` resolves
an `issue_type` to a workflow only via a manifest's own `task_types:`
declaration; as of this writing only four bundled workflows declare one:
`implement-trd.yaml` (`task_types: [implement_trd]`),
`implement-trd-beads.yaml` (`task_types: [implement_trd_beads]`),
`fix.yaml` (`task_types: [bug]`), and `prd.yaml` (`task_types: [feature]`).
A bead whose `issue_type` is anything else
— including `task`, `epic`, or any other bundled workflow's own
name (`assess.yaml` and `review.yaml` declare
no `task_types:` at all) — resolves to `{:error, :unmapped_type}` and the
watcher returns `:unmapped` for that line (its own outcome, counted as
`lines_unmapped` on `[:watcher, :replay_completed]`; it used to share
`:transient`, which now means only that a dispatch itself failed). The
bead is left untouched and re-evaluated on every poll, so it dispatches on the
first poll after the installed catalog maps its type; no task is created until then.
`foreman doctor`'s `workflows.bead_types` row lists which types are mapped and
which are held. An `issue_type` key that is absent is `:malformed` with reason
`:issue_type_missing`; one that is present but not a non-empty string (`null`,
`""`, a number) is `:malformed` with `{:issue_type_unusable, <inspected value>}`.
This is not a bug: it is the intended
fail-closed behavior (TRD-005 REQ), but it means adding a new issue type to
the auto-dispatch surface requires an explicit `task_types:` entry in the
target workflow's manifest (and a matching `foreman init --force` to refresh
the installed runtime copy) — the mapping does not grow automatically as
workflows are added.

**`implement_trd_beads` beads are epic roots; the run is judged on the Beads graph (TRD-2026-72f477ca PR 2).**
`implement-trd-beads.yaml` (name and `task_types: [implement_trd_beads]`
unchanged) dispatches `/skill:ensemble-beads-build {{implementation.bead_id}}
--foreman` (was `/skill:ensemble-full-implement-trd-beads
{{implementation.trd_path_argument}} --foreman`): single worktree, single
phase, and NO `timeout_minutes` (`FailurePolicy` resolves `:infinity`; a tree of
dozens of beads runs for hours).

- *Eligibility (unchanged).* `BeadsWatcher` dispatches a bead only when its
  status is `open`, it carries label `foreman-exec`, `issue_type:
  implement_trd_beads` maps to the workflow, and `agent_context.trd_path` is a
  non-empty project-relative path (a missing/empty `trd_path` blocks the bead
  with a remediation comment). Also: a `trd_path` that is not a tracked regular file at the project's HEAD inside the project root (missing, deleted, a directory, absolute or escaping the project, or untracked) is treated like a missing `trd_path`: the bead is moved to `blocked` with the same remediation comment, instead of being retried forever (previously it was held transient and `task.approve` kept failing). Project-level faults (project not registered, root not a git repo) are not blamed on the bead and still proceed to `task.create`. The check re-runs every time the watcher sees the bead as `open`, so after fixing the path (commit the TRD, or `br update` the `trd_path`) reopen it as the comment says (`--status open`, or re-label) and it dispatches on the next scan. The telemetry event for this block, `[:foreman_server, :task_provider, :beads, :watcher, :status_gate, :skipped, :missing_trd_path]`, now carries a `reason` metadata key (the `trd_path_*` validation reason) for the invalid-path case and no `reason` for the missing case.
- *Bead id.* `implementation.bead_id` is the frozen id of the bead that
  triggered the task (`task.external_id`, set by BeadsWatcher).
  `ImplementationContext` fails approval for an `implement-trd-beads` task
  without one: `{:implementation_context_failed, :bead_id_missing |
  :bead_id_malformed}`. An `{{implementation.*}}` placeholder still unresolved
  after approval rendering refuses the approval
  (`CommandGateway.assert_implementation_placeholders_resolved/1`) with
  `{:implementation_placeholder_unresolved, ["{{implementation.bead_id}}"]}`
  instead of the runtime renderer blanking it into an empty epic id, which
  `beads-build` would read as a slug pattern and build an unrelated epic.
- *Outcome check (`Workflow.BeadsTreeCompletion`, after the LAST phase's
  commit).* beads-build is a prompt with no exit code or machine-readable
  result, so Foreman reads the graph. The run completes only if EVERY
  parent-child descendant of the epic is `closed`. The epic's own status is
  never consulted (an epic left `open` over all-closed children completes;
  Foreman then closes the epic bead through the task provider as before); a
  descendant closed by a human mid-run counts as closed; `blocks` edges never
  widen the tree. Otherwise the phase, run (`RunFailed`) and task fail via the
  normal failure path: the epic bead goes `blocked` with the usual transition
  comment `foreman-run:<run_id>:<artifact_path>`, the reason is
  `:incomplete_children: N descendant bead(s) of <epic> are not closed: <id>
  (<status>), ...` (first 8 named, then "and K more"), and the full list is
  appended to the phase artifact under `## Incomplete children of <epic>`.
  `br show` failing or answering in an unknown shape fails closed:
  `:beads_tree_unreadable` (`BEADS_TREE_UNREADABLE: ...`);
  `:beads_tree_unverifiable` if the frozen context has a `bead_id` but no
  database path. Runs without a frozen `bead_id` are unaffected.
- *No cache; retry is judged on the graph as it is then.* Reads are fresh every
  time (one `br show` per tree level), so `run resume`/retry re-issues the same
  command for the same epic and `beads-build` owns dependency-order resume from
  the graph. Recovery is: fix the graph or the bead, then retry.
- *Validation.* `ensemble-beads-build` is an accepted skill for
  `foreman_workflow_validate` (MCP).
- *Installed copies are not refreshed automatically.* Run `foreman init
  --force` after upgrading so `~/.foreman/workflows/implement-trd-beads.yaml`
  carries the new command; tasks approved earlier keep the old command frozen
  in their snapshot.
- *Caveat — id contract not verified live.* The installed ensemble `beads-build`
  skill (v1.2.0) does not declare `--foreman` (an unrecognised token) and
  documents its epic argument as `beads-NNN or a numeric ID`, while Foreman
  bead ids look like `foreman-ab12`. Whether beads-build treats such an id as a
  bead id (EPIC_ID_MODE) or as a title slug is the ensemble repo's contract and
  is NOT verified here; TRD-006b (PR 3) does the live end-to-end run.
- *Caveat — tagging.* Ensemble-side TRD-001 (`implement-trd-beads --plan
  --foreman` tagging the root epic with `issue_type: implement_trd_beads`,
  `agent_context.trd_path` and label `foreman-exec`) is a separate
  ensemble-repo PR; until it ships an operator tags the epic by hand.

**A dispatched task's `prompt` comes from the bead's own title/description,
not the operator.** `BeadsWatcher`'s `task.create` payload sets `prompt:`
from the bead's `title` (plus `description` when present, joined with a
blank line) — `synthesize_task_create_envelope/5` and `bead_prompt/1` in
`beads_watcher.ex`. This is the ONLY channel a `command:`-type phase has
for its subject: `CommandGateway.enrich_approval_via_workflow/2` carries
`Task.prompt` from the task projection onto the `task.approve` command,
and `Approval.prepare/2`'s `maybe_put_prompt/2` freezes it onto
`workflow_snapshot["input"]["prompt"]`, which is what `{{input.prompt}}`
substitutes into a manifest's `command:` string (e.g. `fix.yaml`'s
`/skill:ensemble-fix-issue {{input.prompt}} --foreman`). `title` is
required: a blank or non-string `title` is rejected as `:malformed`
before `task.create` regardless of `description` — a non-string title
is treated as a data-integrity problem, not something to silently
salvage via `description` alone. A present-but-blank `description` is
also `:malformed`; an absent `description` is fine (title-only prompt).

**BeadsWatcher itself is opt-in, off by default** (`config :foreman_server,
:start_beads_watcher?, false`) — set it to `true` (dev-only; do not commit a
default flip to `main`'s `config/dev.exs`) to run one watcher per registered
project, tailing its JSONL and auto-dispatching per the mapping above. See
`docs/user-guide.md`'s "Inbound sync" note for the config key; the
`FOREMAN_START_BEADS_WATCHER=true|false` env var (`config/runtime.exs`) overrides it per start without editing `dev.exs`.

### Beads Dispatch Partitioning via Label Gate (opt-IN semantics)

**BeadsWatcher implements label-based partitioning with opt-IN semantics** to route beads between Foreman and external processors (e.g., human operators, external automation). Only beads tagged with the `"foreman-exec"` label dispatch to Foreman; beads with no labels field or a label list lacking `"foreman-exec"` skip and route to external processes, while a labels field that is not a list is rejected as `:malformed` (see Mechanics).

**Operator workflow:**
- Include a bead in Foreman dispatch: `br update <bead-id> --add-label foreman-exec`
  (NEVER `--labels`: it is an alias of `--set-labels` and REPLACES every existing
  label — verified on br 0.6.0, where `--labels foreman-exec` dropped `alpha,beta`
  while `--add-label gamma` appended)
- Exclude a bead from Foreman dispatch: Omit the flag (default behavior; routes externally)

**Mechanics:**
- **Gate location**: Label check runs in the BeadsWatcher pipeline after status validation, before workflow selection
- **Semantics**:
  - Absent labels field (key missing) → `:skip_labels` outcome (external routing). A present-but-`null` field is NOT absent: `Jason` decodes it to `nil`, which `Map.get/2` cannot tell apart from a missing key, so `check_labels/2` reads it through a `:absent` sentinel default and classifies `nil` as malformed (§5.3), not external routing.
  - Present labels field with `"foreman-exec"` → `:ok` (Foreman dispatch allowed)
  - Present labels field without `"foreman-exec"` → `:skip_labels` outcome (external routing)
  - Present labels field that is not a list — a string, a `null`, any non-list (type violation) → `:malformed` outcome (data integrity error; must be fixed manually)
- **Dedupe & ordering**: Routing is not the dedupe mechanism — `process_line/2` runs `check_dedupe/2` before the status and label gates. That check calls `ProjectionStore.get_task(external_id: bead_id)`: no existing task → proceed; an existing task still at `status: "open"` (created but never approved) → retry `task.approve` without a new `task.create`; an existing task past `"open"` → `:reconciled` with no new `task.create`. The label gate itself only decides external-vs-Foreman routing.
- **Telemetry**: The `:no_labels` and `:not_foreman_exec` skip branches emit `[:foreman_server, :task_provider, :beads, :watcher, :label_gate, :skipped]` events. A malformed labels field emits no bespoke event: every malformed path in the pipeline returns `{:malformed, cause}` and `process_line/2` funnels all of them through one `emit_malformed/3`, which fires the pipeline's existing `@malformed_event` with the cause in its `reason` metadata key (e.g. `{:labels_not_a_list, "foreman-exec"}`). Events carry the watcher's configured `project_id` from its state, not the parsed bead record (bead JSONL lines carry no `project_id` field). The outcome is logged once, at `info`, by the pipeline's existing per-line log line.

**Rationale**: Operator discipline on label assignment enforces cooperation without requiring locks, separate aggregates, or ensemble modifications. Beads API natively supports labels; they are queryable via `br show --json` and filterable via `br list --label`.

### Using bv as an AI sidecar

bv is a graph-aware triage engine for Beads projects. Instead of parsing .beads/issues.jsonl / .beads/beads.jsonl directly or hallucinating graph traversal, use robot flags for deterministic, dependency-aware outputs with precomputed metrics (PageRank, betweenness, critical path, cycles, HITS, eigenvector, k-core).

**Scope boundary:** bv handles *what to work on* (triage, priority, planning). `br` handles creating, modifying, and closing beads.

**CRITICAL: Use ONLY --robot-* flags. Bare bv launches an interactive TUI that blocks your session.**

#### The Workflow: Start With Triage

**`bv --robot-triage` is your single entry point.** It returns everything you need in one call:

- `quick_ref`: at-a-glance counts + top 3 picks
- `recommendations`: ranked actionable items with scores, reasons, unblock info
- `quick_wins`: low-effort high-impact items
- `blockers_to_clear`: items that unblock the most downstream work
- `project_health`: status/type/priority distributions, graph metrics
- `commands`: copy-paste shell commands for next steps

```bash
bv --robot-triage        # THE MEGA-COMMAND: start here
bv --robot-next          # Minimal: just the single top pick + claim command

# Token-optimized output (TOON) for lower LLM context usage:
bv --robot-triage --format toon
```

Before claiming, verify current state with `br show <id> --json` or `br ready --json`. `recommendations` can include graph-important blocked or assigned work; only `quick_ref.top_picks` and non-empty `claim_command` fields represent claimable work.

#### Other bv Commands

| Command | Returns |
| --------- | --------- |
| `--robot-plan` | Parallel execution tracks with unblocks lists |
| `--robot-priority` | Priority misalignment detection with confidence |
| `--robot-insights` | Full metrics: PageRank, betweenness, HITS, eigenvector, critical path, cycles, k-core |
| `--robot-alerts` | Stale issues, blocking cascades, priority mismatches |
| `--robot-suggest` | Hygiene: duplicates, missing deps, label suggestions, cycle breaks |
| `--robot-diff --diff-since <ref>` | Changes since ref: new/closed/modified issues |
| `--robot-graph [--graph-format=json\|dot\|mermaid]` | Dependency graph export |

#### Scoping & Filtering

```bash
bv --robot-plan --label backend              # Scope to label's subgraph
bv --robot-insights --as-of HEAD~30          # Historical point-in-time
bv --recipe actionable --robot-plan          # Pre-filter: ready to work (no blockers)
bv --recipe high-impact --robot-triage       # Pre-filter: top PageRank scores
```

### Task Lifecycle (Beads-driven, TRD-2026-d99cd90d)

Task creation is now driven by Beads, not a CLI verb — `foreman task create/
approve/retry/get` were deleted (TRD-018, 2026-09-13). Create work with `br
create` (or transition an existing bead to `status: open`) and give it the
`foreman-exec` label with a mapped `issue_type`; BeadsWatcher
observes the transition and dispatches the internal `task.create` +
`task.approve` command pair automatically. `foreman run *` remains the way to
inspect or control the resulting dispatched run:

```bash
foreman run list             # List run projections
foreman run get <id>         # Fetch run projection
foreman run cancel --id <id> --reason <text>
foreman run pause --id <id> --reason <text>  # stop now, resumable
foreman run resume --id <id>                  # continue a paused run
foreman run remove --id <id> # Remove run and clean worktree/branch
foreman run reset --id <id>  # Clear failed/stuck run projection
foreman run approve-merge --id <id> --approver <name> --identity <github:login> --head-sha <sha>  # open the merge gate for the head you reviewed
foreman run merge --id <id>  # squash-merge the approved PR (pinned to the approved head; a push after approval voids the approval)
```

### Triage & Discovery (br/bv)

`br`/`bv` now manage this repo's work queue directly (superseding the older
CLI-driven flow): `br create`/`br update --status=open` is how a task is
created; `bv` is for triage and discovery only, never for mutating beads.

```bash
bv --robot-triage              # Triage: ranked recommendations, blockers, quick wins
bv --robot-next                # Minimal: top pick + claim command
bv --robot-plan                # Parallel execution tracks with unblocks
bv --robot-insights            # Full metrics: PageRank, betweenness, cycles
bv --robot-alerts              # Stale issues, blocking cascades
bv --robot-suggest            # Hygiene: duplicates, missing deps, cycles
bv --robot-diff --diff-since <ref>  # Changes since ref

br ready --json                # Show issues ready to work (no blockers)
br list --status=open --json  # All open issues
br show <id> --json           # Full issue details with dependencies
br sync --flush-only          # Export DB to JSONL after Beads mutations
br sync --status --json       # VERIFY: `coverage_drift` must be false
```

### Workflow Pattern

1. **Triage**: Run `bv --robot-triage` to find the highest-impact actionable work
2. **Claim**: Create via `br create` (or `br update <id> --status=open` on an existing draft bead) — the bead also needs the `foreman-exec` label and a mapped `issue_type` (`implement_trd`, `implement_trd_beads`, `bug`, `feature`, or any type a manifest's `task_types:` names; `foreman doctor` row `workflows.bead_types` shows the current mapping); BeadsWatcher then dispatches `task.create` internally
3. **Dispatch**: Auto-approval (TRD-007) dispatches `task.approve` internally the moment the task is created; no separate operator action
4. **Complete**: Task auto-closes when run completes. To retry a failed or cancelled run, either re-open its bead (`br update <id> --status=open`) or submit `task.retry` via `POST /api/commands` (`CommandGateway` validates that the task's bound run is terminal and attaches `acknowledged_run_id`). Re-opening (foreman-pfta.1): `BeadsWatcher` retries a `failed` task whose bead line is `open` with an `updated_at` after the task's last event (`check_dedupe/2` → `{:retry_reopened, ...}` → `CommandGateway.dispatch_system_retry/2`, command id `beads-cmd:<project>:<bead>:retry-<n>`) and then re-approves it; a task that is active or `closed`, or a bead line not newer than the failure (the watcher rescans every line every poll, so this is what stops a bead that fails instantly from looping), is `:reconcile`d. Either way the watcher re-approves the retried task (foreman-nfizr, #687) under an approval id scoped by the task's `retry_count` (`beads-cmd:<project>:<bead>:auto-approve:retry-<n>`), so a NEW run starts; the count-0 id of a never-retried task is unchanged. Do not also send `task.approve`. `docs/user-guide.md` §7.2 "Recovering from a preflight failure" has the exact steps
5. **Sync**: Run the **Session Protocol** block as a single fail-closed script
   (`set -euo pipefail`), not as separate steps — the coverage gate must run
   ONLY after a flush that actually succeeded, since a failed flush leaves an
   older certified JSONL that still satisfies `coverage_drift == false` (it
   compares row counts, not content). Stage `.beads/issues.jsonl` after the
   flush, never before: `br` rewrites it on every mutation.

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready --json` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Git Policy

`br` never commits or pushes. Follow this repository's own git instructions before staging, committing, or pushing. If the repository says "commit only when asked," that rule overrides any generic workflow advice.

<!-- end-bv-agent-instructions -->


## Agent commits and `.beads` runtime files (foreman-okaf)

`Jobsite.Git.commit_all/3` used `git add -A`, and the `iterate` prompt only said "commit". Runtime files that `.beads/.gitignore` does not cover (`.br-wal-index-*`, `beads.db.bak`) were committed even with the file intact, and an agent that deleted `.beads/.gitignore` ("untrack runtime files") exposed every runtime file. Lesson: a `.gitignore` the agent can edit is not a guard. `commit_all/3` now stages `.beads` by allowlist (`issues.jsonl`, `config.yaml`, `metadata.json`), never stages `.beads/.gitignore` and restores it from HEAD if deleted; the prompt carries the same rules (explicit paths, `br sync --flush-only`, commit only `issues.jsonl`). A commit made by the agent itself inside the sandbox is covered by the prompt only.

**Gate before committing the ledger (foreman-kq4nr).** `br sync --flush-only` exits 0 with "Nothing to export" even when `issues.jsonl` is a fraction of the DB (see `beads-workflow-legacy.md`), so the `iterate` prompt now requires `br sync --status --json` -> `coverage_drift == false` (and no conflict markers) before `issues.jsonl` is committed; on drift the agent must not commit or hand-edit it and reports it in the closing comment. This guard is ADVISORY (prompt-only). `Jobsite.Git.commit_all/3` deliberately does not enforce it: it operates on an arbitrary jobsite worktree path (including projects with no beads ledger) where `br`/the worktree's local `beads.db` are not guaranteed, a worktree DB freshly built from the JSONL trivially reports no drift, and agent-made commits inside the sandbox bypass `commit_all` entirely, so a Foreman-side check would be false assurance or a new failure mode for non-beads runs.

## `agent_context` is a JSON string in every real br output (foreman-yqgvw)

Verified against `br` 0.6.0 (`br create --json`, `br show --json`, `br list --json`, `.beads/issues.jsonl`): `agent_context` is always a JSON-ENCODED STRING, whether the bead was created by `BeadsAdapter` (`system_br_runner` passes a string) or by hand with `--agent-context '{...}'`. Map-shaped test fixtures lied about this. One decoder, `TaskProviders.BeadsAgentContext.decode/1` (`{:ok, map} | :absent | {:error, :malformed}`), is the only place the field is parsed; `BeadsAdapter.derive_source_repo/1` and `BeadsWatcher.extract_trd_path/1` consume it (the adapter turns malformed into a `BR_CONTRACT_MISMATCH` error; the watcher treats it as "no trd_path" and blocks with the remediation comment).

One reader is deliberately NOT routed through it, because decoding would change behaviour on real data: `BeadsWatcher.foreman_tag?/1` is string-blind so Foreman-created gap beads (`Review.BeadSink`) are dispatched (`beads_watcher_gap_bead_test.exs`).

`BeadsOrphanJanitor.foreman_tag_classify/1` was map-only (inert on real data) until foreman-n3923; it now decodes with the shared decoder, which is only safe because of a gap-bead exemption. Gap beads carry a synthetic tag `task_id` (`review:<kind>:<id>`, built by `Review.BeadSink.gap_task_id/1`; there is no `kind` field in the envelope) and a task with `external_id == bead id` exists only after the watcher dispatches them, so without the exemption an undispatched gap bead older than `grace_ms` is closed as `foreman-orphan:no-task`. Rule: a gap bead (`BeadSink.gap_task_id?/1`) with NO task is retained (`:gap_awaiting_dispatch`); once a task exists the normal rules apply. A gap bead that is never dispatched (watcher off, dispatch held) stays open until an operator acts: the janitor does not time it out. Malformed context (not a JSON object) is never closed: counted in `lines_malformed` and logged at error level; absent context is untagged. Proven against a real `br` in `beads_orphan_janitor_real_br_test.exs` (note `br create` rejects non-JSON `--agent-context` but accepts any valid JSON, e.g. `[1,2]`). The janitor remains opt-in (`start_beads_orphan_janitor?`, default false).

`derive_source_repo` previously returned `nil` for every real create response, and its `source_repo` metadata has no reader today, so that bug was latent.
