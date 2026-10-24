# Archive agent sessions and auto-review every finished run

## Context

Today Foreman keeps almost nothing after an agent finishes. The jobsite door persists the provider
session id and the last iteration's text tail; the workflow door throws the session id away entirely
and keeps only redacted stdout/stderr lines. Nothing compares the delivered work with the request
that asked for it.

End state: every terminal run on both front doors leaves a durable on-disk **session archive**
(request, transcript, diff, manifest); an **analysis** agent then grades that archive against the
original request on four dimensions (correctness, tests, documentation, robustness) and saves its
verdict into the same archive and onto a new `ReviewRecorded` event. When the work originated from a
bead, the verdict is posted as a bead comment, and each identified gap becomes a new bead labelled
`foreman-exec` so Foreman picks it up and closes it.

Decisions already made (do not revisit): analysis runs on **all** terminal outcomes, success and
failure; the evaluator is a **fixed, separately configured** reviewer agent, not the run's own
provider; jobsites gain an **optional `bead_id`** so a bead-driven jobsite attaches like a workflow
run does.

## Approach

Steps 1-3 are independent of each other and each leaves the tree green. Step 4 depends on 1. Steps
5-7 depend on 4. Step 8 depends on 5.

### 1. `ForemanServer.Review.Archive` — the on-disk session archive

New file `packages/foreman_server/lib/foreman_server/review/archive.ex`.

Directory layout, one per subject:

```
<archive_root>/<kind>/<subject_id>/
  manifest.json       # see shape below
  request.md          # the original request text, verbatim
  transcript.jsonl    # one JSON object per captured agent event
  diff.patch          # unified diff of the delivered code vs its base
  changed-files.txt    # `git diff --name-status --find-renames <base>..HEAD` output
  analysis.json       # written in step 4
  analysis.md         # written in step 4
```

`kind` is the literal `"run"` or `"jobsite"`. `archive_root` defaults to
`Path.join([repo_path, ".foreman", "sessions"])`, matching the existing `.foreman/` convention
(`Jobsite.Logging.default_path/2` already writes to `.foreman/logs`). Override with
`config :foreman_server, :review, archive_root:`; a configured root is used verbatim with
`kind`/`subject_id` appended.

Public functions:

```elixir
@spec dir(kind :: :run | :jobsite, subject_id :: String.t(), repo_path :: String.t()) :: String.t()
@spec init(dir :: String.t(), manifest :: map()) :: :ok | {:error, Error.t()}
@spec put_manifest(dir :: String.t(), manifest :: map()) :: :ok | {:error, Error.t()}
@spec merge_manifest(dir :: String.t(), updates :: map()) :: :ok | {:error, Error.t()}
@spec read_manifest(dir :: String.t()) :: {:ok, map()} | {:error, Error.t()}
@spec write_file(dir :: String.t(), name :: String.t(), contents :: iodata()) :: :ok | {:error, Error.t()}
@spec append_events(dir :: String.t(), events :: [map()]) :: :ok | {:error, Error.t()}
@spec capture_enabled?() :: boolean()
```

`Error` here is a new `ForemanServer.Review.Error` struct modelled exactly on
`ForemanServer.Jobsite.Error` (fields `code`, `message`, `details`; `new/3`). Codes used across this
plan: `:archive_write_failed`, `:archive_missing`, `:archive_malformed`, `:diff_failed`,
`:evaluator_failed`, `:evaluator_malformed_output`, `:bead_unresolved`, `:bead_write_failed`.

`append_events/2` serialises each harness event as
`%{"type" => to_string(event.type), "timestamp" => event.timestamp, "text" => text}` where `text`
comes from the string key `payload["text"]` when present and `nil` otherwise — identical extraction
to `Jobsite.Logging.format/1` (`jobsite/logging.ex:60-67`); harness event payloads are string-keyed
and `JidoHarnessWorker`'s own comment at `overwatch/adapters/jido_harness_worker.ex` documents that
contract. Append stops writing once the file reaches `:max_transcript_bytes` and records
`transcript_truncated: true` in the manifest — a silently short transcript would be read as "the
agent said little".

Manifest shape (all keys always present; absent data is an explicit `null`, never a missing key):

