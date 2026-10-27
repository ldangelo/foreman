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
4. **Complete**: Task auto-closes when run completes. To retry a failed or cancelled run, submit `task.retry` via `POST /api/commands`: `CommandGateway` validates that the task's bound run is terminal and attaches `acknowledged_run_id`. Re-opening the bead (`br update <id> --status=open`) does not retry: once the task is past `"open"`, `BeadsWatcher` dedupes and reconciles it (`check_dedupe/2` → `:reconcile`) instead of dispatching again. `task.retry` alone does not dispatch either: it returns the task to `open`, and the watcher's re-approval then reuses the deterministic `beads-cmd:<project>:<bead>:auto-approve` command id, which replays the original approval (verified 2026-10-26: the task stays `open` with no run bound). Send a fresh `task.approve` (new `command_id`, `approved_by`) after `task.retry` to mint a new run; `docs/user-guide.md` §7.2 "Recovering from a preflight failure" has the exact steps
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

