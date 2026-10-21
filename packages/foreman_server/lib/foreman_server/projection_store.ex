defmodule ForemanServer.ProjectionStore do
  @moduledoc """
  In-memory projection read model for domain queries.

  Maintains projected state for projects, runs, and PR associations
  by applying confirmed events synchronously after each successful
  append.

  ## Startup

  On `init/1`, rebuilds the entire read model by replaying all events from the
  event log via `read_all_streams_forward`. This ensures the projection is always
  consistent with the event store at startup.

  ## Command path

  After `CommandRouter.append_events` succeeds, it calls
  `ProjectionStore.apply_events(events)` before sending `append_ok` to the actor.
  This keeps the projection synchronous with the command path — no eventual consistency.

  ## Query

  `project/1` returns the projected state for a given project_id.
  `run/1` returns the projected state for a given run_id.
  `pr_association/1` returns the current PR association for a given run_id.
  """

  use GenServer

  require Logger

  alias EventStore.{EventData, Page, RecordedEvent}
  alias EventStore.Streams.StreamInfo
  alias ForemanServer.{EventCodec, EventStore}
  alias ForemanServer.Events.{UsageRecorded, WorkerSessionBound, WorkerStderr, WorkerStdout}
  alias ForemanServer.Usage
  alias ForemanServer.Usage.Ledger, as: UsageLedger

  @pr_fold_events ForemanServer.Overview.PrFold.events()
  @pr_watch_only_events ForemanServer.PrWatchFold.events() -- @pr_fold_events
  @active_run_statuses ["awaiting_worker", "in_progress"]

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc "Return the projected state for a project, or nil if not found."
  @spec project(String.t()) :: map() | nil
  def project(project_id) do
    GenServer.call(__MODULE__, {:project, project_id})
  end

  @doc "Return the active run ids."
  @spec active_runs() :: [String.t()]
  def active_runs do
    GenServer.call(__MODULE__, :active_runs)
  end

  @doc """
  Canonical list of run statuses that count as "actively dispatching" —
  i.e. holding a project slot and not yet terminal. Reuse this for any
  check that wants to know whether a run is still in flight.

  Currently `"awaiting_worker"` (admitted but no worker attached yet)
  and `"in_progress"` (worker attached and acknowledged). Adding a new
  pre-terminal state? Add it here and only here.
  """
  @spec active_run_statuses() :: [String.t()]
  def active_run_statuses, do: @active_run_statuses

  @doc "Return active runs whose last activity is older than the threshold."
  @spec stuck_runs(non_neg_integer(), integer() | nil) :: [String.t()]
  def stuck_runs(threshold_ms, now_ms \\ nil)
      when is_integer(threshold_ms) and threshold_ms >= 0 do
    GenServer.call(__MODULE__, {:stuck_runs, threshold_ms, normalize_now_ms_fun(now_ms)})
  end

  @spec stall_candidates(integer() | nil) :: [map()]
  def stall_candidates(now_ms \\ nil) do
    GenServer.call(__MODULE__, {:stall_candidates, normalize_now_ms_fun(now_ms)})
  end

  @doc """
  Apply a list of confirmed events to the projection.

  Called by CommandRouter after a successful append, before replying to the actor.
  """
  @spec apply_events([EventData.t() | RecordedEvent.t() | map()]) :: :ok
  def apply_events(events) do
    GenServer.call(__MODULE__, {:apply_events, events, resolve_now_ms_fun()})
  end

  @doc """
  Rebuild the entire projection from the committed event log.

  Leaves the current projection state untouched if the rebuild read fails.
  """
  @spec rebuild([EventData.t() | RecordedEvent.t() | map()]) :: :ok | {:error, term()}
  def rebuild(recovered_events) when is_list(recovered_events) do
    GenServer.call(__MODULE__, {:rebuild, recovered_events, resolve_now_ms_fun()})
  end

  @doc """
  Rebuild one project's projection from its committed aggregate stream.

  Leaves the current projection state untouched if the stream read fails.
  """
  @spec rebuild_project(String.t(), [EventData.t() | RecordedEvent.t() | map()]) ::
          :ok | {:error, term()}
  def rebuild_project(project_id, recovered_events)
      when is_binary(project_id) and project_id != "" and is_list(recovered_events) do
    GenServer.call(
      __MODULE__,
      {:rebuild_project, project_id, recovered_events, resolve_now_ms_fun()}
    )
  end

  @doc """
  Subscribe the caller to projection events.

  `opts` accepts only `replay_existing: boolean()`; an empty list is also
  valid. An unknown key, a duplicate `replay_existing` entry, or a
  non-boolean value raises -- caller error, not a runtime condition to
  degrade past.

  With `replay_existing: true`, the caller is registered first, then the
  committed event log is replayed into its mailbox before this call returns.
  That closes the startup gap for long-lived subscribers: events committed
  before subscription are replayed, and events committed after subscription are
  queued behind the subscription call and delivered by the normal broadcast path.

  **Delivery is at-least-once, not exactly-once.** The replay read
  (`EventStore.read_all_streams_forward/2`) is a direct, out-of-band read of
  the durable log; it can observe an event that this GenServer's own mailbox
  has not yet processed and broadcast (the store-to-mailbox path has its own
  latency independent of request ordering). A subscriber can therefore
  receive the same event twice: once via replay, once via the normal live
  broadcast that fires immediately after. Building exactly-once delivery here
  (e.g. a per-subscriber replay cursor) was deliberately rejected in favor of
  every consumer of this event stream being idempotent against its own
  current projection state -- the simpler, standard at-least-once pattern.
  `ForemanServer.Workflow.Dispatcher`, the only caller of `replay_existing:
  true`, satisfies this: `TaskApproved`/`TaskDispatched` re-check live
  projection status before acting (`task_ready_for_approval?/2`, the
  `%{status: "in_progress"} = task_proj` match), and every terminal-event
  side effect it dispatches (`lease.release`, `lease.remove_waiter`,
  `run_slots.release`, `task.run_terminated`'s deterministic command_id,
  worktree cleanup's explicit `{:ok, :already_cleaned}` case) is independently
  idempotent. Do not add a new subscriber to this event stream without the
  same property.
  """
  @spec subscribe(keyword()) :: :ok | {:error, term()}
  def subscribe(opts \\ []) when is_list(opts) do
    validated = validate_subscribe_opts!(opts)
    GenServer.call(__MODULE__, {:subscribe, validated}, 30_000)
  end

  @subscribe_keys [:replay_existing]

  defp validate_subscribe_opts!(opts) do
    Enum.each(opts, fn
      {:replay_existing, v} when is_boolean(v) ->
        :ok

      {:replay_existing, v} ->
        raise ArgumentError, "replay_existing must be boolean, got: #{inspect(v)}"

      {key, _} ->
        raise ArgumentError, "unknown ProjectionStore.subscribe/1 option: #{inspect(key)}"
    end)

    seen_keys = Keyword.keys(opts)

    if length(seen_keys) != length(Enum.uniq(seen_keys)) do
      raise ArgumentError, "duplicate ProjectionStore.subscribe/1 option in #{inspect(opts)}"
    end

    unless MapSet.subset?(MapSet.new(seen_keys), MapSet.new(@subscribe_keys)) do
      raise ArgumentError, "unknown ProjectionStore.subscribe/1 option in #{inspect(opts)}"
    end

    opts
  end

  @doc "Return the projected state for a task, or nil if not found."
  @spec task_projection(String.t()) :: map() | nil
  def task_projection(task_id) when is_binary(task_id) and task_id != "" do
    GenServer.call(__MODULE__, {:task_projection, task_id})
  end

  @doc """
  Return the projected task that owns the given bead id (`:external_id`), or nil.

  Used by the Beads watcher dedupe path: before dispatching
  `task.create`, the watcher looks up the existing task by its
  `external_id` to decide between `[:watcher, :reconciled]`
  (already imported) and `[:watcher, :imported]` (new).
  """
  @spec get_task(keyword()) :: map() | nil
  def get_task(opts) when is_list(opts) do
    case opts do
      [external_id: external_id] when is_binary(external_id) and external_id != "" ->
        GenServer.call(__MODULE__, {:get_task_by_external_id, external_id})

      _ ->
        raise ArgumentError,
              "ProjectionStore.get_task/1 expects [external_id: binary]; got #{inspect(opts)}"
    end
  end

  @doc """
  Return every task projection that is currently bound to `run_id`.

  Used by the run-cancellation fanout path so the dispatcher can
  emit a `task.run_terminated` for each affected task. Tasks whose
  previous run already had a terminal acknowledgement are filtered
  out — the operator path is idempotent and a stale re-fire MUST NOT
  rewrite `acknowledged_run_id` against the same run twice.
  """
  @spec tasks_by_run_id(String.t()) :: [map()]
  def tasks_by_run_id(run_id) when is_binary(run_id) and run_id != "" do
    GenServer.call(__MODULE__, {:tasks_by_run_id, run_id})
  end

  @doc "Return every projected task. Used by boot reconciliation to scan run orphans."
  @spec list_tasks() :: [map()]
  def list_tasks do
    GenServer.call(__MODULE__, :list_tasks)
  end

  @doc """
  Return the projected state for a run, or nil if not found.

  `pr_url` is always present on a projected run: a string once a `PrAssociated`
  event has been applied, `nil` when Foreman has recorded no PR for the run. A
  `PrAssociated` event carrying no usable URL raises rather than projecting
  `nil`, so an explicit `nil` never stands in for a lost association.
  """
  @spec run(String.t()) :: map() | nil
  def run(run_id) when is_binary(run_id) and run_id != "" do
    GenServer.call(__MODULE__, {:run, run_id})
  end

  @doc """
  Return the run's pending steering messages (`RunSteerQueued` minus
  `RunSteerConsumed`) in queue order as `[%{message_id, text, resume,
  approval_mode_override}]` (the override is nil unless an approval set it).

  This is the durable source of truth for operator steering: `RunControl`'s
  ETS mailbox is cleared across every pause/resume and is only a cache.
  """
  @spec pending_steering(String.t()) :: [
          %{
            message_id: String.t(),
            text: String.t(),
            resume: boolean(),
            approval_mode_override: String.t() | nil
          }
        ]
  def pending_steering(run_id) when is_binary(run_id) and run_id != "" do
    case run(run_id) do
      nil -> []
      run -> Map.get(run, :pending_steering, [])
    end
  end

  @doc """
  Return the projected state for a jobsite, or nil if not found.
  """
  @spec jobsite(String.t()) :: map() | nil
  def jobsite(jobsite_id) when is_binary(jobsite_id) and jobsite_id != "" do
    GenServer.call(__MODULE__, {:jobsite, jobsite_id})
  end

  @doc """
  Names, versions and last-update times of a project's CURRENTLY SET secrets,
  sorted by name. Never contains a value (events carry none).
  """
  @spec project_secret_names(String.t()) :: [
          %{name: String.t(), version: pos_integer(), updated_at: String.t()}
        ]
  def project_secret_names(project_id) when is_binary(project_id) and project_id != "" do
    GenServer.call(__MODULE__, {:project_secret_names, project_id})
  end

  @doc "Latest event version per secret name (set or unset), `%{}` for none."
  @spec project_secret_versions(String.t()) :: %{String.t() => pos_integer()}
  def project_secret_versions(project_id) when is_binary(project_id) and project_id != "" do
    GenServer.call(__MODULE__, {:project_secret_versions, project_id})
  end

  @doc "Return every projected jobsite, newest-started-first."
  @spec list_jobsites() :: [map()]
  def list_jobsites do
    GenServer.call(__MODULE__, :list_jobsites)
  end

  @doc """
  Return the recorded review for a subject (`"run"` or `"jobsite"` plus its id),
  or nil if no `ReviewRecorded` event has been projected for it.
  """
  @spec review(String.t(), String.t()) :: map() | nil
  def review(subject_kind, subject_id)
      when is_binary(subject_kind) and subject_kind != "" and is_binary(subject_id) and
             subject_id != "" do
    GenServer.call(__MODULE__, {:review, subject_kind, subject_id})
  end

  @typedoc """
  One projected tool-call approval request. `status` is `requested`, `approved`,
  `denied`, `expired` or `finished`; `project_id` is nil only when neither the event
  nor the run/jobsite projection knew it.
  """
  @type tool_call :: %{
          run_id: String.t(),
          tool_call_id: String.t(),
          project_id: String.t() | nil,
          tool_name: String.t(),
          input_summary: String.t() | nil,
          provider: String.t() | nil,
          delivery: String.t() | nil,
          status: String.t(),
          requested_at: String.t(),
          requested_at_ms: integer() | nil,
          decided_at: String.t() | nil,
          decided_by: String.t() | nil,
          reason: String.t() | nil,
          outcome: String.t() | nil
        }

  @approvals_limit 200

  @doc "Maximum approvals returned by one `project_approvals/2` / `run_approvals/2` read."
  @spec approvals_limit() :: pos_integer()
  def approvals_limit, do: @approvals_limit

  @doc """
  A project's tool-call approvals, oldest request first. `status: :pending`
  (default) returns only `requested` calls; `status: :all` includes decided,
  expired and finished ones. Bounded by `:limit` (default and max 200).
  """
  @spec project_approvals(String.t(), keyword()) :: [tool_call()]
  def project_approvals(project_id, opts \\ []) when is_binary(project_id) and is_list(opts),
    do: read_tool_calls({:project, project_id}, opts)

  @doc "A run's (or jobsite's) tool-call approvals; same options as `project_approvals/2`."
  @spec run_approvals(String.t(), keyword()) :: [tool_call()]
  def run_approvals(run_id, opts \\ []) when is_binary(run_id) and is_list(opts),
    do: read_tool_calls({:run, run_id}, opts)

  @doc "The `requested` tool calls of a project, oldest first (the Waiting-on-you source)."
  @spec pending_approvals(String.t()) :: [tool_call()]
  def pending_approvals(project_id), do: project_approvals(project_id)

  @doc "Pending approval counts per run id for a project."
  @spec pending_approvals_by_run(String.t()) :: %{String.t() => pos_integer()}
  def pending_approvals_by_run(project_id) when is_binary(project_id) do
    project_id |> pending_approvals() |> Enum.frequencies_by(& &1.run_id)
  end

  @doc "One tool call, or nil."
  @spec tool_call(String.t(), String.t()) :: tool_call() | nil
  def tool_call(run_id, tool_call_id) when is_binary(run_id) and is_binary(tool_call_id),
    do: GenServer.call(__MODULE__, {:tool_call, run_id, tool_call_id})

  @doc """
  `%{pending: n, expired: n, failed_deliveries: n}` tool-call counts over `run_ids`
  (a thread's runs, or its jobsite id): what `Overview.Signals` reads.
  `failed_deliveries` counts approved calls whose decision never reached the agent.
  """
  @spec approval_counts([String.t()]) :: %{
          pending: non_neg_integer(),
          expired: non_neg_integer(),
          failed_deliveries: non_neg_integer()
        }
  def approval_counts(run_ids) when is_list(run_ids),
    do: GenServer.call(__MODULE__, {:approval_counts, run_ids})

  defp read_tool_calls(scope, opts) do
    statuses =
      case Keyword.get(opts, :status, :pending) do
        :all -> :all
        :pending -> ["requested"]
      end

    limit = opts |> Keyword.get(:limit, @approvals_limit) |> min(@approvals_limit) |> max(1)
    GenServer.call(__MODULE__, {:tool_calls, scope, statuses, limit})
  end

  defp delivery_failed?(%{status: "approved"}), do: true
  defp delivery_failed?(%{status: "finished", outcome: "delivery_failed" <> _}), do: true
  defp delivery_failed?(_call), do: false

  @typedoc """
  One projected operator question. `status` is `open`, `answered` or `expired`.
  The answer text is never projected (it is delivered to the agent and lives only
  in the `QuestionAnswered` event).
  """
  @type question :: %{
          run_id: String.t(),
          question_id: String.t(),
          project_id: String.t() | nil,
          agent_id: String.t() | nil,
          text: String.t() | nil,
          status: String.t(),
          timeout_ms: pos_integer() | nil,
          opened_at: String.t(),
          opened_at_ms: integer() | nil,
          decided_at: String.t() | nil,
          answered_by: String.t() | nil,
          reason: String.t() | nil
        }

  @doc """
  A project's operator questions, oldest first. `status: :pending` (default)
  returns only `open` ones, `status: :all` includes answered and expired.
  Bounded like `project_approvals/2`.
  """
  @spec project_questions(String.t(), keyword()) :: [question()]
  def project_questions(project_id, opts \\ []) when is_binary(project_id) and is_list(opts),
    do: read_questions({:project, project_id}, opts)

  @doc "A run's questions (the id `\"global\"` for unscoped ones); see `project_questions/2`."
  @spec run_questions(String.t(), keyword()) :: [question()]
  def run_questions(run_id, opts \\ []) when is_binary(run_id) and is_list(opts),
    do: read_questions({:run, run_id}, opts)

  @doc "The `open` questions of a project, oldest first (the Waiting-on-you source)."
  @spec open_questions(String.t()) :: [question()]
  def open_questions(project_id), do: project_questions(project_id)

  @doc "Open question counts per run id for a project."
  @spec open_questions_by_run(String.t()) :: %{String.t() => pos_integer()}
  def open_questions_by_run(project_id) when is_binary(project_id) do
    project_id |> open_questions() |> Enum.frequencies_by(& &1.run_id)
  end

  @doc "One question, or nil."
  @spec question(String.t(), String.t()) :: question() | nil
  def question(run_id, question_id) when is_binary(run_id) and is_binary(question_id),
    do: GenServer.call(__MODULE__, {:question, run_id, question_id})

  @doc "`%{open: n, expired: n}` question counts over `run_ids` (what `Overview.Signals` reads)."
  @spec question_counts([String.t()]) :: %{open: non_neg_integer(), expired: non_neg_integer()}
  def question_counts(run_ids) when is_list(run_ids),
    do: GenServer.call(__MODULE__, {:question_counts, run_ids})

  @doc """
  Tool calls whose decision may not have reached the agent: `approved` ones (no
  settling `ToolCallFinished` yet) and `denied` ones. The deliverers' startup
  recovery input; re-delivery is idempotent.
  """
  @spec undelivered_tool_calls() :: [tool_call()]
  def undelivered_tool_calls, do: GenServer.call(__MODULE__, :undelivered_tool_calls)

  @doc "Answered operator questions (the question deliverer's startup recovery input)."
  @spec answered_questions() :: [question()]
  def answered_questions, do: GenServer.call(__MODULE__, :answered_questions)

  @doc """
  Every pending tool call and open question across all projects (unbounded, and
  including ones with no project): the sweeper's input.
  """
  @spec pending_needs_you() :: %{tool_calls: [tool_call()], questions: [question()]}
  def pending_needs_you, do: GenServer.call(__MODULE__, :pending_needs_you)

  @doc """
  The open question with this id in any run, or nil. For the operator-timeout fast
  path, which knows a question id but not the run it was opened under.
  """
  @spec open_question_by_id(String.t()) :: question() | nil
  def open_question_by_id(question_id) when is_binary(question_id),
    do: GenServer.call(__MODULE__, {:open_question_by_id, question_id})

  defp read_questions(scope, opts) do
    statuses =
      case Keyword.get(opts, :status, :pending) do
        :all -> :all
        :pending -> ["open"]
      end

    limit = opts |> Keyword.get(:limit, @approvals_limit) |> min(@approvals_limit) |> max(1)
    GenServer.call(__MODULE__, {:questions, scope, statuses, limit})
  end

  defp question_in_scope?(question, {:project, project_id}), do: question.project_id == project_id
  defp question_in_scope?(question, {:run, run_id}), do: question.run_id == run_id

  defp tool_call_in_scope?(call, {:project, project_id}), do: call.project_id == project_id
  defp tool_call_in_scope?(call, {:run, run_id}), do: call.run_id == run_id

  @doc """
  The adoption record for a subject: the `project.adopt` move that re-homed it
  (`{kind, id}`), or the continuation recorded against it (`{"continue", kind,
  id}`). `nil` when none.
  """
  @spec adoption(tuple()) :: map() | nil
  def adoption(key) when is_tuple(key), do: GenServer.call(__MODULE__, {:adoption, key})

  @doc """
  Audit index of a project's memory topics (`ProjectMemoryWritten` /
  `ProjectMemoryForgotten`), sorted by name. Metadata only; content lives on disk.
  """
  @spec project_memory(String.t()) :: [map()]
  def project_memory(project_id) when is_binary(project_id) and project_id != "" do
    GenServer.call(__MODULE__, {:project_memory, project_id})
  end

  @doc """
  Metadata index of a project's library entries (`ProjectLibraryAdded` /
  `ProjectLibraryReplaced` / `ProjectLibraryRemoved`), sorted by name. Bytes live
  on disk; this is the audit trail and the source of the entry count.
  """
  @spec project_library(String.t()) :: [map()]
  def project_library(project_id) when is_binary(project_id) and project_id != "" do
    GenServer.call(__MODULE__, {:project_library, project_id})
  end

  @doc """
  The full bounded coordinator conversation read model of a project (see
  `ForemanServer.Coordinator.Conversation`); a project that never spoke to its
  coordinator has an empty one. `{:error, :project_not_found}` for an unknown
  project.
  """
  @spec coordinator_state(String.t()) ::
          {:ok, ForemanServer.Coordinator.Conversation.t()} | {:error, :project_not_found}
  def coordinator_state(project_id) when is_binary(project_id) and project_id != "" do
    GenServer.call(__MODULE__, {:coordinator_state, project_id})
  end

  @doc """
  Cursor page of a project's coordinator conversation. Options: `:after` (seq,
  default 0) and `:limit` (1..200, default 50). Returns `%{messages:,
  next_cursor:, has_more:, truncated_before_seq:}`.
  """
  @spec coordinator_conversation(String.t(), keyword()) ::
          {:ok, map()} | {:error, :project_not_found}
  def coordinator_conversation(project_id, opts \\ []) when is_binary(project_id) do
    after_seq = Keyword.get(opts, :after, 0)
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(200)

    with {:ok, conv} <- coordinator_state(project_id) do
      {:ok, ForemanServer.Coordinator.Conversation.page(conv, after_seq, limit)}
    end
  end

  @doc """
  Health of a project's coordinator: `status` (`:idle | :turn_open |
  :unhealthy`), `open_turn`, `consecutive_failures`, `last_error`,
  `pending_messages`, `last_activity_at`.
  """
  @spec coordinator_status(String.t()) :: {:ok, map()} | {:error, :project_not_found}
  def coordinator_status(project_id) when is_binary(project_id) and project_id != "" do
    with {:ok, conv} <- coordinator_state(project_id) do
      alias ForemanServer.Coordinator.Conversation

      {:ok,
       %{
         status: Conversation.status(conv),
         open_turn: conv.open_turn,
         consecutive_failures: conv.consecutive_failures,
         unhealthy_after: conv.unhealthy_after,
         last_error: conv.last_error,
         pending_messages: length(Conversation.pending(conv)),
         last_activity_at: conv.last_activity_at
       }}
    end
  end

  @doc """
  Project ids whose coordinator has an open turn or trigger messages no
  completed turn has consumed (the Runner's catch-up scan).
  """
  @spec coordinator_pending_projects() :: [String.t()]
  def coordinator_pending_projects, do: GenServer.call(__MODULE__, :coordinator_pending_projects)

  @doc "True when a recorded review filed `bead_id` as a gap bead."
  @spec gap_bead?(String.t()) :: boolean()
  def gap_bead?(bead_id) when is_binary(bead_id) and bead_id != "" do
    GenServer.call(__MODULE__, {:gap_bead?, bead_id})
  end

  @typedoc """
  Operator disposition of a thread: `resolved`, when (`resolved_at`, ISO-8601)
  and why, who resolved it, and when it was last reopened (`reopened_at`).
  """
  @type thread_flags :: %{
          resolved: boolean(),
          resolved_at: String.t() | nil,
          reason: String.t() | nil,
          resolved_by: String.t() | nil,
          reopened_at: String.t() | nil
        }

  @doc """
  Return the folded `ThreadResolved`/`ThreadReopened` flags for a thread id, or
  nil when the thread was never resolved or reopened.
  """
  @spec thread_flags(String.t()) :: thread_flags() | nil
  def thread_flags(thread_id) when is_binary(thread_id) and thread_id != "" do
    GenServer.call(__MODULE__, {:thread_flags, thread_id})
  end

  @typedoc """
  Projected schedule. `status` is `"active" | "paused" | "deleted"`;
  `active_since` is unix seconds (creation, last resume or last spec change);
  `last_outcome` is the latest fire or skip. `next_fire_at` is NOT stored: it
  is computed on read from the spec.
  """
  @type schedule :: %{
          schedule_id: String.t(),
          project_id: String.t(),
          name: String.t(),
          spec: %{String.t() => String.t()},
          prompt: String.t(),
          workflow: String.t(),
          auto_approve: boolean() | nil,
          overlap: String.t() | nil,
          misfire_grace_seconds: non_neg_integer() | nil,
          status: String.t(),
          created_at: String.t(),
          active_since: integer() | nil,
          last_slot: integer() | nil,
          last_task_id: String.t() | nil,
          last_outcome:
            %{
              kind: String.t(),
              slot: integer(),
              reason: String.t() | nil,
              missed_count: non_neg_integer() | nil,
              at: String.t()
            }
            | nil
        }

  @doc """
  A project's schedules ordered by name then id. Deleted schedules are excluded
  unless `include_deleted: true`.
  """
  @spec schedules(String.t(), keyword()) :: [schedule()]
  def schedules(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    GenServer.call(
      __MODULE__,
      {:schedules, project_id, Keyword.get(opts, :include_deleted, false)}
    )
  end

  @doc "One schedule (deleted ones included, with `status: \"deleted\"`), or nil."
  @spec schedule(String.t(), String.t()) :: schedule() | nil
  def schedule(project_id, schedule_id) when is_binary(project_id) and is_binary(schedule_id) do
    GenServer.call(__MODULE__, {:schedule, project_id, schedule_id})
  end

  @doc "Every active (not paused, not deleted) schedule across projects, for the ticker."
  @spec all_active_schedules() :: [schedule()]
  def all_active_schedules do
    GenServer.call(__MODULE__, :all_active_schedules)
  end

  @doc """
  Return all events for a run as serializable maps.

  `{:ok, []}` for a run with no stream. `{:error, reason}` on a store failure —
  never an empty list standing in for an error.
  """
  @spec run_events(String.t()) :: {:ok, [map()]} | {:error, term()}
  def run_events(run_id) do
    GenServer.call(__MODULE__, {:run_events, run_id})
  end

  @doc """
  Return per-worker activity for a run, summarized from its
  `worker:<run_id>:<worker_id>` event streams.

  Worker liveness events are appended to those streams, never to
  `run:<run_id>`, so `run_events/1` does not surface them: a live run shows a
  single `RunStarted` event on its run stream while its worker stream grows a
  `WorkerHeartbeat` every few seconds. This read is therefore the only way to
  judge worker liveness without reading the server console.

  `{:ok, []}` for a known run whose workers have emitted nothing yet.
  `{:error, :run_not_found}` for an unknown run — never an empty list standing
  in for an absent run.
  """
  @spec run_activity(String.t()) :: {:ok, [map()]} | {:error, :run_not_found | term()}
  def run_activity(run_id) do
    GenServer.call(__MODULE__, {:run_activity, run_id})
  end

  @doc """
  Return projected durable stdout/stderr for a known run.

  Logs are materialized from `WorkerStdout` / `WorkerStderr` events on
  `worker:<run_id>:<worker_id>` streams. Unknown runs return
  `{:error, :run_not_found}`; known runs with no worker output return a
  successful empty result. The default read is a deterministic latest-500 tail.

  **Absent is not the same as dropped** (AGENTS.md 5.3). A run whose workers
  wrote nothing reads `count: 0, truncated: false, omitted_entries: 0`. A run
  whose output outgrew the resident caps reads `truncated: true` with non-zero
  `omitted_entries`/`omitted_bytes`, so a partial read can never be mistaken
  for a complete one. The events themselves stay in the event store either
  way; this is a bounded read model over them, not the system of record.

  There is no `:log_store_unavailable` / `:log_store_failed` failure: the
  projection is this GenServer's own state, so for a known run the read always
  succeeds. Declaring failures that cannot occur would misdescribe the
  contract.
  """
  @spec run_logs(String.t()) ::
          {:ok,
           %{
             run_id: String.t(),
             entries: [map()],
             count: non_neg_integer(),
             limit: pos_integer(),
             truncated: boolean(),
             omitted_entries: non_neg_integer(),
             omitted_bytes: non_neg_integer(),
             max_limit: pos_integer()
           }}
          | {:error, :run_not_found}
  def run_logs(run_id) do
    GenServer.call(__MODULE__, {:run_logs, run_id})
  end

  @doc "Return the projected state for a phase, or nil if not found."
  @spec phase_projection(String.t()) :: map() | nil
  def phase_projection(phase_id) when is_binary(phase_id) and phase_id != "" do
    GenServer.call(__MODULE__, {:phase_projection, phase_id})
  end

  @doc "Return the ordered phase projections for a run."
  @spec phases_for_run(String.t()) :: [map()]
  def phases_for_run(run_id) when is_binary(run_id) and run_id != "" do
    GenServer.call(__MODULE__, {:phases_for_run, run_id})
  end

  @typedoc """
  Read state of a run's pull request and merge gate (E7-S1), folded from
  `PrAssociated`, `PrReady`, `MergeGatePending/Approved`, `PrUpdated`,
  `PrMerged`, `PrRetargeted` and `PrReset`. `failure_reason` is the run
  projection's `RunFailed` reason. Keys are exactly these.
  """
  @type pr_state_view :: %{
          run_id: String.t(),
          pr_url: String.t() | nil,
          pr_number: non_neg_integer() | nil,
          pr_state: :open | :merged | :closed | :conflicted | nil,
          head_sha: String.t() | nil,
          base_branch: String.t() | nil,
          merge_gate: :none | :pending | :approved,
          merge_gate_at: integer() | nil,
          pr_updated_at: integer() | nil,
          failure_reason: String.t() | nil
        }

  @doc """
  PR / merge-gate read state of one run, or nil when the run is unknown and has
  no PR event. A run with no PR yet reads `pr_state: nil, merge_gate: :none`.
  """
  @spec pr_state(String.t()) :: pr_state_view() | nil
  def pr_state(run_id) when is_binary(run_id) and run_id != "" do
    GenServer.call(__MODULE__, {:pr_state, run_id})
  end

  @doc """
  `pr_state/1` for every run of a project, keyed by run id. One GenServer call;
  O(runs).
  """
  @spec pr_states_for_project(String.t()) :: %{String.t() => pr_state_view()}
  def pr_states_for_project(project_id) when is_binary(project_id) and project_id != "" do
    GenServer.call(__MODULE__, {:pr_states_for_project, project_id})
  end

  @doc "Return the PR association for a run_id, or :not_found."
  @spec pr_association(String.t()) :: {:ok, map()} | {:error, :not_found}
  def pr_association(run_id) when is_binary(run_id) do
    GenServer.call(__MODULE__, {:pr_association, run_id})
  end

  @doc """
  Return the ids of every run whose recorded PR association is `pr_url`, sorted.

  More than one run can be associated with one PR (a retried run that reuses it),
  so this answers with a list; `[]` means no run owns that PR.
  """
  @spec run_ids_for_pr_url(String.t()) :: [String.t()]
  def run_ids_for_pr_url(pr_url) when is_binary(pr_url) and pr_url != "" do
    GenServer.call(__MODULE__, {:run_ids_for_pr_url, pr_url})
  end

  @doc """
  The watched PRs of one run, ordered by `pr_url` (E9). Each record is the fold
  of `ForemanServer.PrWatchFold` (status, head SHA, checks state and digest,
  review decision and digest, fix bookkeeping, `watching`) plus `agent_review`:
  the run's `ReviewRecorded` verdict as another PR signal (`nil` until the
  review ran). `[]` for a run with no observed PR.
  """
  @spec pr_watch(String.t()) :: [map()]
  def pr_watch(run_id) when is_binary(run_id) and run_id != "" do
    GenServer.call(__MODULE__, {:pr_watch, run_id})
  end

  @doc """
  Every PR that should be polled: `watching` and neither merged nor closed.
  One record per `{run_id, pr_url}`, oldest observation first (records never
  observed sort first), so a per-tick cap rotates through the set.
  """
  @spec watched_prs() :: [map()]
  def watched_prs do
    GenServer.call(__MODULE__, :watched_prs)
  end

  @doc "Return the projected state for a project, or nil if not found."
  @spec project_projection(String.t()) :: map() | nil
  def project_projection(project_id) when is_binary(project_id) do
    GenServer.call(__MODULE__, {:project_projection, project_id})
  end

  @doc """
  Typed settings of a project (`nil` only when the project is unknown). Reads
  accept both key conventions found in persisted config (atom live, string
  after replay).
  """
  @spec project_settings(String.t()) :: ForemanServer.ProjectSettings.t() | nil
  def project_settings(project_id) when is_binary(project_id) do
    case project_projection(project_id) do
      nil -> nil
      project -> ForemanServer.ProjectSettings.from_config(Map.get(project, :config))
    end
  end

  @doc """
  Ids of the project's tasks that were dispatched (`TaskDispatched` -> status
  `"in_progress"`, run id assigned) but whose run never started: run admission
  refused them (project paused, daily cap, run limit) or they wait for a slot.
  `Workflow.Dispatcher` re-admits these when the project resumes or its limits
  change.
  """
  @spec deferred_task_ids(String.t()) :: [String.t()]
  def deferred_task_ids(project_id) when is_binary(project_id) do
    GenServer.call(__MODULE__, {:deferred_task_ids, project_id})
  end

  @doc """
  Typed limits and usage of a project (`ForemanServer.ProjectLimits`), or `nil`
  for an unknown project. Rejections of admissions (cap, pause) are retried, so
  `deferred_tasks` shows the waiting backlog.
  """
  @spec project_limits(String.t(), DateTime.t()) :: ForemanServer.ProjectLimits.t() | nil
  def project_limits(project_id, now \\ DateTime.utc_now()) when is_binary(project_id) do
    GenServer.call(__MODULE__, {:project_limits, project_id, now})
  end

  @doc """
  Usage rollup of a project (`ForemanServer.Usage.Rollup`) over the UTC days
  `opts[:from]..opts[:to]` (inclusive ISO dates, both optional), or `nil` for an
  unknown project. A known project without usage returns an empty rollup.
  """
  @spec usage(String.t(), keyword()) :: ForemanServer.Usage.Rollup.t() | nil
  def usage(project_id, opts \\ []) when is_binary(project_id) do
    GenServer.call(__MODULE__, {:usage, project_id, opts[:from], opts[:to]})
  end

  @doc "Return every projected project."
  @spec list_projects() :: [map()]
  def list_projects do
    GenServer.call(__MODULE__, :list_projects)
  end

  @doc "Return projects with reserved active run ids for reconciler enumeration only."
  @spec list_projects_with_active_runs() :: [{String.t(), [String.t()]}]
  def list_projects_with_active_runs do
    GenServer.call(__MODULE__, :list_projects_with_active_runs)
  end

  @doc "Return every projected run, optionally filtered by status, project_id, and limit."
  @spec list_runs(keyword()) :: [map()]
  def list_runs(opts \\ []) when is_list(opts) do
    GenServer.call(__MODULE__, {:list_runs, opts})
  end

  @doc """
  Return every projection the thread read model composes, in one call:
  `%{runs, tasks, jobsites, worktrees, pr_associations, reviews}`. `reviews` is
  keyed by `{subject_kind, subject_id}`, `pr_associations` by run id. Exists so
  `Threads.list/2` never makes a GenServer call per row.
  """
  @spec thread_inputs() :: %{
          runs: [map()],
          tasks: [map()],
          jobsites: [map()],
          worktrees: [map()],
          pr_associations: %{String.t() => map()},
          reviews: %{{String.t(), String.t()} => map()},
          thread_flags: %{String.t() => thread_flags()}
        }
  def thread_inputs do
    GenServer.call(__MODULE__, :thread_inputs)
  end

  @doc "Return every projected scheduler intent."
  @spec list_scheduler_intents() :: [map()]
  def list_scheduler_intents do
    GenServer.call(__MODULE__, :list_scheduler_intents)
  end

  @doc "Return the current run-slot queue status: capacity, running run ids, and waiting run ids in FIFO order."
  @spec queue_status() :: %{
          capacity: non_neg_integer(),
          running: [String.t()],
          waiting: [String.t()]
        }
  def queue_status do
    GenServer.call(__MODULE__, :queue_status)
  end

  @doc "Return the inbox thread for a run_id, or nil if not found."
  @spec inbox_thread(String.t()) :: map() | nil
  def inbox_thread(run_id) when is_binary(run_id) and run_id != "" do
    GenServer.call(__MODULE__, {:inbox_thread, run_id})
  end

  @doc "Return every inbox thread."
  @spec list_inbox_threads() :: [map()]
  def list_inbox_threads do
    GenServer.call(__MODULE__, :list_inbox_threads)
  end

  @doc """
  Return the projected worktree for an `operation_id` (the deterministic
  correlation id `"wt-<run_id>-<phase_id>"`), or nil if not found.
  """
  @spec worktree(String.t()) :: map() | nil
  def worktree(operation_id) when is_binary(operation_id) do
    GenServer.call(__MODULE__, {:worktree, operation_id})
  end

  @doc """
  Return every projected worktree for a given run, sorted by operation_id.
  """
  @spec worktrees_for_run(String.t()) :: [map()]
  def worktrees_for_run(run_id) when is_binary(run_id) do
    GenServer.call(__MODULE__, {:worktrees_for_run, run_id})
  end

  @doc """
  Return the projected worktree for a given `(project_id, run_id, phase_id)`
  tuple, or nil if not found. Mirrors the deterministic `operation_id`
  derivation used by the worktree aggregate.
  """
  @spec worktree_for_phase(String.t(), String.t(), String.t()) :: map() | nil
  def worktree_for_phase(project_id, run_id, phase_id)
      when is_binary(project_id) and is_binary(run_id) and is_binary(phase_id) do
    operation_id = "wt-" <> run_id <> "-" <> phase_id
    GenServer.call(__MODULE__, {:worktree, operation_id})
  end

  @doc """
  Return every projected worktree whose final status is `"created"` —
  i.e. a `WorktreeCreated` event was replayed but no matching
  `WorktreeCleaned` event followed. BootReconciliation uses this
  list to drive cleanup of orphans after a restart.
  """
  @spec list_unresolved_worktrees() :: [map()]
  def list_unresolved_worktrees do
    GenServer.call(__MODULE__, :list_unresolved_worktrees)
  end

  @doc """
  Return the projected worktree create orphan for an `operation_id`, or
  nil if not found. BootReconciliation surfaces these for operator
  recovery when in-process compensation failed.
  """
  @spec worktree_create_orphan(String.t()) :: map() | nil
  def worktree_create_orphan(operation_id) when is_binary(operation_id) do
    GenServer.call(__MODULE__, {:worktree_create_orphan, operation_id})
  end

  @doc """
  Return every projected worktree create orphan, sorted by operation_id.
  Used by `BootReconciliation` to surface durables whose create
  compensation failed.
  """
  @spec list_worktree_create_orphans() :: [map()]
  def list_worktree_create_orphans do
    GenServer.call(__MODULE__, :list_worktree_create_orphans)
  end

  # -------------------------------------------------------------------------

  @impl true
  def init(init_arg) do
    {:ok, rebuild_from_event_log(init_now_ms_fun(init_arg))}
  end

  @impl true
  def handle_call({:project, project_id}, _from, state) do
    {:reply, Map.get(state.projects, project_id), state}
  end

  @impl true
  def handle_call({:run, run_id}, _from, state) do
    {:reply, Map.get(state.runs, run_id), state}
  end

  @impl true
  def handle_call({:project_secret_names, project_id}, _from, state) do
    names =
      state.project_secrets
      |> Map.get(project_id, %{})
      |> Enum.filter(fn {_name, entry} -> entry.set? end)
      |> Enum.map(fn {name, entry} ->
        %{name: name, version: entry.version, updated_at: entry.updated_at}
      end)
      |> Enum.sort_by(& &1.name)

    {:reply, names, state}
  end

  def handle_call({:project_secret_versions, project_id}, _from, state) do
    versions =
      state.project_secrets
      |> Map.get(project_id, %{})
      |> Map.new(fn {name, entry} -> {name, entry.version} end)

    {:reply, versions, state}
  end

  def handle_call({:jobsite, jobsite_id}, _from, state) do
    {:reply, Map.get(state.jobsites, jobsite_id), state}
  end

  @impl true
  def handle_call({:project_library, project_id}, _from, state) do
    entries =
      state.project_library
      |> Map.get(project_id, %{})
      |> Map.values()
      |> Enum.sort_by(& &1.name)

    {:reply, entries, state}
  end

  @impl true
  def handle_call({:project_memory, project_id}, _from, state) do
    entries =
      state.project_memory
      |> Map.get(project_id, %{})
      |> Map.values()
      |> Enum.sort_by(& &1.name)

    {:reply, entries, state}
  end

  @impl true
  def handle_call({:coordinator_state, project_id}, _from, state) do
    reply =
      if Map.has_key?(state.projects, project_id) do
        {:ok,
         state
         |> Map.get(:coordinators, %{})
         |> Map.get(project_id, ForemanServer.Coordinator.Conversation.new())}
      else
        {:error, :project_not_found}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:coordinator_pending_projects, _from, state) do
    alias ForemanServer.Coordinator.Conversation

    ids =
      state
      |> Map.get(:coordinators, %{})
      |> Enum.filter(fn {project_id, conv} ->
        Map.has_key?(state.projects, project_id) and
          (conv.open_turn != nil or Conversation.pending(conv) != [])
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    {:reply, ids, state}
  end

  @impl true
  def handle_call({:review, subject_kind, subject_id}, _from, state) do
    {:reply, Map.get(state.reviews, {subject_kind, subject_id}), state}
  end

  @impl true
  def handle_call({:adoption, key}, _from, state) do
    {:reply, Map.get(state.adoptions, key), state}
  end

  @impl true
  def handle_call({:schedules, project_id, include_deleted?}, _from, state) do
    list =
      for {{^project_id, _id}, schedule} <- state.schedules,
          include_deleted? or schedule.status != "deleted",
          do: schedule

    {:reply, Enum.sort_by(list, &{&1.name, &1.schedule_id}), state}
  end

  @impl true
  def handle_call({:tool_calls, scope, statuses, limit}, _from, state) do
    calls =
      state.tool_calls
      |> Map.values()
      |> Enum.filter(&tool_call_in_scope?(&1, scope))
      |> Enum.filter(&(statuses == :all or &1.status in statuses))
      |> Enum.sort_by(&{&1.requested_at_ms || 0, &1.tool_call_id})
      |> Enum.take(limit)

    {:reply, calls, state}
  end

  @impl true
  def handle_call({:tool_call, run_id, tool_call_id}, _from, state) do
    {:reply, Map.get(state.tool_calls, {run_id, tool_call_id}), state}
  end

  @impl true
  def handle_call({:approval_counts, run_ids}, _from, state) do
    counts =
      Enum.reduce(
        state.tool_calls,
        %{pending: 0, expired: 0, failed_deliveries: 0},
        fn {{run_id, _}, call}, acc ->
          cond do
            run_id not in run_ids -> acc
            call.status == "requested" -> Map.update!(acc, :pending, &(&1 + 1))
            call.status == "expired" -> Map.update!(acc, :expired, &(&1 + 1))
            delivery_failed?(call) -> Map.update!(acc, :failed_deliveries, &(&1 + 1))
            true -> acc
          end
        end
      )

    {:reply, counts, state}
  end

  @impl true
  def handle_call({:questions, scope, statuses, limit}, _from, state) do
    questions =
      state.questions
      |> Map.values()
      |> Enum.filter(&question_in_scope?(&1, scope))
      |> Enum.filter(&(statuses == :all or &1.status in statuses))
      |> Enum.sort_by(&{&1.opened_at_ms || 0, &1.question_id})
      |> Enum.take(limit)

    {:reply, questions, state}
  end

  @impl true
  def handle_call({:question, run_id, question_id}, _from, state) do
    {:reply, Map.get(state.questions, {run_id, question_id}), state}
  end

  @impl true
  def handle_call({:open_question_by_id, question_id}, _from, state) do
    open =
      Enum.find_value(state.questions, fn
        {{_run_id, ^question_id}, %{status: "open"} = question} -> question
        _other -> nil
      end)

    {:reply, open, state}
  end

  @impl true
  def handle_call(:undelivered_tool_calls, _from, state) do
    calls =
      state.tool_calls |> Map.values() |> Enum.filter(&(&1.status in ["approved", "denied"]))

    {:reply, calls, state}
  end

  @impl true
  def handle_call(:answered_questions, _from, state) do
    {:reply, state.questions |> Map.values() |> Enum.filter(&(&1.status == "answered")), state}
  end

  @impl true
  def handle_call(:pending_needs_you, _from, state) do
    reply = %{
      tool_calls: state.tool_calls |> Map.values() |> Enum.filter(&(&1.status == "requested")),
      questions: state.questions |> Map.values() |> Enum.filter(&(&1.status == "open"))
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:question_counts, run_ids}, _from, state) do
    counts =
      Enum.reduce(state.questions, %{open: 0, expired: 0}, fn {{run_id, _}, question}, acc ->
        cond do
          run_id not in run_ids -> acc
          question.status == "open" -> Map.update!(acc, :open, &(&1 + 1))
          question.status == "expired" -> Map.update!(acc, :expired, &(&1 + 1))
          true -> acc
        end
      end)

    {:reply, counts, state}
  end

  @impl true
  def handle_call({:schedule, project_id, schedule_id}, _from, state) do
    {:reply, Map.get(state.schedules, {project_id, schedule_id}), state}
  end

  @impl true
  def handle_call(:all_active_schedules, _from, state) do
    active =
      state.schedules
      |> Map.values()
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.sort_by(&{&1.project_id, &1.schedule_id})

    {:reply, active, state}
  end

  @impl true
  def handle_call({:thread_flags, thread_id}, _from, state) do
    {:reply, Map.get(state.thread_flags, thread_id), state}
  end

  @impl true
  def handle_call({:gap_bead?, bead_id}, _from, state) do
    found? =
      Enum.any?(state.reviews, fn {_key, review} ->
        bead_id in (Map.get(review, :gap_bead_ids) || [])
      end)

    {:reply, found?, state}
  end

  @impl true
  def handle_call(:list_jobsites, _from, state) do
    jobsites =
      state.jobsites
      |> Map.values()
      |> Enum.sort_by(fn jobsite -> get(jobsite, :started_at_ms, 0) end, :desc)

    {:reply, jobsites, state}
  end

  @impl true
  def handle_call({:run_events, run_id}, _from, state) do
    # `%EventStore.RecordedEvent{}` has no Jason.Encoder, so returning the
    # structs raised Protocol.UndefinedError as soon as a run actually had
    # events — the tool only ever looked correct because its test covered the
    # empty case. Project each event onto a serializable map.
    reply =
      case EventStore.read_stream_forward("run:#{run_id}", 0, 99_999_999) do
        {:ok, events} -> {:ok, Enum.map(events, &recorded_event_to_map/1)}
        {:error, :stream_not_found} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:run_activity, run_id}, _from, state) do
    reply =
      case Map.get(state.runs, run_id) do
        nil -> {:error, :run_not_found}
        _run -> worker_activity_for_run(run_id)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:run_logs, run_id}, _from, state) do
    reply =
      case Map.get(state.runs, run_id) do
        nil -> {:error, :run_not_found}
        _run -> run_logs_result(state, run_id)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:active_runs, _from, state) do
    {:reply, active_run_ids(state), state}
  end

  @impl true
  def handle_call({:stuck_runs, threshold_ms, now_ms_fun}, _from, state) do
    now_ms = now_ms_fun.()

    reply =
      state
      |> active_run_ids()
      |> Enum.filter(fn run_id ->
        case Map.get(state.runs, run_id) do
          %{last_event_at_ms: last_event_at_ms} when is_integer(last_event_at_ms) ->
            last_event_at_ms + threshold_ms <= now_ms

          _ ->
            false
        end
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:stall_candidates, now_ms_fun}, _from, state) do
    now_ms = now_ms_fun.()
    {:reply, stall_candidates_from_state(state, now_ms), state}
  end

  @impl true
  def handle_call({:apply_events, events, now_ms_fun}, _from, state) do
    new_state =
      Enum.reduce(events, state, fn event, acc -> apply_event(acc, event, now_ms_fun) end)

    new_state = broadcast_events(new_state, events)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:rebuild, recovered_events, now_ms_fun}, _from, state) do
    case rebuild_state_from_event_log(now_ms_fun) do
      {:ok, rebuilt_state} ->
        new_state =
          rebuilt_state
          |> Map.put(:subscribers, state.subscribers)
          |> broadcast_events(recovered_events)

        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(
        {:rebuild_project, project_id, recovered_events, now_ms_fun},
        _from,
        state
      ) do
    case rebuild_project_state(project_id, now_ms_fun) do
      {:ok, rebuilt_project_state} ->
        projects =
          replace_project_entry(
            state.projects,
            rebuilt_project_state.projects,
            project_id
          )

        project_active_runs =
          replace_project_entry(
            state.project_active_runs,
            rebuilt_project_state.project_active_runs,
            project_id
          )

        usage_ledgers =
          replace_project_entry(
            Map.get(state, :usage, %{}),
            Map.get(rebuilt_project_state, :usage, %{}),
            project_id
          )

        project_thread_days =
          replace_project_entry(
            Map.get(state, :project_thread_days, %{}),
            Map.get(rebuilt_project_state, :project_thread_days, %{}),
            project_id
          )

        project_deferrals =
          replace_project_entry(
            Map.get(state, :project_deferrals, %{}),
            Map.get(rebuilt_project_state, :project_deferrals, %{}),
            project_id
          )

        new_state =
          state
          |> Map.put(:projects, projects)
          |> Map.put(:project_active_runs, project_active_runs)
          |> Map.put(:project_thread_days, project_thread_days)
          |> Map.put(:project_deferrals, project_deferrals)
          |> Map.put(:usage, usage_ledgers)
          |> broadcast_events(recovered_events)

        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:subscribe, opts}, {pid, _ref}, state) do
    {ref, subscribers, newly_monitored?} =
      case Map.fetch(state.subscribers, pid) do
        {:ok, existing_ref} ->
          {existing_ref, state.subscribers, false}

        :error ->
          ref = Process.monitor(pid)
          {ref, Map.put(state.subscribers, pid, ref), true}
      end

    Process.put(:projection_subscribers, subscribers)
    state = %{state | subscribers: subscribers}

    if Keyword.get(opts, :replay_existing, false) do
      case EventStore.read_all_streams_forward(0, 99_999_999) do
        {:ok, events} ->
          replay_events(pid, events)
          {:reply, :ok, state}

        {:error, reason} ->
          if newly_monitored? do
            Process.demonitor(ref, [:flush])
            remaining = Map.delete(subscribers, pid)
            Process.put(:projection_subscribers, remaining)
            {:reply, {:error, reason}, %{state | subscribers: remaining}}
          else
            {:reply, {:error, reason}, state}
          end
      end
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:queue_status, _from, state) do
    %{capacity: capacity, holders: holders, waiters: waiters} = state.run_slots

    reply = %{
      capacity: capacity,
      running: Map.keys(holders),
      waiting: Enum.map(waiters, & &1.run_id)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:thread_inputs, _from, state) do
    inputs = %{
      runs: Map.values(state.runs),
      tasks: Map.values(state.tasks),
      jobsites: Map.values(state.jobsites),
      worktrees: state.worktrees |> Map.values() |> Enum.sort_by(&get(&1, :operation_id, "")),
      pr_associations: state.pr_associations,
      reviews: state.reviews,
      thread_flags: state.thread_flags
    }

    {:reply, inputs, state}
  end

  @impl true
  def handle_call(:list_scheduler_intents, _from, state) do
    {:reply, Map.values(state.scheduler_intents), state}
  end

  @impl true
  def handle_call({:pr_state, run_id}, _from, state) do
    run = Map.get(state.runs, run_id)
    entry = Map.get(state.pr_states, run_id)

    view = if run || entry, do: pr_state_view(run_id, run, entry)
    {:reply, view, state}
  end

  @impl true
  def handle_call({:pr_states_for_project, project_id}, _from, state) do
    views =
      for {run_id, %{project_id: ^project_id} = run} <- state.runs, into: %{} do
        {run_id, pr_state_view(run_id, run, Map.get(state.pr_states, run_id))}
      end

    {:reply, views, state}
  end

  @impl true
  def handle_call({:pr_association, run_id}, _from, state) do
    case Map.get(state.pr_associations, run_id) do
      nil -> {:reply, {:error, :not_found}, state}
      assoc -> {:reply, {:ok, assoc}, state}
    end
  end

  @impl true
  def handle_call({:run_ids_for_pr_url, pr_url}, _from, state) do
    run_ids =
      for {run_id, %{pr_url: ^pr_url}} <- state.pr_associations, do: run_id

    {:reply, Enum.sort(run_ids), state}
  end

  @impl true
  def handle_call({:pr_watch, run_id}, _from, state) do
    {:reply, pr_watch_view(state, run_id), state}
  end

  @impl true
  def handle_call(:watched_prs, _from, state) do
    pr_watch = Map.get(state, :pr_watch, %{})

    observed =
      for {run_id, _records} <- pr_watch,
          record <- pr_watch_view(state, run_id),
          record.watching and record.status not in ["merged", "closed"],
          do: record

    # A PR the run is associated with but nothing observed yet (no PrUpdated) is
    # watched too, as a blank record, so the poller's first sweep finds it.
    unobserved =
      for {run_id, %{pr_url: pr_url}} <- state.pr_associations,
          is_binary(pr_url),
          not Map.has_key?(Map.get(pr_watch, run_id, %{}), pr_url),
          do: unobserved_record(state, run_id, pr_url)

    watched = observed ++ unobserved
    {:reply, Enum.sort_by(watched, &{&1.updated_at || 0, &1.run_id, &1.pr_url}), state}
  end

  @impl true
  def handle_call({:inbox_thread, run_id}, _from, state) do
    {:reply, Map.get(state.inbox_threads, run_id), state}
  end

  @impl true
  def handle_call(:list_inbox_threads, _from, state) do
    {:reply, Map.values(state.inbox_threads), state}
  end

  @impl true
  def handle_call({:deferred_task_ids, project_id}, _from, state) do
    {:reply, deferred_task_ids(state, project_id), state}
  end

  @impl true
  def handle_call({:usage, project_id, from, to}, _from, state) do
    reply =
      if Map.has_key?(state.projects, project_id) do
        state
        |> Map.get(:usage, %{})
        |> Map.get(project_id, UsageLedger.new())
        |> UsageLedger.rollup(from, to)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:project_limits, project_id, now}, _from, state) do
    reply =
      case Map.get(state.projects, project_id) do
        nil ->
          nil

        project ->
          day = ForemanServer.ProjectLimits.day(now)

          threads_today =
            state
            |> Map.get(:project_thread_days, %{})
            |> Map.get(project_id, %{})
            |> Map.get(day, MapSet.new())
            |> MapSet.size()

          deferred = state |> deferred_task_ids(project_id) |> length()

          deferred_by_reason =
            state
            |> Map.get(:project_deferrals, %{})
            |> Map.get(project_id, %{})
            |> Map.get(day, %{})
            |> Map.new(fn {reason, task_ids} -> {reason, MapSet.size(task_ids)} end)

          ForemanServer.ProjectLimits.build(
            project,
            %{
              active_runs:
                state |> Map.get(:project_active_runs, %{}) |> Map.get(project_id, []) |> length(),
              threads_started_today: threads_today,
              deferred_tasks: deferred,
              deferred_by_reason: deferred_by_reason
            },
            now
          )
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:threads_started_on, project_id, day}, _from, state) do
    count =
      state
      |> Map.get(:project_thread_days, %{})
      |> Map.get(project_id, %{})
      |> Map.get(day, MapSet.new())
      |> MapSet.size()

    {:reply, count, state}
  end

  @impl true
  def handle_call({:project_projection, project_id}, _from, state) do
    {:reply, Map.get(state.projects, project_id), state}
  end

  @impl true
  def handle_call(:list_projects, _from, state) do
    {:reply, Map.values(state.projects), state}
  end

  @impl true
  def handle_call(:list_projects_with_active_runs, _from, state) do
    reply =
      state
      |> Map.get(:project_active_runs, %{})
      |> Enum.reduce([], fn
        {project_id, run_ids}, acc when is_binary(project_id) and run_ids != [] ->
          [{project_id, Enum.sort(run_ids)} | acc]

        _, acc ->
          acc
      end)
      |> Enum.sort_by(fn {project_id, _run_ids} -> project_id end)

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:list_runs, opts}, _from, state) do
    runs =
      state.runs
      |> Map.values()
      |> filter_runs(opts)
      |> Enum.sort_by(
        fn run -> {get(run, :last_event_at_ms, 0), get(run, :run_id, "")} end,
        :desc
      )
      |> limit_runs(Keyword.get(opts, :limit))

    {:reply, runs, state}
  end

  @impl true
  def handle_call({:get_task_by_external_id, external_id}, _from, state) do
    task =
      Enum.find_value(state.tasks, fn {_task_id, task} ->
        if get(task, :external_id) == external_id, do: task, else: nil
      end)

    {:reply, task, state}
  end

  @impl true
  def handle_call({:task_projection, task_id}, _from, state) do
    {:reply, Map.get(state.tasks, task_id), state}
  end

  @impl true
  def handle_call({:tasks_by_run_id, run_id}, _from, state) do
    tasks =
      state.tasks
      |> Map.values()
      |> Enum.filter(fn task ->
        get(task, :run_id) == run_id and
          get(task, :acknowledged_run_id) != run_id
      end)
      |> Enum.sort_by(fn task -> get(task, :task_id, "") end)

    {:reply, tasks, state}
  end

  @impl true
  def handle_call(:list_tasks, _from, state) do
    tasks =
      state.tasks
      |> Map.values()
      |> Enum.sort_by(fn task -> get(task, :task_id, "") end)

    {:reply, tasks, state}
  end

  @impl true
  def handle_call({:phase_projection, phase_id}, _from, state) do
    {:reply, Map.get(state.phases, phase_id), state}
  end

  @impl true
  def handle_call({:phases_for_run, run_id}, _from, state) do
    phases =
      state.phases
      |> Map.values()
      |> Enum.filter(fn phase -> get(phase, :run_id) == run_id end)
      |> Enum.sort_by(fn phase -> get(phase, :index, 0) end)

    {:reply, phases, state}
  end

  @impl true
  def handle_call({:worktree, operation_id}, _from, state) do
    {:reply, Map.get(state.worktrees, operation_id), state}
  end

  @impl true
  def handle_call({:worktrees_for_run, run_id}, _from, state) do
    worktrees =
      state.worktrees
      |> Map.values()
      |> Enum.filter(fn wt -> get(wt, :run_id) == run_id end)
      |> Enum.sort_by(fn wt -> get(wt, :operation_id, "") end)

    {:reply, worktrees, state}
  end

  @impl true
  def handle_call(:list_unresolved_worktrees, _from, state) do
    unresolved =
      state.worktrees
      |> Map.values()
      |> Enum.filter(fn wt -> get(wt, :status) == "created" end)
      |> Enum.sort_by(fn wt -> get(wt, :operation_id, "") end)

    {:reply, unresolved, state}
  end

  @impl true
  def handle_call({:worktree_create_orphan, operation_id}, _from, state) do
    {:reply, Map.get(state.worktree_create_orphans, operation_id), state}
  end

  @impl true
  def handle_call(:list_worktree_create_orphans, _from, state) do
    orphans =
      state.worktree_create_orphans
      |> Map.values()
      |> Enum.sort_by(fn wt -> get(wt, :operation_id, "") end)

    {:reply, orphans, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  defp broadcast_events(state, events) do
    for event <- events,
        pid <- Map.keys(state.subscribers) do
      send(pid, {:projection_event, event})
    end

    state
  end

  defp replay_events(pid, events) do
    Enum.each(events, fn event -> send(pid, {:projection_event, event}) end)
  end

  # -------------------------------------------------------------------------
  # Projection logic
  # -------------------------------------------------------------------------

  defp rebuild_from_event_log(now_ms_fun) when is_function(now_ms_fun, 0) do
    case rebuild_state_from_event_log(now_ms_fun) do
      {:ok, rebuilt_state} -> rebuilt_state
      {:error, _reason} -> initial_state()
    end
  end

  defp rebuild_state_from_event_log(now_ms_fun) when is_function(now_ms_fun, 0) do
    case EventStore.read_all_streams_forward(0, 99_999_999) do
      {:ok, events} ->
        {:ok,
         Enum.reduce(events, initial_state(), fn event, acc ->
           apply_event(acc, event, now_ms_fun)
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rebuild_project_state(project_id, now_ms_fun)
       when is_binary(project_id) and is_function(now_ms_fun, 0) do
    case EventStore.read_stream_forward("project:#{project_id}", 0, 99_999_999) do
      {:ok, events} ->
        {:ok,
         Enum.reduce(events, initial_state(), fn event, acc ->
           apply_event(acc, event, now_ms_fun)
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_project_entry(current, rebuilt, project_id) do
    case Map.fetch(rebuilt, project_id) do
      {:ok, value} -> Map.put(current, project_id, value)
      :error -> Map.delete(current, project_id)
    end
  end

  @doc false
  @spec initial_state() :: map()
  def initial_state do
    %{
      projects: %{},
      runs: %{},
      tasks: %{},
      phases: %{},
      pr_associations: %{},
      pr_states: %{},
      pr_watch: %{},
      run_logs: %{},
      scheduler_intents: %{},
      subscribers: %{},
      project_active_runs: %{},
      project_thread_days: %{},
      project_deferrals: %{},
      usage: %{},
      worktrees: %{},
      worktree_create_orphans: %{},
      run_slots: %{capacity: 0, holders: %{}, waiters: []},
      inbox_threads: %{},
      jobsites: %{},
      adoptions: %{},
      reviews: %{},
      project_memory: %{},
      project_library: %{},
      project_secrets: %{},
      thread_flags: %{},
      schedules: %{},
      tool_calls: %{},
      questions: %{},
      coordinators: %{}
    }
  end

  defp apply_event(state, %RecordedEvent{} = recorded, now_ms_fun) do
    payload =
      recorded.data
      |> to_payload_map()
      |> with_recorded_projection_metadata(recorded, now_ms_fun)

    apply_event_by_type(state, recorded.event_type, payload)
  end

  defp apply_event(state, %EventData{} = event_data, now_ms_fun) do
    payload =
      event_data.data
      |> to_payload_map()
      |> with_event_at_ms(now_ms_fun.())

    apply_event_by_type(state, event_data.event_type, payload)
  end

  defp apply_event(state, %{event_type: type, payload: payload}, now_ms_fun) do
    apply_event_by_type(
      state,
      type,
      payload |> to_payload_map() |> with_event_at_ms(now_ms_fun.())
    )
  end

  defp apply_event(state, event, now_ms_fun) when is_map(event) do
    type = Map.get(event, :event_type) || Map.get(event, "event_type")

    payload =
      Map.get(event, :data) ||
        Map.get(event, "data") ||
        Map.get(event, :payload) ||
        Map.get(event, "payload") ||
        event

    apply_event_by_type(
      state,
      type,
      payload |> to_payload_map() |> with_event_at_ms(now_ms_fun.())
    )
  end

  defp apply_event_by_type(state, "ProjectRegistered", payload) do
    project_id = get(payload, :project_id)
    path = get(payload, :path)

    if valid_id?(project_id) do
      put_state(
        state,
        Map.put(state.projects, project_id, project_projection(payload, path)),
        state.runs
      )
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectUpdated", payload) do
    project_id = get(payload, :project_id)

    if valid_id?(project_id) do
      project =
        state.projects
        |> Map.get(project_id, project_projection(payload, nil))
        |> maybe_put(:path, get(payload, :path))
        |> maybe_put(:status, get(payload, :status))
        |> maybe_put(:health, get(payload, :health))
        |> maybe_put(:name, get(payload, :name))
        |> maybe_put(:task_provider, get(payload, :task_provider))
        |> put_project_config(get(payload, :config, %{}))
        |> put_project_settings(payload)
        |> put_project_projection_metadata(payload)

      put_state(state, Map.put(state.projects, project_id, project), state.runs)
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectArchived", payload) do
    project_id = get(payload, :project_id)

    if valid_id?(project_id) do
      project =
        state.projects
        |> Map.get(project_id, %{status: "archived", archived?: true})
        |> Map.put(:status, "archived")
        |> Map.put(:archived?, true)
        |> put_project_projection_metadata(payload)

      put_state(state, Map.put(state.projects, project_id, project), state.runs)
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectReactivated", payload) do
    project_id = get(payload, :project_id)

    if valid_id?(project_id) do
      project =
        state.projects
        |> Map.get(project_id, %{status: "active", archived?: false})
        |> Map.put(:status, "active")
        |> Map.put(:archived?, false)
        |> put_project_projection_metadata(payload)

      put_state(state, Map.put(state.projects, project_id, project), state.runs)
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectPaused", payload),
    do: set_project_status(state, payload, "paused")

  defp apply_event_by_type(state, "ProjectResumed", payload),
    do: set_project_status(state, payload, "active")

  defp apply_event_by_type(state, "ProjectRunReserved", payload) do
    project_id = get(payload, :project_id)
    run_id = get(payload, :run_id)

    if valid_id?(project_id) and valid_id?(run_id) do
      active_runs =
        state
        |> Map.get(:project_active_runs, %{})
        |> Map.update(project_id, [run_id], &add_project_run_id(&1, run_id))

      state
      |> Map.put(:project_active_runs, active_runs)
      |> count_project_thread(project_id, "run", run_id, get(payload, :reserved_on))
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectThreadStarted", payload) do
    project_id = get(payload, :project_id)
    thread_id = get(payload, :thread_id)
    kind = get(payload, :thread_kind)

    if valid_id?(project_id) and valid_id?(thread_id) and is_binary(kind) do
      count_project_thread(state, project_id, kind, thread_id, get(payload, :day))
    else
      state
    end
  end

  # Admission refusals are retried, so they are counted per project/day/reason
  # as distinct tasks (a MapSet: replaying the event cannot inflate the count).
  defp apply_event_by_type(state, "ProjectAdmissionDeferred", payload) do
    project_id = get(payload, :project_id)
    task_id = get(payload, :task_id)
    reason = get(payload, :reason)
    day = get(payload, :day)

    if valid_id?(project_id) and valid_id?(task_id) and is_binary(reason) and is_binary(day) do
      all = Map.get(state, :project_deferrals, %{})

      per_day =
        all
        |> Map.get(project_id, %{})
        |> Map.update(day, %{reason => MapSet.new([task_id])}, fn by_reason ->
          Map.update(by_reason, reason, MapSet.new([task_id]), &MapSet.put(&1, task_id))
        end)
        |> retain_recent_days()

      Map.put(state, :project_deferrals, Map.put(all, project_id, per_day))
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectRunReservationReleased", payload) do
    project_id = get(payload, :project_id)
    run_id = get(payload, :run_id)

    if valid_id?(project_id) and valid_id?(run_id) do
      active_runs =
        state
        |> Map.get(:project_active_runs, %{})
        |> remove_project_run_id(project_id, run_id)

      Map.put(state, :project_active_runs, active_runs)
    else
      state
    end
  end

  # `project.adopt` re-homes a session by rewriting `project_id` on its
  # projected task(s), run(s) and jobsite; the original events keep their
  # `project_id` (history is immutable). Malformed payloads are skipped: this
  # fold also runs on every rebuild from the event log.
  defp apply_event_by_type(state, "ProjectSubjectAdopted", payload) do
    target = get(payload, :project_id)
    kind = get(payload, :subject_kind)
    id = get(payload, :subject_id)
    mode = get(payload, :mode)

    if valid_id?(target) and kind in ["task", "run", "jobsite"] and valid_id?(id) and
         mode in ["move", "continue"] do
      adopt_subject(state, mode, kind, id, target, payload)
    else
      state
    end
  end

  defp apply_event_by_type(state, "NotificationEnqueued", payload) do
    case decode_for_projection("NotificationEnqueued", payload) do
      %ForemanServer.Events.NotificationEnqueued{run_id: run_id} = event
      when is_binary(run_id) and run_id != "" ->
        project_notification_enqueued(state, payload, event)

      _ ->
        state
    end
  end

  defp apply_event_by_type(state, "NotificationSuppressed", payload) do
    case decode_for_projection("NotificationSuppressed", payload) do
      %ForemanServer.Events.NotificationSuppressed{run_id: run_id} = event
      when is_binary(run_id) and run_id != "" ->
        project_notification_outcome(state, payload, event, "suppressed", %{
          reason: event.reason
        })

      _ ->
        state
    end
  end

  defp apply_event_by_type(state, "NotificationDeliveryAttempted", payload) do
    case decode_for_projection("NotificationDeliveryAttempted", payload) do
      %ForemanServer.Events.NotificationDeliveryAttempted{run_id: run_id} = event
      when is_binary(run_id) and run_id != "" ->
        project_notification_outcome(state, payload, event, "attempted", %{})

      _ ->
        state
    end
  end

  defp apply_event_by_type(state, "NotificationDeliverySucceeded", payload) do
    case decode_for_projection("NotificationDeliverySucceeded", payload) do
      %ForemanServer.Events.NotificationDeliverySucceeded{run_id: run_id} = event
      when is_binary(run_id) and run_id != "" ->
        project_notification_outcome(state, payload, event, "succeeded", %{
          delivered_at: event.delivered_at
        })

      _ ->
        state
    end
  end

  defp apply_event_by_type(state, "NotificationDeliveryFailed", payload) do
    case decode_for_projection("NotificationDeliveryFailed", payload) do
      %ForemanServer.Events.NotificationDeliveryFailed{run_id: run_id} = event
      when is_binary(run_id) and run_id != "" ->
        project_notification_outcome(state, payload, event, "failed", %{
          reason: event.reason,
          retryable?: event.retryable?
        })

      _ ->
        state
    end
  end

  defp apply_event_by_type(state, "RunStarted", payload) do
    case decode_for_projection("RunStarted", payload) do
      %ForemanServer.Events.RunStarted{run_id: run_id} = event ->
        if valid_id?(run_id) do
          event_at_ms = payload_event_at_ms(payload)

          run = %{
            run_id: run_id,
            task_id: event.task_id,
            project_id: event.project_id,
            workflow_name: event.workflow_name,
            workflow_digest: event.workflow_digest,
            workflow_snapshot: event.workflow_snapshot,
            phase_ids: [],
            last_sequence: event.sequence,
            status: "awaiting_worker",
            terminal?: false,
            started_at_ms: event_at_ms,
            last_event_at_ms: event_at_ms,
            failure_reason: nil,
            pr_url: nil,
            phase_prs: [],
            notifications: [],
            provider_session_id: nil,
            provider_sessions: [],
            usage: nil
          }

          put_state(state, state.projects, Map.put(state.runs, run_id, run))
        else
          state
        end
    end
  end

  defp apply_event_by_type(state, "RunUpdated", payload) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      maybe_put(run, :task_id, get(payload, :task_id))
    end)
  end

  defp apply_event_by_type(state, "RunCompleted", payload) do
    apply_terminal_run_event(state, payload, "completed")
  end

  defp apply_event_by_type(state, "RunFailed", payload) do
    apply_terminal_run_event(state, payload, "failed")
  end

  defp apply_event_by_type(state, "RunBlocked", payload) do
    apply_terminal_run_event(state, payload, "blocked")
  end

  defp apply_event_by_type(state, "RunDeleted", payload) do
    apply_terminal_run_event(state, payload, "deleted")
  end

  defp apply_event_by_type(state, "RunReset", payload) do
    run_id = get(payload, :run_id)

    if valid_id?(run_id) do
      project_id = get(payload, :project_id)

      state
      |> Map.update(:project_active_runs, %{}, fn active_runs ->
        if valid_id?(project_id) do
          remove_project_run_id(active_runs, project_id, run_id)
        else
          active_runs
        end
      end)
      |> put_state(state.projects, Map.delete(state.runs, run_id))
    else
      state
    end
  end

  defp apply_event_by_type(state, "RunFlaggedStuck", payload) do
    apply_terminal_run_event(state, payload, "stuck")
  end

  defp apply_event_by_type(state, "RunStallReported", payload) do
    stall = latest_stall_from_payload(payload)
    run_id = get(payload, :run_id)
    phase_id = get(payload, :phase_id)
    task_id = get(payload, :task_id)
    status_effect = get(payload, :status_effect)

    state
    |> update_run_projection(run_id, payload_event_at_ms(payload), fn run ->
      run
      |> Map.put(:latest_stall, stall)
      |> maybe_put_status_effect(status_effect, stall.reason)
    end)
    |> Map.update!(:phases, fn phases ->
      Map.update(phases, phase_id, %{latest_stall: stall}, fn phase ->
        Map.put(phase, :latest_stall, stall)
      end)
    end)
    |> update_task_latest_stall(task_id, stall)
  end

  defp apply_event_by_type(state, "RunCancelled", payload) do
    apply_terminal_run_event(state, payload, "cancelled")
  end

  defp apply_event_by_type(state, "RunPaused", payload) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      Map.put(run, :status, "paused")
    end)
  end

  defp apply_event_by_type(state, "RunResumed", payload) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      run
      |> Map.put(:status, "awaiting_worker")
      |> Map.put(:terminal?, false)
    end)
  end

  # E6-S4 steering mailbox: pending steering is RunSteerQueued minus
  # RunSteerConsumed, in queue order. This projection field is the durable
  # source `RunControl`'s ETS mailbox is rebuilt from.
  defp apply_event_by_type(state, "RunSteerQueued", payload) do
    message_id = get(payload, :message_id)

    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      pending = Map.get(run, :pending_steering, [])

      if is_binary(message_id) and message_id != "" and
           not Enum.any?(pending, &(&1.message_id == message_id)) do
        entry = %{
          message_id: message_id,
          text: get(payload, :text),
          resume: get(payload, :resume) != false,
          approval_mode_override: get(payload, :approval_mode_override)
        }

        Map.put(run, :pending_steering, pending ++ [entry])
      else
        run
      end
    end)
  end

  defp apply_event_by_type(state, "RunSteerConsumed", payload) do
    consumed = MapSet.new(List.wrap(get(payload, :message_ids)))

    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      Map.update(run, :pending_steering, [], fn pending ->
        Enum.reject(pending, &MapSet.member?(consumed, &1.message_id))
      end)
    end)
  end

  defp apply_event_by_type(state, "RunBaseBranchRecorded", payload) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      maybe_put(run, :base_branch, get(payload, :base_branch))
    end)
  end

  defp apply_event_by_type(state, "PhaseStarted", payload) do
    case decode_for_projection("PhaseStarted", payload) do
      %ForemanServer.Events.PhaseStarted{phase_id: phase_id, run_id: run_id} = event
      when not is_nil(phase_id) and phase_id != "" and not is_nil(run_id) and run_id != "" ->
        phase = %{
          phase_id: phase_id,
          run_id: run_id,
          index: event.index,
          name: event.name,
          attempt: event.attempt,
          status: "in_progress",
          artifact_template: event.artifact_template,
          artifact: nil,
          failure_reason: nil,
          last_sequence: event.sequence,
          started_at_ms: payload_event_at_ms(payload),
          last_event_at_ms: payload_event_at_ms(payload),
          output_activity_at_ms: payload_event_at_ms(payload),
          messaging_activity_at_ms: payload_event_at_ms(payload),
          stall_detection_kind: event.stall_detection_kind,
          stall_threshold_ms: event.stall_threshold_ms,
          stall_policy: event.stall_policy,
          latest_stall: nil
        }

        state
        |> touch_run_for_payload(payload)
        |> Map.update!(:phases, &Map.put(&1, phase_id, phase))
        |> append_phase_id_to_run(run_id, phase_id)

      _ ->
        touch_run_for_payload(state, payload)
    end
  end

  defp apply_event_by_type(state, "PhaseCompleted", payload) do
    case decode_for_projection("PhaseCompleted", payload) do
      %ForemanServer.Events.PhaseCompleted{phase_id: phase_id} = event
      when not is_nil(phase_id) and phase_id != "" ->
        phase =
          state.phases
          |> Map.get(phase_id, %{})
          |> Map.put(:status, "completed")
          |> Map.put(:artifact, %{
            path: event.artifact_path,
            sha256: event.artifact_sha256,
            bytes: event.artifact_bytes
          })
          |> Map.put(:last_sequence, event.sequence)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))
          |> Map.put(:output_activity_at_ms, payload_event_at_ms(payload))

        state
        |> touch_run_for_payload(payload)
        |> Map.update!(:phases, &Map.put(&1, phase_id, phase))

      _ ->
        touch_run_for_payload(state, payload)
    end
  end

  defp apply_event_by_type(state, "PhaseFailed", payload) do
    case decode_for_projection("PhaseFailed", payload) do
      %ForemanServer.Events.PhaseFailed{phase_id: phase_id} = event
      when not is_nil(phase_id) and phase_id != "" ->
        phase =
          state.phases
          |> Map.get(phase_id, %{})
          |> Map.put(:status, "failed")
          |> Map.put(:failure_reason, event.reason)
          |> Map.put(:last_sequence, event.sequence)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))
          |> Map.put(:output_activity_at_ms, payload_event_at_ms(payload))

        state
        |> touch_run_for_payload(payload)
        |> Map.update!(:phases, &Map.put(&1, phase_id, phase))

      _ ->
        touch_run_for_payload(state, payload)
    end
  end

  defp apply_event_by_type(state, "PhaseTimedOut", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, "PhaseRetried", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, "TaskCreated", payload) do
    case decode_for_projection("TaskCreated", payload) do
      %ForemanServer.Events.TaskCreated{task_id: task_id} = event ->
        task = %{
          task_id: task_id,
          external_id: event.external_id,
          project_id: event.project_id,
          title: event.title,
          description: event.description,
          priority: event.priority,
          status: event.status,
          task_type: event.task_type,
          workflow_type: event.workflow_type,
          trd_path: event.trd_path,
          prompt: event.prompt,
          # Carried because `CommandGateway` gates `task.approve` on it. Until
          # this line existed the field was accepted by `task.create`, stored on
          # the aggregate, and written onto `TaskCreated` — then dropped here, so
          # no cross-task reader could see it and dependencies had no effect on
          # anything.
          #
          # `event.dependencies || []` was wrong and is exactly the shape
          # AGENTS.md §5.4b names: `false || []` returns `[]` just as `nil || []`
          # does, so a malformed value arrived here as "no dependencies" and the
          # approval guard waved it through. Verified before fixing — a
          # `task.create` carrying `dependencies: false` returned `{:ok, ...}`,
          # the event stored `false`, and this projection reported `[]`.
          # `task.create` now refuses a non-list, but historical events keep
          # theirs, so the malformed value is PRESERVED here rather than
          # flattened; the guard refuses that approval by its own clause. A read
          # model must not raise on replay (`ProjectionStore.init/1` rebuilds
          # from the event log), and must not launder bad data either.
          dependencies: normalize_dependencies(event.dependencies),
          provider_tracked: event.provider_tracked,
          approval_id: nil,
          approved_by: nil,
          approved_at: nil,
          run_id: nil,
          workflow_snapshot: nil,
          failure_reason: nil,
          created_at_ms: payload_event_at_ms(payload),
          last_event_at_ms: payload_event_at_ms(payload)
        }

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "TaskUpdated", payload) do
    case decode_for_projection("TaskUpdated", payload) do
      %ForemanServer.Events.TaskUpdated{task_id: task_id} = event ->
        task =
          state.tasks
          |> Map.get(task_id, %{})
          |> maybe_put(:status, event.status)
          |> maybe_put(:priority, event.priority)
          |> maybe_put(:title, event.title)
          |> maybe_put(:description, event.description)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "TaskApproved", payload) do
    case decode_for_projection("TaskApproved", payload) do
      %ForemanServer.Events.TaskApproved{task_id: task_id} = event ->
        task =
          state.tasks
          |> Map.get(task_id, %{})
          |> Map.put(:status, "ready")
          |> Map.put(:approval_id, event.approval_id)
          |> Map.put(:approved_by, event.approved_by)
          |> Map.put(:approved_at, event.approved_at)
          |> Map.put(:run_id, event.run_id)
          |> Map.put(:workflow_snapshot, event.workflow_snapshot)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "TaskDispatched", payload) do
    case decode_for_projection("TaskDispatched", payload) do
      %ForemanServer.Events.TaskDispatched{task_id: task_id} ->
        task =
          state.tasks
          |> Map.get(task_id, %{})
          |> Map.put(:status, "in_progress")
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "TaskExecutionCompleted", payload) do
    case decode_for_projection("TaskExecutionCompleted", payload) do
      %ForemanServer.Events.TaskExecutionCompleted{task_id: task_id} ->
        task =
          state.tasks
          |> Map.get(task_id, %{})
          |> Map.put(:status, "closed")
          |> Map.put(:failure_reason, nil)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "TaskExecutionFailed", payload) do
    case decode_for_projection("TaskExecutionFailed", payload) do
      %ForemanServer.Events.TaskExecutionFailed{task_id: task_id} = event ->
        task =
          state.tasks
          |> Map.get(task_id, %{})
          |> Map.put(:status, "failed")
          |> Map.put(:failure_reason, event.reason)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "TaskRunTerminated", payload) do
    case decode_for_projection("TaskRunTerminated", payload) do
      %ForemanServer.Events.TaskRunTerminated{task_id: task_id, run_id: run_id} = event ->
        task =
          state.tasks
          |> Map.get(task_id, %{})
          |> Map.put(:acknowledged_run_id, run_id)
          |> Map.put(:run_terminal_reason, event.reason)
          |> Map.put(:run_terminal_at, event.acknowledged_at)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "TaskRetried", payload) do
    case decode_for_projection("TaskRetried", payload) do
      %ForemanServer.Events.TaskRetried{task_id: task_id} ->
        task =
          state.tasks
          |> Map.get(task_id, %{})
          |> Map.put(:status, "open")
          |> Map.put(:approval_id, nil)
          |> Map.put(:approved_by, nil)
          |> Map.put(:approved_at, nil)
          |> Map.put(:run_id, nil)
          |> Map.put(:workflow_snapshot, nil)
          |> Map.put(:acknowledged_run_id, nil)
          |> Map.put(:failure_reason, nil)
          |> Map.put(:run_terminal_reason, nil)
          |> Map.put(:run_terminal_at, nil)
          |> Map.put(:last_event_at_ms, payload_event_at_ms(payload))

        %{state | tasks: Map.put(state.tasks, task_id, task)}
    end
  end

  defp apply_event_by_type(state, "WorkerStarted", payload) do
    state
    |> update_run_projection(get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      case run do
        %{status: "awaiting_worker"} -> %{run | status: "in_progress"}
        run -> run
      end
    end)
    |> touch_active_phase_activity(get(payload, :run_id), :output, payload_event_at_ms(payload))
  end

  # Binds the provider's session id to the run. The fold is idempotent: a
  # replayed event (same worker, provider, session) leaves one entry, and
  # `provider_session_id` is always the latest bound value.
  #
  # An undecodable payload leaves the projection untouched rather than raising:
  # this runs inside `rebuild_state_from_event_log/1` from `init/1`, where a
  # raise would take the whole application down at boot.
  defp apply_event_by_type(state, "WorkerSessionBound", payload) do
    case decode_or_skip("WorkerSessionBound", payload) do
      {:ok, %WorkerSessionBound{} = event} ->
        entry = %{
          worker_id: event.worker_id,
          provider: event.provider,
          model: event.model,
          provider_session_id: event.provider_session_id
        }

        update_run_projection(state, event.run_id, payload_event_at_ms(payload), fn run ->
          sessions =
            run
            |> Map.get(:provider_sessions, [])
            |> Enum.reject(&(&1 == entry))
            |> Kernel.++([entry])

          run
          |> Map.put(:provider_sessions, sessions)
          |> Map.put(:provider_session_id, event.provider_session_id)
        end)

      :error ->
        state
    end
  end

  # Cumulative usage for the run. Each worker's usage is stored on
  # `workers[worker_id].usage` (replaced, so replaying one worker's event is
  # idempotent) and `run.usage` is the nil-preserving sum over all workers.
  # `nil` until the first event, so historical runs read as "unknown", not 0.
  defp apply_event_by_type(state, "UsageRecorded", payload) do
    case decode_or_skip("UsageRecorded", payload) do
      {:ok, %UsageRecorded{} = event} ->
        usage = Usage.from_fields(Map.from_struct(event))

        state
        |> update_run_projection(event.run_id, payload_event_at_ms(payload), fn run ->
          workers =
            run
            |> Map.get(:workers, %{})
            |> Map.update(event.worker_id, %{usage: usage}, &Map.put(&1, :usage, usage))

          total =
            workers
            |> Map.values()
            |> Enum.map(&Map.get(&1, :usage))
            |> Enum.reject(&is_nil/1)
            |> Enum.reduce(nil, &Usage.merge(&2, &1))

          run
          |> Map.put(:workers, workers)
          |> Map.put(:usage, total)
        end)
        |> record_worker_usage(event, usage, payload)

      :error ->
        state
    end
  end

  defp apply_event_by_type(state, "WorkerHeartbeat", payload) do
    touch_run_for_payload(state, payload)
  end

  defp apply_event_by_type(state, "WorkerExited", payload) do
    state
    |> touch_run_for_payload(payload)
    |> touch_active_phase_activity(get(payload, :run_id), :output, payload_event_at_ms(payload))
  end

  defp apply_event_by_type(state, "WorkerStdout", payload) do
    project_worker_log(state, decode_for_projection("WorkerStdout", payload), payload, "stdout")
  end

  defp apply_event_by_type(state, "WorkerStderr", payload) do
    project_worker_log(state, decode_for_projection("WorkerStderr", payload), payload, "stderr")
  end

  defp apply_event_by_type(state, "WorkerUnresponsive", payload) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      worker_id = get(payload, :worker_id)
      sequence = get(payload, :sequence)

      workers =
        Map.update(
          Map.get(run, :workers, %{}),
          worker_id,
          %{status: "unresponsive", sequence: sequence},
          &Map.merge(&1, %{status: "unresponsive", sequence: sequence})
        )

      run
      |> Map.put(:status, "needs_recovery")
      |> Map.put(:needs_recovery, true)
      |> Map.put(:workers, workers)
    end)
  end

  defp apply_event_by_type(state, "WorkerRecoveryRequired", payload) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      Map.put(run, :recovery_observation_at_ms, payload_event_at_ms(payload))
    end)
  end

  # `PrAssociated` lands on BOTH the association map and the run projection.
  # It previously wrote only the association map, so `run/1` — and therefore
  # `GET /api/runs/:id` and `GET /api/runs` — carried no PR field at all: the
  # run that opened https://github.com/ldangelo/foreman/pull/420 read exactly
  # like a run that opened nothing.
  defp apply_event_by_type(state, "PrAssociated", payload) do
    case decode_for_projection("PrAssociated", payload) do
      %ForemanServer.Events.PrAssociated{run_id: run_id, pr_url: pr_url} = event
      when is_binary(run_id) and run_id != "" and is_binary(pr_url) and pr_url != "" ->
        association = %{
          run_id: run_id,
          pr_url: pr_url,
          pr_number: event.pr_number,
          associated_at: event.associated_at
        }

        state
        |> update_run_projection(run_id, payload_event_at_ms(payload), fn run ->
          Map.put(run, :pr_url, pr_url)
        end)
        |> Map.update!(:pr_associations, &Map.put(&1, run_id, association))
        |> fold_pr_state("PrAssociated", payload)

      # AGENTS.md 5.3: a blank run_id or pr_url is malformed, not absent.
      # Projecting it would leave `pr_url: nil` on the run, indistinguishable
      # from "this run opened no PR". `PrAssociation.handle_command/2` rejects
      # both on the write path, so reaching here means the aggregate was
      # bypassed.
      %ForemanServer.Events.PrAssociated{} = event ->
        raise ArgumentError,
              "ProjectionStore: PrAssociated with unusable run_id/pr_url: #{inspect(event)}"
    end
  end

  defp apply_event_by_type(state, "PhasePrRecorded", payload) do
    case decode_for_projection("PhasePrRecorded", payload) do
      %ForemanServer.Events.PhasePrRecorded{} = event ->
        record = %{
          run_id: event.run_id,
          phase_id: event.phase_id,
          phase_index: event.phase_index,
          phase_name: event.phase_name,
          status: event.status,
          pr_url: event.pr_url,
          pr_number: event.pr_number,
          base_branch: event.base_branch,
          head_branch: event.head_branch,
          provider: event.provider,
          reason: event.reason,
          recorded_at: event.recorded_at
        }

        validate_phase_pr_record!(record)

        state
        |> update_run_projection(event.run_id, payload_event_at_ms(payload), fn run ->
          phase_prs =
            run
            |> Map.get(:phase_prs, [])
            |> upsert_phase_pr(record)

          Map.put(run, :phase_prs, phase_prs)
        end)
        |> Map.update!(:phases, fn phases ->
          Map.update(phases, event.phase_id, %{phase_prs: [record]}, fn phase ->
            Map.put(phase, :phase_prs, upsert_phase_pr(Map.get(phase, :phase_prs, []), record))
          end)
        end)
    end
  end

  defp apply_event_by_type(state, "ScheduledFireRecorded", payload) do
    intent_id = get(payload, :intent_id)

    if valid_id?(intent_id) do
      intent = %{
        intent_id: intent_id,
        status: "recorded",
        schedule_id: get(payload, :schedule_id),
        project_id: get(payload, :project_id),
        slot: get(payload, :slot),
        recorded_at: payload_event_at_ms(payload),
        run_id: get(payload, :run_id),
        task_id: get(payload, :task_id),
        scheduled_at: get(payload, :scheduled_at),
        scheduled_for: get(payload, :scheduled_for),
        payload: get(payload, :payload, %{})
      }

      put_state(state, state.projects, state.runs)
      |> Map.put(:scheduler_intents, Map.put(state.scheduler_intents, intent_id, intent))
    else
      state
    end
  end

  defp apply_event_by_type(state, "ScheduledFireConfirmed", payload) do
    update_intent(state, payload, "confirmed")
  end

  defp apply_event_by_type(state, "ScheduledFireSkipped", payload) do
    update_intent(state, payload, "skipped")
  end

  defp apply_event_by_type(state, "SchedulerIntentStale", payload) do
    update_intent(state, payload, "stale")
  end

  defp apply_event_by_type(state, "AssistantMessage", payload) do
    state
    |> touch_run_for_payload(payload)
    |> touch_active_phase_activity(get(payload, :run_id), :output, payload_event_at_ms(payload))
  end

  # E8 operator-question folds (same tolerance as the tool-call folds below).
  defp apply_event_by_type(state, "QuestionOpened", payload) do
    case decode_or_skip("QuestionOpened", payload) do
      {:ok, %ForemanServer.Events.QuestionOpened{run_id: run_id, question_id: id} = e}
      when is_binary(run_id) and run_id != "" and is_binary(id) and id != "" ->
        entry = %{
          run_id: run_id,
          question_id: id,
          project_id: e.project_id || subject_project_id(state, run_id),
          agent_id: e.agent_id,
          text: e.text,
          status: "open",
          timeout_ms: e.timeout_ms,
          opened_at: e.at,
          opened_at_ms: iso_to_ms(e.at),
          decided_at: nil,
          answered_by: nil,
          reason: nil
        }

        %{state | questions: Map.put_new(state.questions, {run_id, id}, entry)}

      _ ->
        Logger.warning("ProjectionStore skipped malformed QuestionOpened")
        state
    end
  end

  defp apply_event_by_type(state, "QuestionAnswered", payload) do
    case decode_or_skip("QuestionAnswered", payload) do
      {:ok, %ForemanServer.Events.QuestionAnswered{} = e} ->
        update_question(state, e.run_id, e.question_id, fn question ->
          %{question | status: "answered", decided_at: e.at, answered_by: e.answered_by}
        end)

      _ ->
        Logger.warning("ProjectionStore skipped malformed QuestionAnswered")
        state
    end
  end

  defp apply_event_by_type(state, "QuestionExpired", payload) do
    case decode_or_skip("QuestionExpired", payload) do
      {:ok, %ForemanServer.Events.QuestionExpired{} = e} ->
        update_question(state, e.run_id, e.question_id, fn question ->
          %{question | status: "expired", decided_at: e.at, reason: e.reason}
        end)

      _ ->
        Logger.warning("ProjectionStore skipped malformed QuestionExpired")
        state
    end
  end

  # E8 tool-call folds. A decision event for an unknown call is ignored (never
  # raised) so `init/1`'s event-log rebuild survives partial or reordered history.
  defp apply_event_by_type(state, "ToolCallRequested", payload) do
    case decode_or_skip("ToolCallRequested", payload) do
      {:ok, %ForemanServer.Events.ToolCallRequested{run_id: run_id, tool_call_id: id} = e}
      when is_binary(run_id) and run_id != "" and is_binary(id) and id != "" ->
        entry = %{
          run_id: run_id,
          tool_call_id: id,
          project_id: e.project_id || subject_project_id(state, run_id),
          tool_name: e.tool_name,
          input_summary: e.input_summary,
          provider: e.provider,
          delivery: e.delivery,
          status: "requested",
          requested_at: e.requested_at,
          requested_at_ms: iso_to_ms(e.requested_at),
          decided_at: nil,
          decided_by: nil,
          reason: nil,
          outcome: nil
        }

        %{state | tool_calls: Map.put_new(state.tool_calls, {run_id, id}, entry)}

      _ ->
        Logger.warning("ProjectionStore skipped malformed ToolCallRequested")
        state
    end
  end

  defp apply_event_by_type(state, "ToolCallApproved", payload),
    do: decide_tool_call(state, "ToolCallApproved", payload, "approved")

  defp apply_event_by_type(state, "ToolCallDenied", payload),
    do: decide_tool_call(state, "ToolCallDenied", payload, "denied")

  defp apply_event_by_type(state, "ToolCallExpired", payload) do
    case decode_or_skip("ToolCallExpired", payload) do
      {:ok, %ForemanServer.Events.ToolCallExpired{} = e} ->
        update_tool_call(state, e.run_id, e.tool_call_id, fn call ->
          %{call | status: "expired", decided_at: e.at, reason: e.reason}
        end)

      _ ->
        Logger.warning("ProjectionStore skipped malformed ToolCallExpired")
        state
    end
  end

  # Worker-emitted `ToolCallFinished` events carry no `tool_call_id`; only the
  # approvals path (`tool.finish`) does, and only that one settles a call.
  defp apply_event_by_type(state, "ToolCallFinished", payload) do
    state =
      case get(payload, :tool_call_id) do
        id when is_binary(id) and id != "" ->
          update_tool_call(state, get(payload, :run_id), id, fn call ->
            %{call | status: "finished", outcome: get(payload, :outcome)}
          end)

        _ ->
          state
      end

    state
    |> touch_run_for_payload(payload)
    |> touch_active_phase_activity(get(payload, :run_id), :output, payload_event_at_ms(payload))
  end

  defp apply_event_by_type(state, "WorktreeCreated", payload) do
    case decode_for_projection("WorktreeCreated", payload) do
      %ForemanServer.Events.WorktreeCreated{} = event
      when not is_nil(event.operation_id) and event.operation_id != "" ->
        entry = %{
          operation_id: event.operation_id,
          project_id: event.project_id,
          run_id: event.run_id,
          phase_id: event.phase_id,
          status: "created",
          repo_path: event.repo_path,
          worktree_path: event.worktree_path,
          branch: event.branch,
          base_ref: event.base_ref,
          cleanup: event.cleanup,
          last_event_at_ms: payload_event_at_ms(payload)
        }

        state
        |> Map.update!(:worktrees, &Map.put(&1, event.operation_id, entry))
        |> touch_run_for_payload(payload)

      _ ->
        touch_run_for_payload(state, payload)
    end
  end

  defp apply_event_by_type(state, "WorktreeCleaned", payload) do
    case decode_for_projection("WorktreeCleaned", payload) do
      %ForemanServer.Events.WorktreeCleaned{} = event
      when not is_nil(event.operation_id) and event.operation_id != "" ->
        existing = Map.get(state.worktrees, event.operation_id, %{})

        merged =
          Map.merge(existing, %{
            operation_id: event.operation_id,
            project_id: event.project_id || existing[:project_id],
            run_id: event.run_id || existing[:run_id],
            phase_id: event.phase_id || existing[:phase_id],
            status: "cleaned",
            repo_path: event.repo_path || existing[:repo_path],
            worktree_path: event.worktree_path || existing[:worktree_path],
            cleanup_observed: event.cleanup_observed,
            last_event_at_ms: payload_event_at_ms(payload)
          })

        state
        |> Map.update!(:worktrees, &Map.put(&1, event.operation_id, merged))
        |> touch_run_for_payload(payload)

      _ ->
        touch_run_for_payload(state, payload)
    end
  end

  defp apply_event_by_type(state, "WorktreeCreateOrphanRecorded", payload) do
    case decode_for_projection("WorktreeCreateOrphanRecorded", payload) do
      %ForemanServer.Events.WorktreeCreateOrphanRecorded{} = event
      when not is_nil(event.operation_id) and event.operation_id != "" ->
        entry = %{
          operation_id: event.operation_id,
          project_id: event.project_id,
          run_id: event.run_id,
          phase_id: event.phase_id,
          worktree_path: event.worktree_path,
          repo_path: event.repo_path,
          reason: event.reason,
          last_event_at_ms: payload_event_at_ms(payload)
        }

        state
        |> Map.update!(:worktree_create_orphans, &Map.put(&1, event.operation_id, entry))
        |> touch_run_for_payload(payload)

      _ ->
        touch_run_for_payload(state, payload)
    end
  end

  defp apply_event_by_type(state, "WorktreeCreateOrphanResolved", payload) do
    case decode_for_projection("WorktreeCreateOrphanResolved", payload) do
      %ForemanServer.Events.WorktreeCreateOrphanResolved{} = event
      when not is_nil(event.operation_id) and event.operation_id != "" ->
        state
        |> Map.update!(:worktree_create_orphans, &Map.delete(&1, event.operation_id))
        |> touch_run_for_payload(payload)

      _ ->
        touch_run_for_payload(state, payload)
    end
  end

  # -------------------------------------------------------------------------
  # InboxThread events — folded into state.inbox_threads
  # -------------------------------------------------------------------------

  defp apply_event_by_type(state, "InboxMessageAppended", payload) do
    run_id = get(payload, :run_id)

    if valid_id?(run_id) do
      thread =
        state.inbox_threads
        |> Map.get(run_id, %{run_id: run_id, messages: []})
        |> Map.update!(:messages, fn msgs ->
          msg = %{
            message_id: get(payload, :message_id),
            body: get(payload, :body),
            delivery_status: nil,
            metadata:
              Map.drop(payload, [:run_id, :message_id, :body, "run_id", "message_id", "body"]),
            event_at_ms: payload_event_at_ms(payload)
          }

          msgs ++ [msg]
        end)

      state
      |> Map.put(:inbox_threads, Map.put(state.inbox_threads, run_id, thread))
      |> touch_active_phase_activity(run_id, :messaging, payload_event_at_ms(payload))
    else
      state
    end
  end

  defp apply_event_by_type(state, "InboxDeliveryUpdated", payload) do
    run_id = get(payload, :run_id)
    message_id = get(payload, :message_id)

    if valid_id?(run_id) and valid_id?(message_id) do
      case Map.get(state.inbox_threads, run_id) do
        nil ->
          state

        thread ->
          updated_messages =
            Enum.map(thread.messages, fn msg ->
              if msg.message_id == message_id do
                Map.put(msg, :delivery_status, get(payload, :delivery_status))
              else
                msg
              end
            end)

          updated_thread = %{thread | messages: updated_messages}
          %{state | inbox_threads: Map.put(state.inbox_threads, run_id, updated_thread)}
      end
    else
      state
    end
  end

  # -------------------------------------------------------------------------
  # RunSlot events — folded into state.run_slots
  # -------------------------------------------------------------------------

  defp apply_event_by_type(state, "RunSlotAcquired", payload) do
    run_id = get(payload, :run_id)
    capacity = get(payload, :capacity)

    if valid_id?(run_id) do
      Map.update!(state, :run_slots, fn slots ->
        %{slots | capacity: capacity, holders: Map.put(slots.holders, run_id, :held)}
      end)
    else
      state
    end
  end

  defp apply_event_by_type(state, "RunSlotQueued", payload) do
    run_id = get(payload, :run_id)
    position = get(payload, :position)
    enqueued_at_ms = get(payload, :enqueued_at_ms)

    if valid_id?(run_id) do
      Map.update!(state, :run_slots, fn slots ->
        waiter = %{run_id: run_id, position: position, enqueued_at_ms: enqueued_at_ms}
        %{slots | waiters: slots.waiters ++ [waiter]}
      end)
    else
      state
    end
  end

  defp apply_event_by_type(state, "RunSlotReleased", payload) do
    run_id = get(payload, :run_id)

    if valid_id?(run_id) do
      Map.update!(state, :run_slots, fn slots ->
        %{slots | holders: Map.delete(slots.holders, run_id)}
      end)
    else
      state
    end
  end

  defp apply_event_by_type(state, "RunSlotTransferred", payload) do
    released_run_id = get(payload, :released_run_id)
    acquired_run_id = get(payload, :acquired_run_id)

    if valid_id?(released_run_id) and valid_id?(acquired_run_id) do
      Map.update!(state, :run_slots, fn slots ->
        new_holders =
          slots.holders
          |> Map.delete(released_run_id)
          |> Map.put(acquired_run_id, :held)

        # Remove the promoted waiter
        new_waiters = Enum.reject(slots.waiters, &(&1.run_id == acquired_run_id))

        %{slots | holders: new_holders, waiters: new_waiters}
      end)
    else
      state
    end
  end

  defp apply_event_by_type(state, "RunSlotWaiterRemoved", payload) do
    run_id = get(payload, :run_id)

    if valid_id?(run_id) do
      Map.update!(state, :run_slots, fn slots ->
        %{slots | waiters: Enum.reject(slots.waiters, &(&1.run_id == run_id))}
      end)
    else
      state
    end
  end

  defp apply_event_by_type(state, "ProjectSecretSet", payload),
    do: put_project_secret(state, "ProjectSecretSet", payload, true)

  defp apply_event_by_type(state, "ProjectSecretUnset", payload),
    do: put_project_secret(state, "ProjectSecretUnset", payload, false)

  # A malformed ReviewRecorded must not crash `init/1`'s event-log rebuild, so
  # a decode failure is logged and the event skipped rather than raised.
  defp apply_event_by_type(state, "ReviewRecorded", payload) do
    event =
      try do
        decode_for_projection("ReviewRecorded", payload)
      rescue
        error in ArgumentError ->
          Logger.warning(
            "ProjectionStore skipped malformed ReviewRecorded: #{Exception.message(error)}"
          )

          nil
      end

    case event do
      %ForemanServer.Events.ReviewRecorded{subject_kind: kind, subject_id: id}
      when is_binary(kind) and kind != "" and is_binary(id) and id != "" ->
        review = Map.from_struct(event)

        %{state | reviews: Map.put(state.reviews, {kind, id}, review)}
        |> record_review_usage(event)

      _ ->
        state
    end
  end

  # Malformed memory events are logged and skipped so `init/1`'s rebuild
  # never crashes on them.
  defp apply_event_by_type(state, "ProjectMemoryWritten", payload) do
    case decode_or_skip("ProjectMemoryWritten", payload) do
      {:ok,
       %ForemanServer.Events.ProjectMemoryWritten{
         project_id: pid,
         name: name,
         sha256: sha,
         bytes: bytes
       } =
           e}
      when is_binary(pid) and pid != "" and is_binary(name) and name != "" and is_binary(sha) and
             is_integer(bytes) ->
        entry = %{
          name: name,
          description: e.description,
          sha256: e.sha256,
          bytes: e.bytes,
          version: e.version,
          author_kind: e.author_kind,
          author_ref: e.author_ref,
          redactions: e.redactions,
          updated_at: e.at
        }

        put_project_memory(state, pid, &Map.put(&1, name, entry))

      _ ->
        skip_malformed("ProjectMemoryWritten")
        state
    end
  end

  # Malformed library events are logged and skipped, like memory events.
  defp apply_event_by_type(state, "ProjectLibraryAdded", payload),
    do: apply_library_upsert(state, "ProjectLibraryAdded", payload)

  defp apply_event_by_type(state, "ProjectLibraryReplaced", payload),
    do: apply_library_upsert(state, "ProjectLibraryReplaced", payload)

  defp apply_event_by_type(state, "ProjectLibraryRemoved", payload) do
    case decode_or_skip("ProjectLibraryRemoved", payload) do
      {:ok, %ForemanServer.Events.ProjectLibraryRemoved{project_id: pid, entry_id: entry_id}}
      when is_binary(pid) and pid != "" and is_binary(entry_id) and entry_id != "" ->
        put_project_library(state, pid, &Map.delete(&1, entry_id))

      _ ->
        skip_malformed_library("ProjectLibraryRemoved", payload)
        state
    end
  end

  defp apply_event_by_type(state, "ProjectMemoryForgotten", payload) do
    case decode_or_skip("ProjectMemoryForgotten", payload) do
      {:ok, %ForemanServer.Events.ProjectMemoryForgotten{project_id: pid, name: name}}
      when is_binary(pid) and pid != "" and is_binary(name) and name != "" ->
        put_project_memory(state, pid, &Map.delete(&1, name))

      _ ->
        skip_malformed("ProjectMemoryForgotten")
        state
    end
  end

  # Operator disposition flags per thread id. A malformed payload is logged and
  # skipped (never raised) so `init/1`'s event-log rebuild survives it.
  defp apply_event_by_type(state, "ThreadResolved", payload) do
    case decode_or_skip("ThreadResolved", payload) do
      {:ok, %ForemanServer.Events.ThreadResolved{thread_id: id} = event}
      when is_binary(id) and id != "" ->
        flags = %{
          resolved: true,
          resolved_at: event.at,
          reason: event.reason,
          resolved_by: event.resolved_by,
          reopened_at: nil
        }

        %{state | thread_flags: Map.put(state.thread_flags, id, flags)}

      _ ->
        Logger.warning("ProjectionStore skipped malformed ThreadResolved")
        state
    end
  end

  defp apply_event_by_type(state, "ThreadReopened", payload) do
    case decode_or_skip("ThreadReopened", payload) do
      {:ok, %ForemanServer.Events.ThreadReopened{thread_id: id} = event}
      when is_binary(id) and id != "" ->
        flags = %{
          resolved: false,
          resolved_at: nil,
          reason: nil,
          resolved_by: nil,
          reopened_at: event.at
        }

        %{state | thread_flags: Map.put(state.thread_flags, id, flags)}

      _ ->
        Logger.warning("ProjectionStore skipped malformed ThreadReopened")
        state
    end
  end

  # Schedule folds. Malformed payloads are logged and skipped (never raised) so
  # `init/1`'s event-log rebuild survives them; events for a schedule that was
  # never created are ignored.
  defp apply_event_by_type(state, "ScheduleCreated", payload) do
    case decode_or_skip("ScheduleCreated", payload) do
      {:ok, %ForemanServer.Events.ScheduleCreated{project_id: pid, schedule_id: sid} = e}
      when is_binary(pid) and pid != "" and is_binary(sid) and sid != "" ->
        schedule = %{
          schedule_id: sid,
          project_id: pid,
          name: e.name,
          spec: e.spec,
          prompt: e.prompt,
          workflow: e.workflow,
          auto_approve: e.auto_approve,
          overlap: e.overlap,
          misfire_grace_seconds: e.misfire_grace_seconds,
          status: "active",
          created_at: e.created_at,
          active_since: iso_to_unix(e.created_at),
          last_slot: nil,
          last_task_id: nil,
          last_outcome: nil
        }

        %{state | schedules: Map.put(state.schedules, {pid, sid}, schedule)}

      _ ->
        Logger.warning("ProjectionStore skipped malformed ScheduleCreated")
        state
    end
  end

  defp apply_event_by_type(state, "ScheduleUpdated", payload) do
    update_schedule(state, "ScheduleUpdated", payload, fn schedule, e ->
      changes = e.changes

      schedule =
        Enum.reduce(
          ~w(name spec prompt workflow auto_approve overlap misfire_grace_seconds)a,
          schedule,
          fn field, acc ->
            case Map.fetch(changes, Atom.to_string(field)) do
              {:ok, value} -> Map.put(acc, field, value)
              :error -> acc
            end
          end
        )

      if Map.has_key?(changes, "spec"),
        do: %{schedule | active_since: iso_to_unix(e.updated_at)},
        else: schedule
    end)
  end

  defp apply_event_by_type(state, "SchedulePaused", payload),
    do: update_schedule(state, "SchedulePaused", payload, fn s, _e -> %{s | status: "paused"} end)

  defp apply_event_by_type(state, "ScheduleResumed", payload) do
    update_schedule(state, "ScheduleResumed", payload, fn s, e ->
      %{s | status: "active", active_since: iso_to_unix(e.at)}
    end)
  end

  defp apply_event_by_type(state, "ScheduleDeleted", payload),
    do:
      update_schedule(state, "ScheduleDeleted", payload, fn s, _e -> %{s | status: "deleted"} end)

  defp apply_event_by_type(state, "ScheduleFired", payload) do
    update_schedule(state, "ScheduleFired", payload, fn s, e ->
      %{
        s
        | last_slot: e.slot,
          last_task_id: e.task_id,
          last_outcome: %{
            kind: "fired",
            slot: e.slot,
            reason: nil,
            missed_count: e.collapsed_count,
            at: e.fired_at
          }
      }
    end)
  end

  defp apply_event_by_type(state, "ScheduleFireSkipped", payload) do
    update_schedule(state, "ScheduleFireSkipped", payload, fn s, e ->
      %{
        s
        | last_slot: e.slot,
          last_outcome: %{
            kind: "skipped",
            slot: e.slot,
            reason: e.reason,
            missed_count: e.missed_count,
            at: e.skipped_at
          }
      }
    end)
  end

  defp apply_event_by_type(state, "JobsiteStarted", payload) do
    case decode_for_projection("JobsiteStarted", payload) do
      %ForemanServer.Events.JobsiteStarted{jobsite_id: jobsite_id} = event ->
        if valid_id?(jobsite_id) do
          now = payload_event_at_ms(payload)

          jobsite = %{
            jobsite_id: jobsite_id,
            status: "starting",
            repo_path: event.repo_path,
            bead_id: event.bead_id,
            agent: event.agent || %{},
            project_id: event.project_id,
            strategy: event.strategy,
            branch: event.branch,
            target_branch: event.target_branch,
            worktree_path: nil,
            container_id: nil,
            iteration_index: 0,
            max_iterations: event.max_iterations || 1,
            iterations: [],
            session_id: nil,
            commits: [],
            output: nil,
            merged?: false,
            preserved_path: nil,
            last_error: nil,
            terminal?: false,
            started_at_ms: now,
            updated_at_ms: now
          }

          %{state | jobsites: Map.put(state.jobsites, jobsite_id, jobsite)}
        else
          state
        end
    end
  end

  defp apply_event_by_type(state, "JobsiteWorktreeProvisioned", payload) do
    update_jobsite_projection(
      state,
      get(payload, :jobsite_id),
      payload_event_at_ms(payload),
      fn jobsite ->
        jobsite
        |> Map.put(:status, "running")
        |> Map.put(:worktree_path, get(payload, :path))
        |> Map.put(:branch, get(payload, :branch))
      end
    )
  end

  defp apply_event_by_type(state, "JobsiteSandboxProvisioned", payload) do
    update_jobsite_projection(
      state,
      get(payload, :jobsite_id),
      payload_event_at_ms(payload),
      fn jobsite ->
        jobsite
        |> Map.put(:status, "running")
        |> Map.delete(:paused_reason)
        |> Map.put(:container_id, get(payload, :container_id))
      end
    )
  end

  defp apply_event_by_type(state, "JobsiteIterationStarted", payload) do
    update_jobsite_projection(
      state,
      get(payload, :jobsite_id),
      payload_event_at_ms(payload),
      fn jobsite ->
        Map.put(jobsite, :iteration_index, get(payload, :index))
      end
    )
  end

  defp apply_event_by_type(state, "JobsiteIterationCompleted", payload) do
    state
    |> update_jobsite_projection(
      get(payload, :jobsite_id),
      payload_event_at_ms(payload),
      fn jobsite ->
        record = %{
          index: get(payload, :index),
          status: get(payload, :status),
          text: get(payload, :text),
          text_truncated?: get(payload, :text_truncated?, false) == true,
          session_id: get(payload, :session_id),
          signalled?: get(payload, :signalled?, false),
          matched_signal: get(payload, :matched_signal)
        }

        jobsite
        |> Map.put(:iterations, (Map.get(jobsite, :iterations) || []) ++ [record])
        |> Map.put(:session_id, get(payload, :session_id) || Map.get(jobsite, :session_id))
      end
    )
    |> record_iteration_usage(payload)
  end

  defp apply_event_by_type(state, "JobsiteIterationFailed", payload) do
    update_jobsite_projection(
      state,
      get(payload, :jobsite_id),
      payload_event_at_ms(payload),
      fn jobsite ->
        record = %{
          index: get(payload, :index),
          status: "failed",
          code: get(payload, :code),
          message: get(payload, :message)
        }

        jobsite
        |> Map.put(:iterations, (Map.get(jobsite, :iterations) || []) ++ [record])
        |> Map.put(:last_error, %{
          code: get(payload, :code),
          message: get(payload, :message),
          details: get(payload, :details)
        })
      end
    )
  end

  defp apply_event_by_type(state, "JobsiteCommitsRecorded", payload) do
    update_jobsite_projection(
      state,
      get(payload, :jobsite_id),
      payload_event_at_ms(payload),
      fn jobsite ->
        Map.put(jobsite, :commits, get(payload, :commits) || [])
      end
    )
  end

  defp apply_event_by_type(state, "JobsiteOutputCaptured", payload) do
    update_jobsite_projection(
      state,
      get(payload, :jobsite_id),
      payload_event_at_ms(payload),
      fn jobsite ->
        Map.put(jobsite, :output, %{tag: get(payload, :tag), value: get(payload, :value)})
      end
    )
  end

  defp apply_event_by_type(state, "JobsiteSandboxReleased", payload) do
    update_jobsite_projection(
      state,
      get(payload, :jobsite_id),
      payload_event_at_ms(payload),
      fn jobsite ->
        Map.put(jobsite, :container_id, nil)
      end
    )
  end

  defp apply_event_by_type(state, "JobsiteWorktreeReleased", payload) do
    update_jobsite_projection(
      state,
      get(payload, :jobsite_id),
      payload_event_at_ms(payload),
      fn jobsite ->
        jobsite
        |> Map.put(:merged?, get(payload, :merged?, false))
        |> Map.put(:preserved_path, get(payload, :preserved_path))
      end
    )
  end

  defp apply_event_by_type(state, "JobsiteCompleted", payload) do
    update_jobsite_projection(
      state,
      get(payload, :jobsite_id),
      payload_event_at_ms(payload),
      fn jobsite ->
        jobsite
        |> Map.put(:status, "completed")
        |> Map.put(:terminal?, true)
      end
    )
  end

  defp apply_event_by_type(state, "JobsiteFailed", payload) do
    update_jobsite_projection(
      state,
      get(payload, :jobsite_id),
      payload_event_at_ms(payload),
      fn jobsite ->
        jobsite
        |> Map.put(:status, "failed")
        |> Map.put(:terminal?, true)
        |> Map.put(:last_error, %{
          code: get(payload, :code),
          message: get(payload, :message),
          details: get(payload, :details)
        })
      end
    )
  end

  defp apply_event_by_type(state, "JobsitePaused", payload) do
    update_jobsite_projection(
      state,
      get(payload, :jobsite_id),
      payload_event_at_ms(payload),
      fn jobsite ->
        jobsite
        |> Map.put(:status, "paused")
        |> Map.put(:paused_reason, get(payload, :reason))
      end
    )
  end

  defp apply_event_by_type(state, "JobsiteCancelled", payload) do
    update_jobsite_projection(
      state,
      get(payload, :jobsite_id),
      payload_event_at_ms(payload),
      fn jobsite ->
        jobsite
        |> Map.put(:status, "cancelled")
        |> Map.put(:terminal?, true)
      end
    )
  end

  # E7-S1: PR / merge-gate read state for the Overview. Pure fold in
  # `Overview.PrFold`; it logs and skips malformed payloads, so replay survives.
  # E9 additionally folds the same events into the `pr_watch` read model.
  defp apply_event_by_type(state, type, payload) when type in @pr_fold_events do
    state
    |> fold_pr_state(type, payload)
    |> fold_pr_watch(type, payload)
  end

  # E9: PR observation / fix-thread / watch-lifecycle events. Pure fold in
  # `PrWatchFold`; malformed payloads are skipped there.
  defp apply_event_by_type(state, type, payload) when type in @pr_watch_only_events do
    fold_pr_watch(state, type, payload)
  end

  # Coordinator conversation events fold into `state.coordinators` through the
  # pure `Coordinator.Conversation` reducer, which never raises on a malformed
  # payload (`init/1` rebuilds from the event log).
  @coordinator_events ~w(CoordinatorMessageAppended CoordinatorTurnStarted
                         CoordinatorActionRecorded CoordinatorTurnCompleted
                         CoordinatorTurnFailed CoordinatorRestarted)

  defp apply_event_by_type(state, type, payload) when type in @coordinator_events do
    case coordinator_project_id(payload) do
      nil ->
        skip_malformed(type)
        state

      project_id ->
        coordinators = Map.get(state, :coordinators, %{})
        conv = Map.get(coordinators, project_id) || ForemanServer.Coordinator.Conversation.new()
        conv = ForemanServer.Coordinator.Conversation.apply_event(conv, type, payload)
        Map.put(state, :coordinators, Map.put(coordinators, project_id, conv))
    end
  end

  defp apply_event_by_type(state, _type, _payload), do: state

  defp fold_pr_watch(state, type, payload) do
    Map.update(state, :pr_watch, %{}, &ForemanServer.PrWatchFold.fold(&1, type, payload))
  end

  defp unobserved_record(state, run_id, pr_url) do
    run = Map.get(state.runs, run_id, %{})

    run_id
    |> ForemanServer.PrWatchFold.new_record(pr_url)
    |> Map.merge(%{project_id: Map.get(run, :project_id), task_id: Map.get(run, :task_id)})
    |> Map.put(:agent_review, review_signal(Map.get(state, :reviews, %{}), run_id))
  end

  defp pr_watch_view(state, run_id) do
    review = review_signal(Map.get(state, :reviews, %{}), run_id)

    state
    |> Map.get(:pr_watch, %{})
    |> Map.get(run_id, %{})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_url, record} -> Map.put(record, :agent_review, review) end)
  end

  # The run's `ReviewRecorded` verdict, shown as one more PR signal. It never
  # triggers a fix itself: gap beads already carry that path.
  defp review_signal(reviews, run_id) do
    case Map.get(reviews, {"run", run_id}) do
      %{verdict: verdict} = review ->
        %{
          verdict: verdict,
          gap_bead_ids: Map.get(review, :gap_bead_ids, []),
          at: Map.get(review, :at)
        }

      _none ->
        nil
    end
  end

  defp pr_state_view(run_id, run, entry) do
    failure_reason =
      case run do
        %{status: "failed", failure_reason: reason} when is_binary(reason) -> reason
        _ -> nil
      end

    ForemanServer.Overview.PrFold.default_entry()
    |> Map.merge(entry || %{})
    |> Map.merge(%{run_id: run_id, failure_reason: failure_reason})
  end

  defp fold_pr_state(state, type, payload) do
    Map.update(state, :pr_states, %{}, &ForemanServer.Overview.PrFold.fold(&1, type, payload))
  end

  defp coordinator_project_id(payload) when is_map(payload) do
    case Map.get(payload, :project_id) || Map.get(payload, "project_id") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp coordinator_project_id(_payload), do: nil

  defp append_phase_id_to_run(state, run_id, phase_id) do
    case Map.get(state.runs, run_id) do
      nil ->
        state

      run ->
        existing = Map.get(run, :phase_ids, [])

        if phase_id in existing do
          state
        else
          updated = %{run | phase_ids: existing ++ [phase_id]}
          %{state | runs: Map.put(state.runs, run_id, updated)}
        end
    end
  end

  defp update_intent(state, payload, status) do
    intent_id = get(payload, :intent_id)

    if valid_id?(intent_id) do
      existing = Map.get(state.scheduler_intents, intent_id, %{})
      merged = Map.merge(existing, %{status: status, intent_id: intent_id})

      put_state(state, state.projects, state.runs)
      |> Map.put(:scheduler_intents, Map.put(state.scheduler_intents, intent_id, merged))
    else
      state
    end
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp adopt_subject(state, "move", kind, id, target, payload) do
    moved = get(payload, :moved)
    moved = if is_map(moved), do: moved, else: %{}
    run_ids = adopted_ids(moved, :run_ids)

    rehome = fn entries, ids ->
      Enum.reduce(ids, entries, fn entry_id, acc ->
        case Map.get(acc, entry_id) do
          %{project_id: current} = entry when current != target ->
            Map.put(
              acc,
              entry_id,
              entry |> Map.put(:project_id, target) |> Map.put(:adopted_from, current)
            )

          _already_there_or_unknown ->
            acc
        end
      end)
    end

    worktrees =
      Map.new(state.worktrees, fn
        {key, %{run_id: run_id, project_id: current} = wt} when current != target ->
          if run_id in run_ids, do: {key, %{wt | project_id: target}}, else: {key, wt}

        other ->
          other
      end)

    record = %{
      mode: "move",
      project_id: target,
      from_project_id: get(payload, :from_project_id),
      adopted_at: get(payload, :adopted_at)
    }

    %{
      state
      | tasks: rehome.(state.tasks, adopted_ids(moved, :task_ids)),
        runs: rehome.(state.runs, run_ids),
        jobsites: rehome.(state.jobsites, adopted_ids(moved, :jobsite_ids)),
        worktrees: worktrees,
        adoptions: Map.put(state.adoptions, {kind, id}, record)
    }
  end

  # `continue` re-homes nothing: it links the NEW thread (`new_task_id`) to the
  # source subject, on the task once it is projected and in `adoptions` always.
  defp adopt_subject(state, "continue", kind, id, target, payload) do
    new_task_id = get(payload, :new_task_id)
    link = %{kind: kind, id: id, project_id: get(payload, :from_project_id)}

    state =
      case valid_id?(new_task_id) && Map.get(state.tasks, new_task_id) do
        %{} = task ->
          %{
            state
            | tasks: Map.put(state.tasks, new_task_id, Map.put(task, :continued_from, link))
          }

        _ ->
          state
      end

    record = %{
      mode: "continue",
      project_id: target,
      from_project_id: get(payload, :from_project_id),
      new_task_id: new_task_id,
      adopted_at: get(payload, :adopted_at)
    }

    %{state | adoptions: Map.put(state.adoptions, {"continue", kind, id}, record)}
  end

  defp adopted_ids(moved, key) do
    case get(moved, key) do
      ids when is_list(ids) -> Enum.filter(ids, &valid_id?/1)
      _ -> []
    end
  end

  # Pause/resume flip `status` only; an unknown project is left alone (the
  # aggregate guarantees the project exists, so this is a replay-gap guard).
  defp set_project_status(state, payload, status) do
    project_id = get(payload, :project_id)

    case valid_id?(project_id) && Map.get(state.projects, project_id) do
      project when is_map(project) ->
        project =
          project
          |> Map.put(:status, status)
          |> put_project_projection_metadata(payload)

        put_state(state, Map.put(state.projects, project_id, project), state.runs)

      _ ->
        state
    end
  end

  # Threads started per project per UTC day (deduped by kind+id), keeping only
  # the latest `@thread_day_retention` days. Events without a day count nothing.
  @thread_day_retention 8
  defp count_project_thread(state, _project_id, _kind, _id, day) when not is_binary(day),
    do: state

  defp count_project_thread(state, project_id, kind, id, day) do
    days = Map.get(state, :project_thread_days, %{})
    per_day = Map.get(days, project_id, %{})
    keys = per_day |> Map.get(day, MapSet.new()) |> MapSet.put("#{kind}:#{id}")

    per_day =
      per_day
      |> Map.put(day, keys)
      |> Enum.sort_by(fn {d, _} -> d end, :desc)
      |> Enum.take(@thread_day_retention)
      |> Map.new()

    Map.put(state, :project_thread_days, Map.put(days, project_id, per_day))
  end

  defp retain_recent_days(per_day) do
    per_day
    |> Enum.sort_by(fn {d, _} -> d end, :desc)
    |> Enum.take(@thread_day_retention)
    |> Map.new()
  end

  @doc """
  Number of threads (workflow runs + jobsites) the project started on the given
  UTC day (`Date.to_iso8601/1`). Only the last #{@thread_day_retention} days are kept.
  """
  @spec threads_started_on(String.t(), String.t()) :: non_neg_integer()
  def threads_started_on(project_id, day) when is_binary(project_id) and is_binary(day) do
    GenServer.call(__MODULE__, {:threads_started_on, project_id, day})
  end

  defp deferred_task_ids(state, project_id) do
    for {task_id, task} <- state.tasks,
        get(task, :project_id) == project_id,
        get(task, :status) == "in_progress",
        run_id = get(task, :run_id),
        is_binary(run_id) and run_id != "",
        not Map.has_key?(state.runs, run_id),
        do: task_id
  end

  defp project_projection(payload, path) do
    %{
      project_id: get(payload, :project_id),
      path: path,
      status: get(payload, :status, "active"),
      archived?: false,
      config: get(payload, :config, %{}),
      task_provider: get(payload, :task_provider),
      health: get(payload, :health, %{ok: true}),
      name: get(payload, :name)
    }
    |> put_project_settings(payload)
    |> put_project_projection_metadata(payload)
  end

  # Folds the typed settings fields of ProjectRegistered/ProjectUpdated into the
  # projected config under atom keys. Persisted payloads carry string keys after
  # replay, so any string-key variant already in config is removed first.
  # Never raises: a malformed value (not a map payload) is skipped.
  defp put_project_settings(project, payload) when is_map(project) and is_map(payload) do
    cleared =
      case get(payload, :cleared_settings, []) do
        list when is_list(list) -> list
        _ -> []
      end

    config = get(project, :config, %{})
    config = if is_map(config), do: config, else: %{}

    config =
      Enum.reduce(ForemanServer.ProjectSettings.keys(), config, fn key, acc ->
        string_key = Atom.to_string(key)
        acc = if key in cleared or string_key in cleared, do: drop_setting(acc, key), else: acc

        case get(payload, key) do
          nil -> acc
          value -> acc |> drop_setting(key) |> Map.put(key, value)
        end
      end)

    Map.put(project, :config, config)
  end

  defp drop_setting(config, key), do: Map.drop(config, [key, Atom.to_string(key)])

  defp put_project_projection_metadata(project, payload)
       when is_map(project) and is_map(payload) do
    project
    |> maybe_put(:version, get(payload, :_projection_stream_version))
    |> put_registered_projection_timestamp(get(payload, :_projection_recorded_at))
  end

  defp put_registered_projection_timestamp(project, recorded_at) when is_binary(recorded_at) do
    if is_binary(Map.get(project, :registered_at)) do
      project
    else
      project
      |> Map.put(:registered, recorded_at)
      |> Map.put(:registered_at, recorded_at)
    end
  end

  defp put_registered_projection_timestamp(project, _recorded_at), do: project

  defp put_project_config(project, config) do
    Map.put(project, :config, shallow_merge(get(project, :config, %{}), config))
  end

  defp shallow_merge(left, right) when is_map(left) and is_map(right) do
    Enum.reduce(right, left, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  defp shallow_merge(_left, right) when is_map(right), do: right
  defp shallow_merge(left, _right), do: left

  defp add_project_run_id(run_ids, run_id) when is_list(run_ids) do
    if run_id in run_ids, do: run_ids, else: [run_id | run_ids]
  end

  defp remove_project_run_id(active_runs, project_id, run_id) when is_map(active_runs) do
    case Map.get(active_runs, project_id, []) |> Enum.reject(&(&1 == run_id)) do
      [] -> Map.delete(active_runs, project_id)
      remaining -> Map.put(active_runs, project_id, remaining)
    end
  end

  defp upsert_phase_pr(records, record) when is_list(records) and is_map(record) do
    records
    |> Enum.reject(&(Map.get(&1, :phase_id) == Map.get(record, :phase_id)))
    |> Kernel.++([record])
    |> Enum.sort_by(fn pr -> {Map.get(pr, :phase_index, 0), Map.get(pr, :recorded_at, "")} end)
  end

  defp validate_phase_pr_record!(%{status: status, pr_url: url} = record) do
    cond do
      status in ["created", "existing"] and not (is_binary(url) and url != "") ->
        raise ArgumentError,
              "ProjectionStore: PhasePrRecorded #{status} missing usable pr_url: #{inspect(record)}"

      status == "noop" ->
        :ok

      status in ["created", "existing"] ->
        :ok

      true ->
        raise ArgumentError,
              "ProjectionStore: PhasePrRecorded with unknown status: #{inspect(record)}"
    end
  end

  defp project_notification_enqueued(state, payload, event) do
    update_run_projection(state, event.run_id, payload_event_at_ms(payload), fn run ->
      notification = %{
        notification_id: event.notification_id,
        provider: event.provider,
        event_class: event.event_class,
        severity: event.severity,
        correlation_id: event.correlation_id,
        status: "enqueued",
        reason: nil,
        retryable?: nil,
        metadata: event.metadata || %{}
      }

      Map.update(run, :notifications, [notification], fn notifications ->
        notifications
        |> Enum.reject(&(get(&1, :notification_id) == notification.notification_id))
        |> Kernel.++([notification])
      end)
    end)
  end

  defp project_notification_outcome(state, payload, event, status, outcome_fields) do
    update_run_projection(state, event.run_id, payload_event_at_ms(payload), fn run ->
      Map.update(run, :notifications, [], fn notifications ->
        case Enum.split_with(notifications, &(get(&1, :notification_id) == event.notification_id)) do
          {[existing], rest} ->
            [existing |> Map.put(:status, status) |> Map.merge(outcome_fields) | rest]

          {[], rest} ->
            base = %{
              notification_id: event.notification_id,
              provider: event.provider,
              correlation_id: event.correlation_id,
              status: status,
              reason: nil,
              retryable?: nil,
              metadata: %{}
            }

            [Map.merge(base, outcome_fields) | rest]
        end
      end)
    end)
  end

  defp apply_terminal_run_event(state, payload, status) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      run
      |> maybe_put(:task_id, get(payload, :task_id))
      |> maybe_put(:failure_reason, get(payload, :reason))
      |> Map.update(:last_sequence, get(payload, :sequence), & &1)
      |> Map.put(:status, status)
      |> Map.put(:terminal?, true)
    end)
  end

  defp touch_run_for_payload(state, payload) do
    update_run_projection(state, get(payload, :run_id), payload_event_at_ms(payload), fn run ->
      run
    end)
  end

  defp stall_candidates_from_state(state, now_ms) do
    state.phases
    |> Map.values()
    |> Enum.filter(&(get(&1, :status) == "in_progress"))
    |> Enum.filter(
      &(get(&1, :stall_detection_kind) in ["agent_no_output", "messaging_no_progress"])
    )
    |> Enum.filter(fn phase ->
      case Map.get(state.runs, get(phase, :run_id)) do
        %{status: status} when status in @active_run_statuses -> true
        _ -> false
      end
    end)
    |> Enum.flat_map(fn phase ->
      kind = get(phase, :stall_detection_kind)
      threshold_ms = get(phase, :stall_threshold_ms)
      activity_at_ms = activity_at_ms_for_kind(phase, kind)

      if is_integer(threshold_ms) and threshold_ms > 0 and is_integer(activity_at_ms) and
           activity_at_ms + threshold_ms <= now_ms do
        idle_ms = max(now_ms - activity_at_ms, 0)

        [
          %{
            run_id: get(phase, :run_id),
            task_id: get(Map.get(state.runs, get(phase, :run_id)), :task_id),
            phase_id: get(phase, :phase_id),
            phase_index: get(phase, :index),
            phase_name: get(phase, :name),
            stall_kind: kind,
            policy: get(phase, :stall_policy) || "attention",
            threshold_ms: threshold_ms,
            idle_ms: idle_ms,
            activity_at_ms: activity_at_ms,
            detected_at_ms: now_ms,
            idempotency_key: stall_idempotency_key(phase, kind, activity_at_ms),
            reason: stall_reason(phase, kind, idle_ms, threshold_ms)
          }
        ]
      else
        []
      end
    end)
  end

  defp activity_at_ms_for_kind(phase, "agent_no_output"), do: get(phase, :output_activity_at_ms)

  defp activity_at_ms_for_kind(phase, "messaging_no_progress"),
    do: get(phase, :messaging_activity_at_ms)

  defp stall_idempotency_key(phase, kind, activity_at_ms) do
    [get(phase, :run_id), get(phase, :phase_id), kind, activity_at_ms]
    |> Enum.join(":")
  end

  defp stall_reason(phase, "agent_no_output", idle_ms, threshold_ms) do
    "phase #{get(phase, :index)} (#{get(phase, :name)}) produced no agent output for #{idle_ms}ms (threshold #{threshold_ms}ms)"
  end

  defp stall_reason(phase, "messaging_no_progress", idle_ms, threshold_ms) do
    "phase #{get(phase, :index)} (#{get(phase, :name)}) had no messaging progress for #{idle_ms}ms (threshold #{threshold_ms}ms)"
  end

  defp touch_active_phase_activity(state, run_id, kind, event_at_ms) do
    if valid_id?(run_id) do
      phase_ids = state.runs |> Map.get(run_id, %{}) |> Map.get(:phase_ids, [])

      Map.update!(state, :phases, fn phases ->
        Enum.reduce(phase_ids, phases, fn phase_id, acc ->
          case Map.fetch(acc, phase_id) do
            {:ok, phase} ->
              if get(phase, :status) == "in_progress" do
                key =
                  if kind == :messaging,
                    do: :messaging_activity_at_ms,
                    else: :output_activity_at_ms

                Map.put(acc, phase_id, Map.put(phase, key, event_at_ms))
              else
                acc
              end

            :error ->
              acc
          end
        end)
      end)
    else
      state
    end
  end

  defp latest_stall_from_payload(payload) do
    %{
      run_id: get(payload, :run_id),
      task_id: get(payload, :task_id),
      phase_id: get(payload, :phase_id),
      phase_index: get(payload, :phase_index),
      phase_name: get(payload, :phase_name),
      stall_kind: get(payload, :stall_kind),
      policy: get(payload, :policy),
      status_effect: get(payload, :status_effect),
      threshold_ms: get(payload, :threshold_ms),
      idle_ms: get(payload, :idle_ms),
      activity_at_ms: get(payload, :activity_at_ms),
      detected_at_ms: get(payload, :detected_at_ms),
      idempotency_key: get(payload, :idempotency_key),
      reason: get(payload, :reason)
    }
  end

  defp maybe_put_status_effect(run, nil, _reason), do: run

  defp maybe_put_status_effect(run, status, reason)
       when status in ["failed", "blocked", "stuck"] do
    run
    |> Map.put(:status, status)
    |> Map.put(:terminal?, status in ["failed", "blocked", "stuck"])
    |> Map.put(:failure_reason, reason)
  end

  # Unknown status_effect (a future/unrecognized value persisted by a newer
  # writer): record it as the latest stall without changing run status, so
  # replay does not crash on a value this reader does not recognize yet.
  defp maybe_put_status_effect(run, _status, _reason), do: run

  defp update_task_latest_stall(state, nil, _stall), do: state

  defp update_task_latest_stall(state, task_id, stall) do
    if valid_id?(task_id) do
      Map.update!(state, :tasks, fn tasks ->
        Map.update(
          tasks,
          task_id,
          %{task_id: task_id, latest_stall: stall, attention_reason: stall.reason},
          fn task ->
            task
            |> Map.put(:latest_stall, stall)
            |> Map.put(:attention_reason, stall.reason)
          end
        )
      end)
    else
      state
    end
  end

  defp update_run_projection(state, run_id, event_at_ms, updater) when is_function(updater, 1) do
    if valid_id?(run_id) do
      run =
        state.runs
        |> Map.get(run_id, base_run_projection(run_id, event_at_ms))
        |> updater.()
        |> Map.put(:run_id, run_id)
        |> Map.put(:last_event_at_ms, event_at_ms)

      put_state(state, state.projects, Map.put(state.runs, run_id, run))
    else
      state
    end
  end

  defp update_jobsite_projection(state, jobsite_id, event_at_ms, updater)
       when is_function(updater, 1) do
    if valid_id?(jobsite_id) do
      jobsite =
        state.jobsites
        |> Map.get(jobsite_id, base_jobsite_projection(jobsite_id, event_at_ms))
        |> updater.()
        |> Map.put(:jobsite_id, jobsite_id)
        |> Map.put(:updated_at_ms, event_at_ms)

      %{state | jobsites: Map.put(state.jobsites, jobsite_id, jobsite)}
    else
      state
    end
  end

  defp base_jobsite_projection(jobsite_id, now_ms) do
    %{
      jobsite_id: jobsite_id,
      status: "starting",
      strategy: nil,
      branch: nil,
      target_branch: nil,
      worktree_path: nil,
      container_id: nil,
      iteration_index: 0,
      max_iterations: 1,
      iterations: [],
      session_id: nil,
      commits: [],
      output: nil,
      merged?: false,
      preserved_path: nil,
      last_error: nil,
      terminal?: false,
      started_at_ms: now_ms,
      updated_at_ms: now_ms
    }
  end

  defp base_run_projection(run_id, now_ms) do
    %{
      run_id: run_id,
      status: "awaiting_worker",
      task_id: nil,
      project_id: nil,
      workflow_name: nil,
      workflow_digest: nil,
      workflow_snapshot: nil,
      phase_ids: [],
      last_sequence: nil,
      started_at_ms: now_ms,
      last_event_at_ms: now_ms,
      terminal?: false,
      failure_reason: nil,
      latest_stall: nil,
      pr_url: nil,
      phase_prs: [],
      notifications: [],
      provider_session_id: nil,
      provider_sessions: [],
      usage: nil
    }
  end

  defp filter_runs(runs, opts) do
    status = Keyword.get(opts, :status)
    project_id = Keyword.get(opts, :project_id)

    Enum.filter(runs, fn run ->
      status_match? = is_nil(status) or status == "" or get(run, :status) == status

      project_match? =
        is_nil(project_id) or project_id == "" or get(run, :project_id) == project_id

      status_match? and project_match?
    end)
  end

  defp limit_runs(runs, nil), do: runs
  defp limit_runs(runs, limit) when is_integer(limit) and limit > 0, do: Enum.take(runs, limit)
  defp limit_runs(runs, _limit), do: runs

  defp active_run_ids(state) do
    state.runs
    |> Enum.reduce([], fn
      {run_id, %{status: status}}, acc when status in @active_run_statuses -> [run_id | acc]
      _, acc -> acc
    end)
    |> Enum.sort()
  end

  # Secret events carry name + version only (no value field exists), so the
  # projection cannot leak one. A malformed event is skipped, not fatal to the
  # event-log rebuild in `init/1`.
  defp put_project_secret(state, event_type, payload, set?) do
    case decode_or_skip(event_type, payload) do
      {:ok, %{project_id: project_id, name: name, version: version, at: at}}
      when is_binary(project_id) and project_id != "" and is_binary(name) and is_integer(version) ->
        entry = %{set?: set?, version: version, updated_at: at}
        per_project = state.project_secrets |> Map.get(project_id, %{}) |> Map.put(name, entry)
        %{state | project_secrets: Map.put(state.project_secrets, project_id, per_project)}

      _ ->
        state
    end
  end

  defp put_state(state, projects, runs) do
    %{
      state
      | projects: projects,
        runs: runs
    }
  end

  @run_logs_default_limit 500
  @run_logs_max_limit 5_000
  @run_logs_max_bytes 1_048_576

  # Match the decoded event STRUCT, exactly as `PrAssociated` above does. The
  # bare `%{run_id: _, worker_id: _, sequence: _, line: _}` map pattern this
  # replaced matched by shape, so renaming a field on `Events.WorkerStdout`
  # would have stopped matching and fallen into a `_ -> state` catch-all that
  # silently discarded the log line — the precise failure mode AGENTS.md 5.1
  # and 5.5 exist to prevent.
  #
  # AGENTS.md 5.3: a blank run_id/worker_id is MALFORMED, not absent. It
  # cannot be projected (the entry would have no run to belong to and no
  # stream id), and silently dropping it is indistinguishable from "this
  # worker wrote nothing" — the same confusion the tool's old
  # `:no_log_store` reply created. `WorkerProtocol.emit/2` supplies both, so
  # reaching here means that boundary was bypassed: raise.
  defp project_worker_log(state, decoded, payload, channel)
       when channel in ["stdout", "stderr"] do
    case decoded do
      %{run_id: run_id, worker_id: worker_id} = event
      when is_struct(event, WorkerStdout) or is_struct(event, WorkerStderr) ->
        if is_binary(run_id) and run_id != "" and is_binary(worker_id) and worker_id != "" do
          project_worker_log_entry(state, event, payload, channel, run_id, worker_id)
        else
          raise ArgumentError,
                "ProjectionStore: #{channel} log event with unusable run_id/worker_id: " <>
                  inspect(event)
        end
    end
  end

  defp project_worker_log_entry(state, event, payload, channel, run_id, worker_id) do
    entry = %{
      worker_id: worker_id,
      channel: channel,
      sequence: event.sequence,
      timestamp: event.timestamp || get(payload, :_projection_recorded_at),
      content: event.line || "",
      stream_id: "worker:#{run_id}:#{worker_id}",
      event_number: get(payload, :_projection_event_number),
      stream_version: get(payload, :_projection_stream_version)
    }

    log_state =
      state
      |> Map.get(:run_logs, %{})
      |> Map.get(run_id, empty_run_log_state())
      |> put_log_entry(entry)

    state
    |> touch_run_for_payload(payload)
    |> touch_active_phase_activity(run_id, :output, payload_event_at_ms(payload))
    |> Map.update(:run_logs, %{run_id => log_state}, &Map.put(&1, run_id, log_state))
  end

  defp empty_run_log_state do
    %{entries: :queue.new(), count: 0, bytes: 0, omitted_entries: 0, omitted_bytes: 0}
  end

  # Append is O(1) and evicts at most as many entries as the caps require.
  #
  # The list version of this rebuilt a fresh @run_logs_max_limit-cons-cell
  # list on EVERY log line (`length/1` + `Enum.take/2` + `Enum.drop/2`), and
  # this runs inside the single-writer `ProjectionStore` GenServer that also
  # serves `run/1`, `list_runs/1` and the scheduler's `active_runs/0` — so a
  # chatty worker charged every other projection read for its output.
  #
  # Both caps are needed and they bound different things: `@run_logs_max_limit`
  # bounds entry count, `@run_logs_max_bytes` bounds RESIDENT MEMORY, which
  # entry count alone does not (a line has no intrinsic size limit, and a run
  # may have many workers). This is a memory bound on the read model, distinct
  # from `WorkerLogPolicy`'s bound on how many events are durably WRITTEN —
  # different resources, so not a duplicated boundary (AGENTS.md 5.7). Do not
  # delete one because the other exists. Evictions are always accounted in
  # `omitted_entries`/`omitted_bytes` so a truncated read can never look
  # complete.
  defp put_log_entry(log_state, entry) do
    log_state
    |> Map.update!(:entries, &:queue.in(entry, &1))
    |> Map.update!(:count, &(&1 + 1))
    |> Map.update!(:bytes, &(&1 + byte_size(entry.content)))
    |> evict_over_cap()
  end

  defp evict_over_cap(%{count: count, bytes: bytes} = log_state)
       when count > @run_logs_max_limit or bytes > @run_logs_max_bytes do
    {{:value, oldest}, entries} = :queue.out(log_state.entries)
    size = byte_size(oldest.content)

    evict_over_cap(%{
      log_state
      | entries: entries,
        count: log_state.count - 1,
        bytes: log_state.bytes - size,
        omitted_entries: log_state.omitted_entries + 1,
        omitted_bytes: log_state.omitted_bytes + size
    })
  end

  defp evict_over_cap(log_state), do: log_state

  defp run_logs_result(state, run_id) do
    log_state = state |> Map.get(:run_logs, %{}) |> Map.get(run_id, empty_run_log_state())

    # `:queue.to_list/1` is already oldest-first (the order events were
    # applied), and `Enum.sort_by/2` is stable, so this preserves arrival
    # order and only makes the cross-worker key explicit.
    entries =
      log_state.entries
      |> :queue.to_list()
      |> Enum.sort_by(&log_sort_key/1)

    total = log_state.count
    tail = Enum.take(entries, -@run_logs_default_limit)
    tail_omitted = max(total - length(tail), 0)

    {:ok,
     %{
       run_id: run_id,
       entries: tail,
       count: length(tail),
       limit: @run_logs_default_limit,
       truncated: tail_omitted > 0 or log_state.omitted_entries > 0,
       omitted_entries: log_state.omitted_entries + tail_omitted,
       omitted_bytes: log_state.omitted_bytes,
       max_limit: @run_logs_max_limit
     }}
  end

  defp log_sort_key(entry) do
    {entry.event_number || 0, entry.timestamp || "", entry.worker_id, entry.sequence || 0,
     entry.channel}
  end

  defp recorded_event_at_ms(%RecordedEvent{created_at: %DateTime{} = created_at}, _now_ms_fun) do
    DateTime.to_unix(created_at, :millisecond)
  end

  defp recorded_event_at_ms(_recorded, now_ms_fun) do
    now_ms_fun.()
  end

  defp payload_event_at_ms(payload) do
    get(payload, :_projection_event_at_ms, resolve_now_ms_fun().())
  end

  defp with_event_at_ms(payload, event_at_ms) when is_map(payload) do
    Map.put(payload, :_projection_event_at_ms, event_at_ms)
  end

  # The EventCodec enforces a closed set of fields per typed event struct.
  # `_projection_event_at_ms` is a projection-private timestamp we attach
  # in `with_event_at_ms/2` so `payload_event_at_ms/1` can read it without
  # coupling handlers to metadata storage. Strip it before decoding so
  # typed-event validation does not reject the private key.
  #
  # `event_type` is stripped for the same reason and it is NOT cosmetic:
  # `Overwatch.Tracker.dispatch_lifecycle/3` folds `"event_type" => type`
  # into the payload it persists (`tracker.ex:314-324`), so every worker
  # lifecycle event on disk carries it, while no struct under
  # `ForemanServer.Events` declares such a field. `EventCodec.decode!/2`
  # rejects undeclared keys, so decoding a persisted `WorkerStdout` /
  # `WorkerStderr` raised `ArgumentError` inside
  # `rebuild_state_from_event_log/1` — that runs in `init/1`, so the
  # ProjectionStore failed to start and took the whole application down at
  # boot for any event store containing a single worker log event. The
  # handlers that predate this read those payloads with `get/2` instead of
  # decoding them, which is why nothing had hit it before.
  #
  # Strip it HERE, at the one decode boundary, rather than in the worker-log
  # handler: every future typed handler reading a Tracker-produced payload
  # would otherwise re-discover the same crash (AGENTS.md 5.7).
  defp put_project_memory(state, project_id, fun) do
    topics = state.project_memory |> Map.get(project_id, %{}) |> fun.()
    %{state | project_memory: Map.put(state.project_memory, project_id, topics)}
  end

  defp apply_library_upsert(state, type, payload) do
    case decode_or_skip(type, payload) do
      {:ok, %{project_id: pid, entry_id: entry_id, name: name, manifest_sha256: sha} = e}
      when is_binary(pid) and pid != "" and is_binary(entry_id) and entry_id != "" and
             is_binary(name) and is_binary(sha) ->
        entry = %{
          entry_id: entry_id,
          name: name,
          kind: e.kind,
          file_count: e.file_count,
          bytes: e.bytes,
          manifest_sha256: sha,
          source: e.source,
          skipped_summary: e.skipped_summary,
          author_kind: e.author_kind,
          author_ref: e.author_ref,
          updated_at: e.at
        }

        put_project_library(state, pid, &Map.put(&1, entry_id, entry))

      _ ->
        skip_malformed_library(type, payload)
        state
    end
  end

  defp put_project_library(state, project_id, fun) do
    entries = state.project_library |> Map.get(project_id, %{}) |> fun.()
    %{state | project_library: Map.put(state.project_library, project_id, entries)}
  end

  defp skip_malformed(event_type),
    do: Logger.warning("ProjectionStore skipped malformed #{event_type}")

  # A malformed library event means the audit index silently disagrees with the
  # disk, so it is logged at :error (with the payload's keys) rather than as a
  # routine warning. Replay still continues: `init/1` must not crash on one bad event.
  defp skip_malformed_library(event_type, payload) do
    keys =
      if is_map(payload),
        do: payload |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
        else: []

    Logger.error(
      "ProjectionStore skipped malformed #{event_type}: library index is missing this event " <>
        "(payload keys: #{inspect(keys)})"
    )
  end

  defp decode_for_projection(event_type, payload)
       when is_binary(event_type) and is_map(payload) do
    EventCodec.decode!(event_type, drop_projection_meta(payload))
  end

  # `decode_for_projection/2` for handlers that must survive a malformed
  # historical payload: an undecodable event is skipped, not fatal to `init/1`.
  defp decode_or_skip(event_type, payload) do
    {:ok, decode_for_projection(event_type, payload)}
  rescue
    ArgumentError -> :error
  end

  defp with_recorded_projection_metadata(payload, %RecordedEvent{} = recorded, now_ms_fun) do
    payload
    |> with_event_at_ms(recorded_event_at_ms(recorded, now_ms_fun))
    |> Map.put(:_projection_stream_version, recorded.stream_version)
    |> Map.put(:_projection_event_number, recorded.event_number)
    |> maybe_put(:_projection_recorded_at, recorded_event_timestamp(recorded))
  end

  defp recorded_event_timestamp(%RecordedEvent{created_at: %DateTime{} = created_at}) do
    DateTime.to_iso8601(created_at)
  end

  defp recorded_event_timestamp(%RecordedEvent{created_at: created_at})
       when is_binary(created_at) do
    created_at
  end

  defp recorded_event_timestamp(_recorded), do: nil

  defp drop_projection_meta(payload) do
    payload
    |> Map.delete(:_projection_event_at_ms)
    |> Map.delete("_projection_event_at_ms")
    |> Map.delete(:_projection_stream_version)
    |> Map.delete("_projection_stream_version")
    |> Map.delete(:_projection_event_number)
    |> Map.delete("_projection_event_number")
    |> Map.delete(:_projection_recorded_at)
    |> Map.delete("_projection_recorded_at")
    |> Map.delete(:event_type)
    |> Map.delete("event_type")
  end

  # `%EventStore.RecordedEvent{}` derives no Jason.Encoder, so it cannot cross
  # the MCP boundary. Project it onto the fields a caller inspecting a run
  # actually needs.
  defp recorded_event_to_map(%RecordedEvent{} = event) do
    %{
      event_number: event.event_number,
      event_id: event.event_id,
      stream_uuid: event.stream_uuid,
      stream_version: event.stream_version,
      event_type: event.event_type,
      created_at: encode_timestamp(event.created_at),
      data: event.data
    }
  end

  # Worker events live on one `worker:<run_id>:<worker_id>` stream per worker,
  # so the worker set for a run is discovered from the stream table: the run
  # projection only records a worker once it goes unresponsive, and the run
  # stream never carries worker events at all.
  defp worker_activity_for_run(run_id) do
    prefix = "worker:#{run_id}:"

    with {:ok, stream_uuids} <- worker_stream_uuids(prefix, 1, []) do
      stream_uuids
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn stream_uuid, {:ok, acc} ->
        case EventStore.read_stream_forward(stream_uuid, 0, 99_999_999) do
          {:ok, events} ->
            {:cont, {:ok, [worker_activity(stream_uuid, prefix, events) | acc]}}

          # A stream listed a moment ago can be hard-deleted before we read it.
          {:error, :stream_not_found} ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, activity} -> {:ok, Enum.reverse(activity)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # `paginate_streams(search: term)` matches `%term%`, so the prefix is
  # re-checked here: a substring hit elsewhere in a stream id is not a worker
  # stream for this run. Sorting by `stream_uuid` keeps paging stable.
  defp worker_stream_uuids(prefix, page_number, acc) do
    opts = [search: prefix, page_number: page_number, page_size: 100, sort_by: :stream_uuid]

    case EventStore.paginate_streams(opts) do
      {:ok, %Page{entries: entries, total_pages: total_pages}} ->
        acc =
          Enum.reduce(entries, acc, fn %StreamInfo{stream_uuid: stream_uuid}, uuids ->
            if String.starts_with?(stream_uuid, prefix), do: [stream_uuid | uuids], else: uuids
          end)

        if page_number >= total_pages do
          {:ok, acc}
        else
          worker_stream_uuids(prefix, page_number + 1, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp worker_activity(stream_uuid, prefix, events) do
    heartbeats = Enum.filter(events, &(&1.event_type == "WorkerHeartbeat"))

    %{
      worker_id: String.replace_prefix(stream_uuid, prefix, ""),
      event_count: length(events),
      heartbeat_count: length(heartbeats),
      last_sequence: last_worker_sequence(events),
      last_event_type: last_worker_event_type(events),
      last_event_at: last_worker_event_at(events),
      last_heartbeat_at: last_worker_event_at(heartbeats)
    }
  end

  defp last_worker_event_type([]), do: nil
  defp last_worker_event_type(events), do: List.last(events).event_type

  defp last_worker_event_at([]), do: nil
  defp last_worker_event_at(events), do: encode_timestamp(List.last(events).created_at)

  # `Overwatch.Tracker` allocates a strictly increasing sequence per worker
  # event, so the last event on the stream carries the highest one.
  defp last_worker_sequence([]), do: nil
  defp last_worker_sequence(events), do: get(List.last(events).data, :sequence)

  defp encode_timestamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp encode_timestamp(at) when is_binary(at), do: at
  defp encode_timestamp(_), do: nil

  defp to_payload_map(%{} = payload) do
    if Map.has_key?(payload, :__struct__) do
      Map.from_struct(payload)
    else
      payload
    end
  end

  defp init_now_ms_fun(init_arg) when is_list(init_arg) do
    case Keyword.get(init_arg, :now_ms) do
      now_ms_fun when is_function(now_ms_fun, 0) -> now_ms_fun
      _ -> resolve_now_ms_fun()
    end
  end

  defp init_now_ms_fun(_init_arg), do: resolve_now_ms_fun()

  # An ABSENT declaration reads as the empty list, because "declared nothing"
  # and "declared an empty list" mean the same thing to the approval guard. A
  # non-list is passed through UNCHANGED so the guard can refuse it: collapsing
  # it to `[]` here is the bug this replaced, and it read as "no dependencies".
  defp normalize_dependencies(nil), do: []
  defp normalize_dependencies(dependency_ids) when is_list(dependency_ids), do: dependency_ids
  defp normalize_dependencies(malformed), do: malformed

  defp normalize_now_ms_fun(nil), do: resolve_now_ms_fun()

  defp normalize_now_ms_fun(now_ms) when is_integer(now_ms), do: fn -> now_ms end
  defp normalize_now_ms_fun(now_ms_fun) when is_function(now_ms_fun, 0), do: now_ms_fun

  defp resolve_now_ms_fun do
    case Process.get(:projection_store_now_ms) do
      now_ms_fun when is_function(now_ms_fun, 0) ->
        now_ms_fun

      _ ->
        case Application.get_env(:foreman_server, :projection_store_now_ms) do
          now_ms_fun when is_function(now_ms_fun, 0) -> now_ms_fun
          _ -> fn -> System.system_time(:millisecond) end
        end
    end
  end

  defp update_schedule(state, event_type, payload, fun) do
    case decode_or_skip(event_type, payload) do
      {:ok, %{project_id: pid, schedule_id: sid} = event}
      when is_binary(pid) and is_binary(sid) ->
        case Map.fetch(state.schedules, {pid, sid}) do
          {:ok, schedule} ->
            %{state | schedules: Map.put(state.schedules, {pid, sid}, fun.(schedule, event))}

          :error ->
            state
        end

      _ ->
        Logger.warning("ProjectionStore skipped malformed #{event_type}")
        state
    end
  end

  defp iso_to_unix(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp iso_to_unix(_), do: nil

  defp iso_to_ms(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp iso_to_ms(_), do: nil

  # A tool call / question is owned by a run id, or by a jobsite id for the jobsite door.
  defp subject_project_id(state, subject_id) do
    case {Map.get(state.runs, subject_id), Map.get(state.jobsites, subject_id)} do
      {%{project_id: pid}, _} when is_binary(pid) -> pid
      {_, %{project_id: pid}} when is_binary(pid) -> pid
      _ -> nil
    end
  end

  defp decide_tool_call(state, event_type, payload, status) do
    case decode_or_skip(event_type, payload) do
      {:ok, %{run_id: run_id, tool_call_id: id} = e} ->
        update_tool_call(state, run_id, id, fn call ->
          %{
            call
            | status: status,
              decided_at: e.decided_at,
              decided_by: e.decided_by,
              reason: e.reason
          }
        end)

      _ ->
        Logger.warning("ProjectionStore skipped malformed #{event_type}")
        state
    end
  end

  defp update_question(state, run_id, question_id, fun) do
    case Map.fetch(state.questions, {run_id, question_id}) do
      {:ok, question} ->
        %{state | questions: Map.put(state.questions, {run_id, question_id}, fun.(question))}

      :error ->
        state
    end
  end

  defp update_tool_call(state, run_id, tool_call_id, fun) do
    case Map.fetch(state.tool_calls, {run_id, tool_call_id}) do
      {:ok, call} ->
        %{state | tool_calls: Map.put(state.tool_calls, {run_id, tool_call_id}, fun.(call))}

      :error ->
        state
    end
  end

  defp valid_id?(value) when is_binary(value), do: value != ""
  defp valid_id?(_value), do: false

  defp maybe_put(project, _key, nil), do: project
  defp maybe_put(project, key, value), do: Map.put(project, key, value)

  # -- usage ledger (E14) ------------------------------------------------------

  defp record_usage(state, project_id, key, record) when is_binary(project_id) do
    usage = Map.get(state, :usage, %{})
    ledger = usage |> Map.get(project_id, UsageLedger.new()) |> UsageLedger.put(key, record)
    Map.put(state, :usage, Map.put(usage, project_id, ledger))
  end

  defp record_usage(state, _project_id, _key, _record), do: state

  defp usage_at(at, payload) do
    case is_binary(at) && DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} ->
        DateTime.to_iso8601(datetime)

      _ ->
        payload
        |> payload_event_at_ms()
        |> DateTime.from_unix!(:millisecond)
        |> DateTime.to_iso8601()
    end
  end

  defp usage_provider_atom(provider) do
    case to_string(provider) do
      "claude" -> :claude
      "pi" -> :pi
      _ -> :unknown
    end
  end

  defp usage_from_map(%{} = fields) do
    Usage.from_fields(
      Map.new(
        [
          :input_tokens,
          :output_tokens,
          :cache_read_tokens,
          :cache_write_tokens,
          :total_tokens,
          :cost_usd
        ],
        &{&1, get(fields, &1)}
      )
    )
  end

  defp usage_from_map(_), do: %Usage{}

  defp record_worker_usage(state, %UsageRecorded{} = event, usage, payload) do
    jobsite = Map.get(state.jobsites, event.run_id)
    run = Map.get(state.runs, event.run_id)

    {kind, project_id} =
      cond do
        is_map(jobsite) ->
          {"jobsite", event.project_id || Map.get(jobsite, :project_id)}

        true ->
          {"workflow", event.project_id || (is_map(run) && Map.get(run, :project_id)) || nil}
      end

    if Usage.empty?(usage) do
      state
    else
      record_usage(state, project_id, {kind, event.run_id, {:worker, event.worker_id}}, %{
        thread_kind: kind,
        thread_id: event.run_id,
        role: event.role || "thread",
        model: event.model,
        provider: event.provider,
        at: usage_at(event.at, payload),
        usage: usage
      })
    end
  end

  defp record_iteration_usage(state, payload) do
    jobsite_id = get(payload, :jobsite_id)
    jobsite = Map.get(state.jobsites, jobsite_id)
    raw = get(payload, :usage)

    if is_map(jobsite) and is_map(raw) and map_size(raw) > 0 do
      agent = Map.get(jobsite, :agent) || %{}
      provider = get(agent, :provider)
      usage = Usage.normalize(usage_provider_atom(provider), raw, nil)

      if Usage.empty?(usage) do
        state
      else
        record_usage(
          state,
          Map.get(jobsite, :project_id),
          {"jobsite", jobsite_id, {:iteration, get(payload, :index)}},
          %{
            thread_kind: "jobsite",
            thread_id: jobsite_id,
            role: "thread",
            model: get(agent, :model),
            provider: provider && to_string(provider),
            at: usage_at(nil, payload),
            usage: usage
          }
        )
      end
    else
      state
    end
  end

  defp record_review_usage(state, %ForemanServer.Events.ReviewRecorded{} = event) do
    usage = usage_from_map(event.usage)

    if Usage.empty?(usage) do
      state
    else
      kind = if event.subject_kind == "jobsite", do: "jobsite", else: "workflow"

      record_usage(state, event.project_id, {kind, event.subject_id, {:worker, "review"}}, %{
        thread_kind: kind,
        thread_id: event.subject_id,
        role: "review",
        model: event.model,
        provider: event.usage_provider,
        at: usage_at(event.at, %{}),
        usage: usage
      })
    end
  end

  defp get(%{} = m, k), do: get(m, k, nil)

  defp get(%{} = m, k, default) when is_atom(k) do
    Map.get(m, k, Map.get(m, Atom.to_string(k), default))
  end

  defp get(%{} = m, k, default), do: Map.get(m, k, default)
end