```json
{
  "schema": "foreman.review.manifest.v1",
  "kind": "run",
  "subject_id": "run-abc",
  "project_id": "foreman",
  "repo_path": "/path/to/repo",
  "bead_id": null,
  "request": {"source": "task", "title": "...", "prompt": "...", "workflow_name": "implement-trd"},
  "agent": {"provider": "claude", "model": null},
  "provider_session_ids": ["c0ffee-..."],
  "branch": "agent/foreman-abc",
  "base_ref": "3e347319...",
  "worktree_path": "/path/to/.foreman/worktrees/...",
  "status": "completed",
  "started_at": "2026-01-01T00:00:00Z",
  "finished_at": "2026-01-01T00:10:00Z",
  "transcript_source": "harness_events",
  "transcript_truncated": false,
  "diff_status": "captured",
  "capture_errors": []
}
```

`diff_status` is one of `"captured"`, `"empty"`, `"unavailable"`. `capture_errors` is a list of
`{"stage": ..., "code": ..., "message": ...}` objects. Every write failure in steps 2-3 appends an
entry here and logs at `:warning`; capture must never fail a run, but a failed capture must never
look like a clean empty archive either.

`capture_enabled?/0` reads `config :foreman_server, :review, capture: true`.

Reuse `ForemanServer.Jobsite.Git` for every git invocation that already exists there. For the diff
itself no helper exists — add two to `jobsite/git.ex` next to `commits_between/3`:

```elixir
@spec diff(repo_path :: String.t(), base :: String.t(), head :: String.t()) :: {:ok, String.t()} | {:error, Error.t()}
@spec changed_files(repo_path :: String.t(), base :: String.t(), head :: String.t()) :: {:ok, String.t()} | {:error, Error.t()}
```

`diff/3` runs `git -C <repo_path> diff --find-renames <base>..<head>`; `changed_files/3` runs
`git -C <repo_path> diff --name-status --find-renames <base>..<head>`. Before building either argv,
validate `base` and `head` with the same ref guard
`ForemanServerWeb.OperatorDashboard.ChangeEvidence` uses (`operator_dashboard.ex:463+`): reject a ref
that begins with `-` or contains control/whitespace characters, so a projected ref can never become a
git option. Copy the guard predicate into `Jobsite.Git` as a private function rather than calling
into the web module — a lib module must not depend on `ForemanServerWeb`.

Add the config block to `config/config.exs`:

```elixir
config :foreman_server, :review,
  capture: true,
  analysis: true,
  archive_root: nil,
  agent: %{provider: :claude, model: nil, effort: nil},
  evaluator: ForemanServer.Review.Evaluator.Agent,
  evaluator_timeout_ms: 900_000,
  max_transcript_bytes: 2_000_000,
  max_diff_bytes: 1_000_000,
  max_comment_bytes: 8_000,
  max_gap_beads: 10
```

In `config/test.exs` add `config :foreman_server, :review, capture: false, analysis: false,
evaluator: ForemanServer.Review.Evaluator.Stub`. Capture must be off by default under test or every
jobsite/run test would write into the repo's own `.foreman/sessions`; the tests that exercise capture
turn it on per-test and point `archive_root` at a `tmp_dir`.

### 2. Capture on the jobsite door

**Transcript.** `Jobsite.Engine`'s `runner_opts` (engine.ex:498-509) already carries
`run_id: ctx.jobsite_id` and `cwd`. Add one more entry:

```elixir
archive_dir: ForemanServer.Review.Archive.dir(:jobsite, ctx.jobsite_id, ctx.repo_path)
```

`Runners.Direct` passes `opts` straight through, so `Jobsite.AgentRunner` receives it. In
`AgentRunner.build_result/4` (agent_runner.ex:287-304), before constructing the `%IterationResult{}`,
call `Review.Capture.put_iteration(archive_dir, result)` when `archive_dir` is set and
`Archive.capture_enabled?/0`. That helper appends `result.events` to `transcript.jsonl` and merges
`provider_session_ids` into the manifest. `%Jido.Harness.RunResult{}` carries `events` (an array of
`Jido.Harness.Event`) and `provider_session_id`
(`deps/jido_harness/lib/jido_harness/run/result.ex:14-27`), so no new data has to be threaded.

Also call it from `failed_result_error/1`'s two clauses (agent_runner.ex:264-276) so a failed
iteration still archives what the agent produced. These take a `%RunResult{}` too.

Do not touch `Runners.Overwatch`: its declared capability is `live_stream: false` and it never sees a
`RunResult`. The workflow door gets its transcript in step 3 from data it already persists.

**Request + manifest.** In `Jobsite.Executor.execute/2` (executor.ex), immediately before
`Engine.run_program`, call `Review.Capture.open_jobsite(jobsite_id, spec, prompt)`. It creates the
archive directory, writes `request.md` from the resolved prompt text, and writes the initial manifest
from the spec (`repo_path`, `strategy`, agent provider/model, `bead_id`, `name`). The resolved prompt
is what `Engine` passes to the runner; take it from the same place `build_program/2` resolves it so
the archived request is byte-identical to the prompt the agent saw.

**Diff.** In `Jobsite.Executor.Observer.step_completed(%{kind: :commit}, ctx, {:commit, outcome},
state)` (executor/observer.ex), after `commits_record/2` succeeds and before dispatching
`jobsite.commits.record`, call `Review.Capture.put_diff(archive_dir, ctx.worktree.path,
ctx.worktree.base_sha, "HEAD")`. This is the last step at which the worktree is guaranteed alive —
the program's `:release` step closes it, and that runs inside `Engine` before `Executor` ever
dispatches `jobsite.complete`.

**`bead_id` on the jobsite door.** Thread one new optional value end to end:

- `Jobsite.Spec`: add `"bead_id"` to `@allowed_keys` (spec.ex:42-44). Validate it as a non-empty
  binary or absent; a present-but-invalid value is `{:error, Error.new(:spec_option_invalid, ...)}`,
  reusing the existing code rather than minting a new one.
- `Jobsite.Executor.build_spec/2` (executor.ex:98-124): add `bead_id: Keyword.get(opts, :bead_id)`
  to the returned map.
- `Jobsite.Executor.start_payload/2` (executor.ex:729-749): add `bead_id: spec.bead_id`.
- `Events.JobsiteStarted` (events/jobsite_started.ex): add `bead_id: String.t() | nil` to the
  typespec and to `defstruct`. It is not an enforced key, so historical events still decode.
- `Aggregates.Jobsite`: accept and store `bead_id` on the `jobsite.start` command exactly as `name`
  is handled today.
- `ProjectionStore` `"JobsiteStarted"` handler (projection_store.ex:1905+): add `bead_id` to the
  projected jobsite map, defaulting to `nil`.

### 3. Capture on the workflow door

The workflow door already persists its agent output durably as `WorkerStdout`/`WorkerStderr` events,
readable through `ProjectionStore.run_logs/1`. Use that as the transcript source instead of modifying
`Overwatch`, `JidoHarnessWorker` or `RunExecutor`'s agent path — none of which currently sees a
`RunResult` the way the jobsite door does.

Only one edit to `run_executor.ex` is needed, and it is the diff capture.

`cleanup_run_worktree/2` (run_executor.ex:2818) is the single funnel both terminal paths pass
through: `finalize_run/1` calls it with `:success` at line 1501, and `finalize_terminal_and_stop/2`
calls it with `:failure` at line 3694. Insert the capture as the **first** statement of
`cleanup_run_worktree/2`, before `warn_uncommitted_work(state)`:

```elixir
_ = ForemanServer.Review.Capture.close_run(state, outcome)
```

`close_run/2` creates or updates the archive for `state.run_id`, writes `request.md` and the manifest
(see below), and captures the diff from `state.run_worktree` — a map with `worktree_path` and
`base_ref` keys (run_executor.ex:700-712, 846-847). It must never raise and never return a value the
caller depends on; wrap its body so any exception is logged and recorded in `capture_errors`.

The manifest's `request` block for a run comes from the projections, not from new plumbing:

- `ProjectionStore.run(run_id)` gives `task_id`, `project_id`, `workflow_name`.
- `ProjectionStore.task_projection(task_id)` gives `title`, `description`, `prompt`, `external_id`.
  `external_id` **is** the bead id — that is the bead link for the workflow door
  (`beads_watcher.ex` sets `external_id` to the bead id when synthesising `task.create`).

The transcript is materialised at analysis time, not at capture time, by
`Review.Capture.transcript_from_run_logs/2`: call `ProjectionStore.run_logs(run_id)`, write one JSONL
object per entry (`%{"type" => entry.channel, "timestamp" => entry.timestamp, "text" =>
entry.content}`), and set `transcript_source: "run_logs"` plus `transcript_truncated` from the
result's own `truncated` flag. `run_logs/1` returns `{:ok, %{entries:, truncated:, omitted_entries:,
omitted_bytes:}}` or `{:error, :run_not_found}`; carry `omitted_entries`/`omitted_bytes` into the
manifest so a bounded log is visibly bounded.

### 4. `Review.Analyzer` — react to terminal events and produce a verdict

New files under `lib/foreman_server/review/`: `analyzer.ex`, `subject.ex`, `verdict.ex`,
`evaluator.ex`, `evaluator/agent.ex`, `evaluator/stub.ex`, `prompt.ex`.

`Review.Analyzer` is a `GenServer` that calls `ProjectionStore.subscribe(replay_existing: false)` in
`init/1` and handles `{:projection_event, %{event_type: type, data: payload}}`. `replay_existing:
false` is deliberate: a restart must not re-analyze every historical run.

Reacted-to event types, exactly these four literals:
`"RunCompleted"`, `"RunFailed"`, `"JobsiteCompleted"`, `"JobsiteFailed"`.

Everything else returns `{:noreply, state}` unchanged.

For each matched event the analyzer builds a `%Review.Subject{}`:

```elixir
@enforce_keys [:kind, :subject_id, :project_id, :repo_path, :archive_dir, :status]
defstruct [:kind, :subject_id, :project_id, :repo_path, :archive_dir, :status,
           :bead_id, :request_title, :request_text, :workflow_name]
```

- `:run` subjects resolve through `ProjectionStore.run/1` → `task_projection/1`; `bead_id` is the
  task's `external_id`. `repo_path` comes from the run's worktree projection
  (`ProjectionStore.worktrees_for_run/1`, field `repo_path`).
- `:jobsite` subjects resolve through `ProjectionStore.jobsite/1`; `repo_path` and `bead_id` are both
  on that projection after step 2.

The analyzer then runs the evaluation under
`Task.Supervisor.start_child(ForemanServer.Review.TaskSupervisor, fn -> ... end)` so a slow agent
never blocks the projection subscriber. Add `{Task.Supervisor, name:
ForemanServer.Review.TaskSupervisor}` and the analyzer itself to `application.ex`, gated by a new
`maybe_review_children/0` following the existing `maybe_messaging_dispatcher_child/0` shape
(application.ex:208-214), keyed on `Application.get_env(:foreman_server, :review, [])[:analysis]`.

The supervised task does, in order:

1. `Review.Capture.finalize(subject)` — materialise the workflow transcript if needed and merge
   `status`/`finished_at` into the manifest.
2. `evaluator().evaluate(subject)` where `evaluator()` reads
   `config :foreman_server, :review, :evaluator`.
3. Write `analysis.json` (the verdict, serialised) and `analysis.md` (human-readable) into the
   archive.
4. Dispatch `review.record` (step 5).
5. Call `Review.BeadSink.publish(subject, verdict)` (step 6).

A failed evaluation is still recorded: build a `%Verdict{verdict: :undetermined, error_code:
<atom>, summary: <reason>}` and run steps 3-5 with it. Never skip the event — an analysis that
silently did not happen is indistinguishable from a run nobody reviewed.

`Review.Verdict`:

```elixir
@enforce_keys [:verdict, :summary]
@type dimension :: :correctness | :tests | :documentation | :robustness
@type t :: %__MODULE__{
        verdict: :met | :partially_met | :not_met | :undetermined,
        scores: %{dimension() => 1..5},
        summary: String.t(),
        gaps: [ForemanServer.Review.Gap.t()],
        error_code: atom() | nil
      }
defstruct [:verdict, :summary, scores: %{}, gaps: [], error_code: nil]
```

`Review.Gap`:

```elixir
@enforce_keys [:title, :description, :dimension, :severity]
@type t :: %__MODULE__{title: String.t(), description: String.t(),
                       dimension: Verdict.dimension(), severity: :major | :minor}
```

`Review.Evaluator` is a behaviour with a single callback
`@callback evaluate(Subject.t()) :: {:ok, Verdict.t()} | {:error, Review.Error.t()}`.

`Review.Evaluator.Agent` is the production implementation:

- Renders the prompt with `Review.Prompt.render/1` from a template read at runtime from
  `Path.join(:code.priv_dir(:foreman_server), "review/analysis_prompt.md")`. Put the template at
  `packages/foreman_server/priv/review/analysis_prompt.md` — **not** under
  `priv/defaults/workflows/prompts/`, which `foreman init --force` installs into user projects as
  workflow phase prompts.
- The prompt embeds the request title and text, the manifest, the archive's absolute paths, and
  instructs the agent to read `diff.patch`, `changed-files.txt` and `transcript.jsonl` itself, then
  emit exactly one fenced ```json block with keys `verdict`, `scores`, `summary`, `gaps`.
- Runs the agent through `ForemanServer.AgentRuntime.JidoHarness.DetachedRun.start_run/3` +
  `await_run/2` — the existing thin façade over `Jido.Harness.Run`, already covered by
  `test/foreman_server/agent_runtime/jido_harness/detached_run_test.exs`. Build the request with
  `Jido.Harness.RunRequest.new/1`:

  ```elixir
  %{prompt: prompt,
    provider: cfg.agent.provider,
    cwd: subject.repo_path,
    model: cfg.agent.model,
    reasoning_effort: cfg.agent.effort,
    approval_mode: :default,
    sandbox_mode: :read_only,
    runtime_timeout_ms: cfg.evaluator_timeout_ms,
    idle_timeout_ms: cfg.evaluator_timeout_ms}
  ```

  `sandbox_mode: :read_only` and `approval_mode: :default` together keep the reviewer from editing
  the repo it is grading; both are real `RunRequest` enum values
  (`deps/jido_harness/lib/jido_harness/run/request.ex:4-6, 48-49`).
- Parses the JSON block strictly. A missing block, a JSON decode failure, an unknown `verdict` value,
  a score outside `1..5`, or a gap missing a key is `{:error, Review.Error.new(:evaluator_malformed_output, ...)}` —
  never a partially filled verdict. Also archive the evaluator's own `RunResult.events` as
  `evaluator-transcript.jsonl` so a bad verdict can be traced.

`Review.Evaluator.Stub` returns a verdict read from `Application.get_env(:foreman_server,
:review_stub_verdict)`, defaulting to a `:met` verdict with no gaps. This is what makes steps 4-7
testable without spawning a provider CLI.

### 5. `review:` aggregate and the `ReviewRecorded` event

New `lib/foreman_server/events/review_recorded.ex`, following `events/jobsite_request_audited.ex`
exactly (`@derive Jason.Encoder`, `@enforce_keys`, full typespec). `EventCodec` discovers it by
scanning `lib/foreman_server/events/**/*.ex`, so no registry edit is needed.

```elixir
@enforce_keys [:subject_kind, :subject_id, :project_id, :verdict, :at]
subject_kind: String.t(),        # "run" | "jobsite"
subject_id: String.t(),
project_id: String.t(),
bead_id: String.t() | nil,
verdict: String.t(),             # "met" | "partially_met" | "not_met" | "undetermined"
scores: map() | nil,
summary: String.t(),
gap_bead_ids: [String.t()],
archive_path: String.t() | nil,
analysis_path: String.t() | nil,
evaluator: String.t() | nil,     # e.g. "agent:claude"
error_code: String.t() | nil,
at: String.t()
```

New `lib/foreman_server/aggregates/review.ex`, modelled on `aggregates/jobsite_audit.ex` (the
smallest complete aggregate in the repo):

- Stream id is `"review:" <> subject_kind <> ":" <> subject_id`.
- Handles one command type, the literal `"review.record"`, emitting `"ReviewRecorded"`.
- `apply_event/2` keeps a `%State{recorded: boolean(), verdict: String.t() | nil}` and **must** have
  the `_ -> state` catch-all clause `Aggregates.Phase` has; `Aggregates.Run` lacks one and new event
  types on its streams crash replay.
- Validates `subject_kind` against `~w(run jobsite)` and `verdict` against
  `~w(met partially_met not_met undetermined)`, each with its own distinct error tuple
  (`{:invalid_subject_kind, value}` vs `{:missing_or_invalid, :subject_kind}`).

Register the prefix in `command_router.ex` next to the other `aggregate_module_for/1` clauses
(command_router.ex:571-592):

```elixir
def aggregate_module_for("review:" <> _), do: ForemanServer.Aggregates.Review
```

Dispatch through `CommandGateway.dispatch_system/2` with
`command_id: "review:" <> kind <> ":" <> subject_id`, which makes the whole record idempotent via
`CommandRouter`'s deterministic event id. Do **not** add `review.record` to the operator allowlist —
it is system automation, like `jobsite.audit.record`.

Add a `ProjectionStore` handler for `"ReviewRecorded"` beside the existing ones, storing into a new
`state.reviews` map keyed by `{subject_kind, subject_id}`, and expose:

```elixir
@spec review(String.t(), String.t()) :: map() | nil
def review(subject_kind, subject_id)
```

`ProjectionStore.init/1` rebuilds from the event log, so the handler must not raise on a malformed
payload — follow the surrounding handlers' `decode_for_projection/2` pattern.

### 6. `Review.BeadSink` — comment on the source bead, open beads for gaps

New `lib/foreman_server/review/bead_sink.ex`.

`publish(subject, verdict)` returns `{:ok, gap_bead_ids}` or `{:error, Review.Error.t()}`:

1. `subject.bead_id == nil` → `{:ok, []}`. Log at `:info`. This is the explicitly requested
   conditional: non-bead work gets an archive and an event, nothing more.
2. Resolve the provider with `TaskProvider.Registry.project_config(subject.project_id)`, which
   returns `{:ok, %{provider_module: mod, config: cfg}}`. A `{:error, _}` here is
   `:bead_unresolved` — do not fall back to a default provider.
3. Post the comment: `mod.annotate(subject.bead_id, body, cfg)`. `body` is the markdown verdict,
   truncated to `:max_comment_bytes` with a trailing pointer to the absolute `analysis.md` path.
   `BeadsAdapter.annotate/3` passes the body as a single `--message` argv element, so an untruncated
   multi-megabyte body would hit the OS argv limit.
4. Create one bead per gap, capped at `:max_gap_beads`, via `mod.create(subject.project_id, attrs)`:

   ```elixir
   %{title: gap.title,
     description: <<gap.description, source attribution, archive path>>,
     priority: 2,                       # severity :major -> 1, :minor -> 3, default 2
     task_type: "bug",                  # :major -> "bug", :minor -> "chore"
     task_id: "review:" <> subject.kind <> ":" <> subject.subject_id,
     command_id: "review:" <> subject.subject_id <> ":gap:" <> index,
     labels: ["foreman-exec", "foreman-gap"]}
   ```

   `task_type` must be one of `BeadsAdapter`'s `@valid_task_types`
   (`task bug feature epic chore docs question`, beads_adapter.ex:68) or `create/2` rejects it, and
   `priority` must be an integer in `0..4`. `task_id` and `command_id` are required non-empty
   correlation handles (`validate_create_attrs/1`, beads_adapter.ex:2850-2866).

   The description must be self-contained — the bead is dispatched to a fresh agent with no memory of
   this run. Include the gap text, the originating bead id, the subject id, and the absolute archive
   path.

**Loop guard.** A gap bead is labelled `foreman-exec`, so `BeadsWatcher` auto-dispatches it
(`check_labels/2`, beads_watcher.ex:1050-1090), that run is itself analyzed, and its gaps would spawn
more beads. Before creating any gap bead, fetch the source bead with `mod.get(subject.bead_id, cfg)`
and skip gap creation entirely when its `labels` contain `"foreman-gap"`. The comment is still
posted. That caps the chain at depth 1. Record the decision in the `ReviewRecorded` summary so a
suppressed round is visible rather than silent.

Do **not** rely on `BeadsWatcher.foreman_tag?/1` for this. It tests `is_map(agent_context)`
(beads_watcher.ex:959-962), but `br` round-trips `agent_context` as a JSON *string* — confirmed
against the repo's own `.beads/issues.jsonl`, where every record carries
`"agent_context":"{\"foreman\":{...}"`. That guard therefore does not fire today, which is precisely
why gap beads are dispatchable at all. Pin that behaviour with the test in step 8 so a future change
to `foreman_tag?/1` fails loudly instead of silently disabling this feature.

### 7. `--labels` support on bead creation

`br create` accepts `-l, --labels <LABELS>` as a comma-separated list — verified against
`br create --help` on `br 0.6.0`. Three edits:

1. `TaskProviders.SystemBrRunner.build_action_argv(:create, payload)` (system_br_runner.ex:251-267):
   append `["--labels", Enum.join(labels, ",")]` when `payload[:labels]` is a non-empty list, before
   `maybe_append_json_flag/1`. Absent or `[]` adds no flag.
2. `SystemBrRunner.validate_payload_shape!(:create, payload)` (system_br_runner.ex:336+): add a
   clause raising `ArgumentError` unless `:labels` is absent or a list of non-empty binaries
   containing no comma. A label with an embedded comma would silently split into two labels.
3. `BeadsAdapter.build_create_payload/1` (beads_adapter.ex:2970-3000): carry `:labels` from `attrs`
   into the payload when present.

`TaskProvider`'s `create/2` callback takes an open `attrs` map, so the behaviour itself does not
change and no other provider is affected. Add `:label` to `BeadsAdapter.capabilities/0`'s `supports`
list (beads_adapter.ex:40-58) so the capability map stops under-reporting.

### 8. Tests

Behaviour-defining tests, not cleanup. New files under `packages/foreman_server/test/`:

- `foreman_server/review/archive_test.exs` — manifest round-trip; `append_events/2` truncation sets
  `transcript_truncated: true`; a write failure into an unwritable directory produces a
  `capture_errors` entry and `{:error, %Review.Error{code: :archive_write_failed}}`, not a silent
  `:ok`.
- `foreman_server/jobsite/git_diff_test.exs` — `Jobsite.Git.diff/3` and `changed_files/3` against a
  real temp repo with two commits; a `base` of `"--upload-pack=evil"` returns an error and never
  reaches git.
- `foreman_server/review/analyzer_test.exs` — with `Evaluator.Stub` configured, feeding a synthetic
  `"RunCompleted"` projection event writes `analysis.json`/`analysis.md` and appends exactly one
  `ReviewRecorded` to `review:run:<id>`; a second identical event appends no second record
  (idempotency via `command_id`); a stub returning `{:error, _}` still produces a `ReviewRecorded`
  with `verdict: "undetermined"` and a non-null `error_code`.
- `foreman_server/review/evaluator_agent_test.exs` — the strict parser: a well-formed JSON block
  parses; a missing block, a bad `verdict` string, a score of `0` and a gap missing `dimension` each
  return `{:error, %Review.Error{code: :evaluator_malformed_output}}`.
- `foreman_server/review/bead_sink_test.exs` — with a stub `BrRunner` (the `@runner` seam
  `BeadsAdapter` already uses), assert the exact argv for the comment and for each gap bead, that the
  gap argv contains `--labels` with `foreman-exec,foreman-gap`, that a source bead already carrying
  `foreman-gap` yields zero gap beads but still one comment, and that a `nil` bead id yields
  `{:ok, []}` with no `br` invocation at all.
- `foreman_server/task_providers/system_br_runner_labels_test.exs` — argv assertions for absent,
  empty and populated `:labels`, plus the `ArgumentError` for a label containing a comma.
- `foreman_server/task_providers/beads_watcher_gap_bead_test.exs` — the regression pin: a JSONL line
  shaped exactly like a Foreman-created gap bead (`agent_context` as a JSON **string**, labels
  `["foreman-exec","foreman-gap"]`, status `open`, a mapped `issue_type`) is dispatched, not skipped.

Extend existing suites rather than duplicating them:

- `test/foreman_server/jobsite/` — a jobsite run with `capture: true` and `archive_root` in a
  `tmp_dir` produces `transcript.jsonl`, `request.md`, `diff.patch` and a manifest naming the
  provider session id.
- `test/foreman_server/jobsite/spec_test.exs` — `bead_id` is accepted, lands on `JobsiteStarted`, and
  an empty-string `bead_id` is rejected with `:spec_option_invalid`.

## Critical files & anchors

| File | Anchor | Why |
|---|---|---|
| `lib/foreman_server/jobsite/engine.ex` | `runner_opts` list, ~498-509 | The one place both doors' runners get their options; `archive_dir` goes here. |
| `lib/foreman_server/workflow/run_executor.ex` | `cleanup_run_worktree/2`, 2818 | Single funnel for both terminal paths (callers at 1501 and 3694) and the last moment the worktree exists. |
| `lib/foreman_server/jobsite/executor/observer.ex` | `step_completed(%{kind: :commit}, ...)` | Jobsite diff capture point, before the program's `:release` step. |
| `lib/foreman_server/aggregates/jobsite_audit.ex` | whole file | Template for `Aggregates.Review`: smallest complete aggregate + typed event + validation style. |
| `lib/foreman_server/task_providers/system_br_runner.ex` | `build_action_argv(:create, ...)`, 251 | Sole `br` argv site; `--labels` goes here, nowhere else. |

## Verification

All commands run from `packages/foreman_server` inside `devbox run`. Never append `; echo $?` to a
`devbox run -- bash -c '...'` string — devbox expands `$` in the string and always reports `0`. Read
the `Result: N passed` line instead.

1. **Suite.** `mix test --warnings-as-errors`. Baseline on `main` is `Result: 3201 passed (3
   properties, 3198 tests), 13 excluded`; expect that plus the new tests, with zero failures.
2. **Targeted.** `mix test test/foreman_server/review test/foreman_server/jobsite
   test/foreman_server/task_providers/system_br_runner_labels_test.exs
   test/foreman_server/task_providers/beads_watcher_gap_bead_test.exs`.
3. **Mutation check on the loop guard** (the one assertion most likely to be vacuous): in
   `BeadSink`, invert the `"foreman-gap"` label check, re-run `bead_sink_test.exs`, and confirm the
   "source bead already labelled foreman-gap yields zero gap beads" test fails. Restore.
4. **End-to-end, real agent, real bead.** Requires a configured `br` database and a provider CLI on
   `PATH`.

   ```
   br create "Add a /healthz route returning 200" -t task -p 2 -l foreman-exec
   ```

   Let the workflow run to completion, then assert all four observable outcomes:
   - `ls .foreman/sessions/run/<run_id>/` lists `manifest.json`, `request.md`, `transcript.jsonl`,
     `diff.patch`, `changed-files.txt`, `analysis.json`, `analysis.md`.
   - `jq -r '.verdict, .scores' .foreman/sessions/run/<run_id>/analysis.json` prints one of the four
     verdict strings and four integer scores.
   - `br comments list <bead_id>` shows the analysis comment.
   - `br list -l foreman-gap --json` shows one bead per reported gap, each also carrying
     `foreman-exec`, and each with a description that names the originating bead and the archive path.
5. **Depth cap.** Let one of those gap beads run to completion. Assert `br list -l foreman-gap`
   gained **no** new beads from it, and that its own `ReviewRecorded` summary says gap creation was
   suppressed.
6. **Capture is off in test by default.** After the full suite, `git status --short` must show no new
   `.foreman/sessions/` paths in the repo.

## Assumptions & contingencies

- **`br` is at 0.6.0 and `br create -l/--labels` is comma-separated.** Verified this session against
  `br create --help`. If the installed `br` rejects `--labels`, use `br update <id> --add-label` as a
  second call immediately after create, from `SystemBrRunner`'s existing generic
  `{:update, %{flags: [...]}}` request shape — a create without its label is worse than two calls,
  because an unlabelled gap bead is never dispatched.
- **The evaluating agent's provider CLI is installed and authenticated on the server.** If
  `DetachedRun.start_run/3` returns a provider-unavailable error, the analyzer records
  `verdict: "undetermined"` with that `error_code` and still posts no gap beads; archives keep
  accumulating and remain analyzable later. No fallback to a second provider — a silent downgrade to
  a weaker reviewer would make verdicts incomparable, which is the whole reason the reviewer agent is
  fixed by config.
- **`ProjectionStore.run_logs/1` is the workflow door's transcript.** It is bounded (10,000 lines /
  5 MiB, redacted) and in-memory. If a run's logs are reported `truncated`, that is recorded in the
  manifest, not hidden. If this proves too lossy to grade against in practice, the follow-on is to
  read the `worker:<run_id>:<worker_id>` streams from the event store directly — same JSONL output,
  same manifest field, no change to anything downstream.
- **Archiving is on by default, analysis is on by default.** Analysis spends one agent invocation per
  terminal run. To stop the spend without losing archives, set
  `config :foreman_server, :review, analysis: false`; archives keep being written and can be analyzed
  later.
