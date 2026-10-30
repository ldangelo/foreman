defmodule ForemanServer.Aggregates.Run.PrWatch do
  @moduledoc """
  Pure PR-watch rules of the `Run` aggregate (E9): what a watched PR looks like
  in aggregate state, how the PR commands turn into events, and every guard
  that keeps automatic fixing bounded.

  State (kept on `Aggregates.Run.State`, keyed by `pr_url`; a nullable
  `repo_id` rides on every payload and is passed through, never defaulted -
  spike S3: absent = the run's primary repo):

    * `pr_watch` - `%{pr_url => %{status, head_sha, base_branch, checks_state,
      checks_digest, review_digest, review_decision, watching, ...}}`.
    * `pr_fixes` - `%{pr_url => %{attempts: %{kind => n}, in_flight: nil |
      :requested | jobsite_id, last_fix_head_sha, last_outcome: %{kind =>
      outcome}, last_finished_at, exhausted: %{kind => head_sha}}}`.

  Commands handled (all allowed on terminal runs - a PR outlives its run):
  `run.pr.checks`, `run.pr.review` (system, from `PrWatcher`),
  `run.pr.fix_ci | address_comments | resolve_conflicts` (operator or system),
  `run.pr.fix_started | fix_finished | fix_exhausted` (system),
  `run.pr.watch_stop | watch_start`, `run.pr.create` (operator; the real
  `gh pr create` ran before dispatch, see `ForemanServer.PrCreate`).

  Guards read this authoritative state, never the projection, so they survive
  restarts and optimistic-concurrency retries. Merging stays out of here: the
  merge gate is `run.pr.merge` / `merge_approve`, operator-only.
  """

  alias ForemanServer.Aggregate

  @kinds %{
    "run.pr.fix_ci" => "ci",
    "run.pr.address_comments" => "comments",
    "run.pr.resolve_conflicts" => "conflicts"
  }

  @command_types [
                   "run.pr.checks",
                   "run.pr.review",
                   "run.pr.fix_started",
                   "run.pr.fix_finished",
                   "run.pr.fix_exhausted",
                   "run.pr.watch_stop",
                   "run.pr.watch_start",
                   "run.pr.create"
                 ] ++ Map.keys(@kinds)

  @events %{
    "run.pr.checks" => "PrChecksChanged",
    "run.pr.review" => "PrReviewChanged",
    "run.pr.fix_ci" => "PrFixRequested",
    "run.pr.address_comments" => "PrFixRequested",
    "run.pr.resolve_conflicts" => "PrFixRequested",
    "run.pr.fix_started" => "PrFixStarted",
    "run.pr.fix_finished" => "PrFixFinished",
    "run.pr.fix_exhausted" => "PrFixExhausted",
    "run.pr.watch_stop" => "PrWatchStopped",
    "run.pr.watch_start" => "PrWatchStarted",
    "run.pr.create" => "PrCreated"
  }

  @checks_states ~w(none pending failing passing)
  @review_decisions [nil, "approved", "changes_requested", "review_required"]
  @outcomes ~w(pushed no_change failed)
  @exhaust_reasons ~w(max_attempts no_progress)
  @watch_stop_reasons ~w(operator merged closed)
  @watch_start_reasons ~w(operator reopened)
  @open_statuses ~w(open conflicted)

  @hard_cap 5
  @default_auto_cap 2
  @max_note 2000

  @doc "Every command type this module handles."
  @spec command_types() :: [String.t()]
  def command_types, do: @command_types

  @doc "Every event type this module can emit (the values of its command→event map)."
  @spec event_types() :: [String.t()]
  def event_types, do: @events |> Map.values() |> Enum.uniq()

  @operator_types ~w(run.pr.fix_ci run.pr.address_comments run.pr.resolve_conflicts
                     run.pr.watch_stop run.pr.watch_start run.pr.create)

  @doc """
  The PR commands an operator may issue (`CommandGateway` / `CommandController`
  allowlists). The rest of `command_types/0` (observations, fix start/finish/exhausted)
  is system-only. Merging (`run.pr.merge`, `merge_approve`) is NOT here and is never
  issued by the watcher.
  """
  @spec operator_types() :: [String.t()]
  def operator_types, do: @operator_types

  @doc "The fix commands (`run.pr.fix_ci | address_comments | resolve_conflicts`): the ones that may carry an operator `note`."
  @spec fix_types() :: [String.t()]
  def fix_types, do: Map.keys(@kinds)

  @doc "Fix kinds, `ci | comments | conflicts`."
  @spec kinds() :: [String.t()]
  def kinds, do: Map.values(@kinds)

  @doc "Hard per-PR, per-kind ceiling on fix attempts (also applies to operators)."
  @spec hard_cap() :: pos_integer()
  def hard_cap, do: @hard_cap

  @doc "Whether `type` is an E9 PR command."
  @spec handles?(String.t()) :: boolean()
  def handles?(type), do: type in @command_types

  @doc """
  Handle a PR command against the aggregate `state` (a `Run.State`).
  Returns `{:ok, event_spec}`, `{:ok, nil}` for a no-op repeat, or
  `{:error, reason}`.
  """
  @spec handle(struct(), String.t(), map()) :: {:ok, map() | nil} | {:error, term()}
  def handle(state, type, payload) when type in @command_types do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         {:ok, pr_url} <- resolve_pr_url(state, type, payload) do
      do_handle(type, state, run_id, pr_url, payload)
    end
  end

  defp require_exists(%{exists?: true, run_id: run_id}, run_id), do: :ok
  defp require_exists(_state, run_id), do: {:error, {:not_found, :run, run_id}}

  # `run.pr.create` has no PR yet: its payload names the PR just opened.
  defp resolve_pr_url(state, type, payload) do
    case Aggregate.get(payload, :pr_url) do
      url when is_binary(url) and url != "" ->
        {:ok, url}

      nil when type in ["run.pr.checks", "run.pr.review", "run.pr.create"] ->
        {:error, {:missing_or_invalid, :pr_url}}

      nil ->
        single_watched_url(state, Aggregate.get(payload, :run_id))

      _other ->
        {:error, {:missing_or_invalid, :pr_url}}
    end
  end

  # Operator commands may omit `pr_url` while the run knows exactly one PR (always
  # true until multi-repo runs, E12); with several, exactly one may be watched;
  # otherwise the caller must name it.
  defp single_watched_url(state, run_id) do
    case Map.keys(state.pr_watch) do
      [url] ->
        {:ok, url}

      [] ->
        {:error, {:pr_not_watched, nil}}

      _many ->
        case for({url, %{watching: true}} <- state.pr_watch, do: url) do
          [url] -> {:ok, url}
          _none_or_many -> {:error, {:pr_url_required, run_id}}
        end
    end
  end

  # -- observations ----------------------------------------------------------

  defp do_handle("run.pr.checks", state, run_id, pr_url, payload) do
    with {:ok, ids} <- identity(state, payload),
         {:ok, head_sha} <-
           Aggregate.required_binary(Aggregate.get(payload, :head_sha), :head_sha),
         {:ok, digest} <- Aggregate.required_binary(Aggregate.get(payload, :digest), :digest),
         {:ok, checks_state} <-
           one_of(Aggregate.get(payload, :checks_state), @checks_states, :checks_state) do
      event("run.pr.checks", run_id, pr_url, payload, ids, %{
        head_sha: head_sha,
        digest: digest,
        checks_state: checks_state
      })
    end
  end

  defp do_handle("run.pr.review", state, run_id, pr_url, payload) do
    with {:ok, ids} <- identity(state, payload),
         {:ok, head_sha} <-
           Aggregate.required_binary(Aggregate.get(payload, :head_sha), :head_sha),
         {:ok, digest} <- Aggregate.required_binary(Aggregate.get(payload, :digest), :digest),
         {:ok, decision} <-
           one_of(Aggregate.get(payload, :review_decision), @review_decisions, :review_decision) do
      event("run.pr.review", run_id, pr_url, payload, ids, %{
        head_sha: head_sha,
        digest: digest,
        review_decision: decision
      })
    end
  end

  # -- fix threads -------------------------------------------------------------

  defp do_handle(type, state, run_id, pr_url, payload) when is_map_key(@kinds, type) do
    kind = Map.fetch!(@kinds, type)
    trigger = Aggregate.get(payload, :trigger) || "operator"
    auto? = trigger in ["auto", "coordinator"]
    force? = Aggregate.get(payload, :force) == true and not auto?

    with {:ok, ids} <- identity(state, payload),
         {:ok, _trigger} <- one_of(trigger, ["operator", "auto", "coordinator"], :trigger),
         {:ok, note} <- note(Aggregate.get(payload, :note)),
         {:ok, record} <- watched_open(state, pr_url),
         fixes = Map.get(state.pr_fixes, pr_url, new_fixes()),
         :ok <- no_fix_in_flight(fixes, pr_url),
         :ok <- not_exhausted(fixes, kind, record.head_sha, force?),
         {:ok, cap} <- cap(payload, auto?),
         :ok <- under_cap(fixes, kind, cap, force?),
         :ok <- made_progress(fixes, kind, record.head_sha, auto?),
         :ok <- cooled_down(fixes, kind, payload, auto?) do
      attempt = Map.get(fixes.attempts, kind, 0) + 1

      event(type, run_id, pr_url, payload, ids, %{
        kind: kind,
        attempt: attempt,
        trigger: trigger,
        head_sha: record.head_sha,
        note: note,
        requested_at: Aggregate.get(payload, :requested_at) || System.system_time(:millisecond)
      })
    end
  end

  defp do_handle("run.pr.fix_started", state, run_id, pr_url, payload) do
    fixes = Map.get(state.pr_fixes, pr_url, new_fixes())

    with {:ok, ids} <- identity(state, payload),
         {:ok, jobsite_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         :ok <- fix_requested(fixes, pr_url) do
      event("run.pr.fix_started", run_id, pr_url, payload, ids, %{
        kind: fixes.in_flight_kind,
        attempt: fixes.in_flight_attempt,
        jobsite_id: jobsite_id,
        started_at: Aggregate.get(payload, :started_at) || System.system_time(:millisecond)
      })
    end
  end

  defp do_handle("run.pr.fix_finished", state, run_id, pr_url, payload) do
    fixes = Map.get(state.pr_fixes, pr_url, new_fixes())

    with {:ok, ids} <- identity(state, payload),
         {:ok, outcome} <- one_of(Aggregate.get(payload, :outcome), @outcomes, :outcome),
         :ok <- fix_in_flight(fixes, pr_url) do
      event("run.pr.fix_finished", run_id, pr_url, payload, ids, %{
        kind: fixes.in_flight_kind,
        attempt: fixes.in_flight_attempt,
        outcome: outcome,
        jobsite_id: if(is_binary(fixes.in_flight), do: fixes.in_flight),
        finished_at: Aggregate.get(payload, :finished_at) || System.system_time(:millisecond)
      })
    end
  end

  defp do_handle("run.pr.fix_exhausted", state, run_id, pr_url, payload) do
    fixes = Map.get(state.pr_fixes, pr_url, new_fixes())

    with {:ok, ids} <- identity(state, payload),
         {:ok, kind} <- one_of(Aggregate.get(payload, :kind), kinds(), :kind),
         {:ok, reason} <- one_of(Aggregate.get(payload, :reason), @exhaust_reasons, :reason),
         {:ok, head_sha} <-
           Aggregate.required_binary(Aggregate.get(payload, :head_sha), :head_sha) do
      if Map.get(fixes.exhausted, kind) == head_sha do
        {:ok, nil}
      else
        event("run.pr.fix_exhausted", run_id, pr_url, payload, ids, %{
          kind: kind,
          reason: reason,
          head_sha: head_sha,
          attempts: Map.get(fixes.attempts, kind, 0),
          exhausted_at: Aggregate.get(payload, :exhausted_at) || System.system_time(:millisecond)
        })
      end
    end
  end

  # -- watch lifecycle ---------------------------------------------------------

  defp do_handle("run.pr.watch_stop", state, run_id, pr_url, payload) do
    with {:ok, ids} <- identity(state, payload),
         {:ok, reason} <-
           one_of(Aggregate.get(payload, :reason) || "operator", @watch_stop_reasons, :reason) do
      case Map.get(state.pr_watch, pr_url) do
        nil ->
          {:error, {:pr_not_watched, pr_url}}

        %{watching: false} ->
          {:ok, nil}

        _record ->
          event("run.pr.watch_stop", run_id, pr_url, payload, ids, %{
            reason: reason,
            stopped_by: Aggregate.get(payload, :stopped_by),
            stopped_at: Aggregate.get(payload, :stopped_at) || System.system_time(:millisecond)
          })
      end
    end
  end

  defp do_handle("run.pr.watch_start", state, run_id, pr_url, payload) do
    with {:ok, ids} <- identity(state, payload),
         {:ok, reason} <-
           one_of(Aggregate.get(payload, :reason) || "operator", @watch_start_reasons, :reason) do
      case Map.get(state.pr_watch, pr_url) do
        nil ->
          {:error, {:pr_not_watched, pr_url}}

        %{watching: true} ->
          {:ok, nil}

        _record ->
          event("run.pr.watch_start", run_id, pr_url, payload, ids, %{
            reason: reason,
            started_by: Aggregate.get(payload, :started_by),
            started_at: Aggregate.get(payload, :started_at) || System.system_time(:millisecond)
          })
      end
    end
  end

  defp do_handle("run.pr.create", state, run_id, pr_url, payload) do
    with {:ok, ids} <- identity(state, payload),
         {:ok, head} <-
           Aggregate.required_binary(Aggregate.get(payload, :head_branch), :head_branch),
         {:ok, base} <-
           Aggregate.required_binary(Aggregate.get(payload, :base_branch), :base_branch) do
      event("run.pr.create", run_id, pr_url, payload, ids, %{
        head_branch: head,
        base_branch: base,
        created_by: Aggregate.get(payload, :created_by),
        created_at: Aggregate.get(payload, :created_at) || System.system_time(:millisecond)
      })
    end
  end

  # -- shared helpers ----------------------------------------------------------

  # project_id / task_id default to the run's own; a payload that names others is
  # rejected so a caller cannot file a PR fact under a different project.
  defp identity(state, payload) do
    with {:ok, project_id} <-
           same(state.project_id, Aggregate.get(payload, :project_id), :project_id),
         {:ok, task_id} <- same(state.task_id, Aggregate.get(payload, :task_id), :task_id) do
      {:ok,
       %{project_id: project_id, task_id: task_id, repo_id: Aggregate.get(payload, :repo_id)}}
    end
  end

  defp same(own, nil, key), do: Aggregate.required_binary(own, key)
  defp same(own, given, _key) when is_binary(own) and own == given, do: {:ok, own}
  defp same(nil, given, key), do: Aggregate.required_binary(given, key)
  defp same(_own, _given, key), do: {:error, {:missing_or_invalid, key}}

  defp one_of(value, allowed, key) do
    if value in allowed, do: {:ok, value}, else: {:error, {:missing_or_invalid, key}}
  end

  defp note(nil), do: {:ok, nil}

  defp note(note) when is_binary(note) do
    if String.valid?(note) and String.length(note) <= @max_note,
      do: {:ok, note},
      else: {:error, {:invalid_note, @max_note}}
  end

  defp note(_other), do: {:error, {:invalid_note, @max_note}}

  defp watched_open(state, pr_url) do
    case Map.get(state.pr_watch, pr_url) do
      %{watching: true, status: status} = record when status in @open_statuses -> {:ok, record}
      %{watching: true, status: status} -> {:error, {:pr_not_open, status}}
      _unwatched -> {:error, {:pr_not_watched, pr_url}}
    end
  end

  defp no_fix_in_flight(%{in_flight: nil}, _pr_url), do: :ok
  defp no_fix_in_flight(_fixes, pr_url), do: {:error, {:fix_in_flight, pr_url}}

  defp fix_requested(%{in_flight: :requested}, _pr_url), do: :ok

  defp fix_requested(%{in_flight: jobsite_id}, pr_url) when is_binary(jobsite_id),
    do: {:error, {:fix_already_started, pr_url, jobsite_id}}

  defp fix_requested(_fixes, pr_url), do: {:error, {:no_fix_requested, pr_url}}

  defp fix_in_flight(%{in_flight: nil}, pr_url), do: {:error, {:no_fix_in_flight, pr_url}}
  defp fix_in_flight(_fixes, _pr_url), do: :ok

  defp not_exhausted(_fixes, _kind, _head, true), do: :ok

  defp not_exhausted(fixes, kind, head_sha, false) do
    if Map.get(fixes.exhausted, kind) == head_sha, do: {:error, {:fix_exhausted, kind}}, else: :ok
  end

  defp cap(_payload, false), do: {:ok, @hard_cap}

  defp cap(payload, true) do
    case Aggregate.get(payload, :max_attempts) do
      nil -> {:ok, @default_auto_cap}
      n when is_integer(n) and n in 1..@hard_cap -> {:ok, n}
      other -> {:error, {:invalid_integer, :max_attempts, other}}
    end
  end

  defp under_cap(fixes, kind, cap, force?) do
    attempts = Map.get(fixes.attempts, kind, 0)

    cond do
      attempts >= @hard_cap -> {:error, {:fix_attempts_exhausted, kind, @hard_cap}}
      force? -> :ok
      attempts >= cap -> {:error, {:fix_attempts_exhausted, kind, cap}}
      true -> :ok
    end
  end

  # Automatic only: a fix that produced no new commit must not be retried on the
  # same head. (An operator may still ask again; the hard cap bounds that.)
  defp made_progress(fixes, kind, head_sha, true) do
    if Map.get(fixes.last_outcome, kind) == "no_change" and fixes.last_fix_head_sha == head_sha,
      do: {:error, {:fix_no_progress, kind}},
      else: :ok
  end

  defp made_progress(_fixes, _kind, _head, false), do: :ok

  defp cooled_down(fixes, _kind, payload, true) do
    with {:ok, cooldown_s} <- cooldown_seconds(Aggregate.get(payload, :cooldown_seconds)) do
      cooldown_ms = cooldown_s * 1000

      if cooldown_ms == 0 do
        :ok
      else
        case Aggregate.get(payload, :requested_at) do
          now when is_integer(now) ->
            if is_integer(fixes.last_finished_at) and now - fixes.last_finished_at < cooldown_ms,
              do: {:error, {:fix_cooling_down, fixes.last_finished_at + cooldown_ms}},
              else: :ok

          other ->
            {:error, {:invalid_integer, :requested_at, other}}
        end
      end
    end
  end

  defp cooled_down(_fixes, _kind, _payload, false), do: :ok

  defp cooldown_seconds(nil), do: {:ok, 0}
  defp cooldown_seconds(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp cooldown_seconds(other), do: {:error, {:invalid_integer, :cooldown_seconds, other}}

  @passthrough ~w(observed_at observation_seq failing branch_name base_branch pr_status
                  comment_ids thread_ids new_comment_count requested_by resumed_session
                  error_code new_head_sha stopped_by started_by)a

  defp event(type, run_id, pr_url, payload, ids, extra) do
    base =
      Enum.reduce(@passthrough, %{}, fn key, acc ->
        case Aggregate.get(payload, key) do
          nil -> acc
          value -> Map.put(acc, key, value)
        end
      end)

    event_type = Map.fetch!(@events, type)
    allowed = event_fields(event_type)

    {:ok,
     %{
       stream_id: "run:#{run_id}",
       event_type: event_type,
       payload:
         base
         |> Map.merge(ids)
         |> Map.merge(extra)
         |> Map.put(:run_id, run_id)
         |> Map.put(:pr_url, pr_url)
         |> Map.take(allowed)
     }}
  end

  # The events are strictly decoded, so a payload carries only declared fields.
  defp event_fields(event_type) do
    module = Module.safe_concat(ForemanServer.Events, event_type)
    module |> struct() |> Map.from_struct() |> Map.keys()
  end

  # -- state -------------------------------------------------------------------

  @doc "Empty per-PR fix bookkeeping."
  @spec new_fixes() :: map()
  def new_fixes do
    %{
      attempts: %{},
      in_flight: nil,
      in_flight_kind: nil,
      in_flight_attempt: nil,
      in_flight_head_sha: nil,
      last_fix_head_sha: nil,
      last_outcome: %{},
      last_finished_at: nil,
      exhausted: %{}
    }
  end

  @doc """
  Fold an E9 event into `state`. Unknown event types and unrelated payloads
  return `state` unchanged.
  """
  @spec apply_event(struct(), String.t(), map()) :: struct()
  def apply_event(state, type, payload) do
    case Aggregate.get(payload, :pr_url) do
      url when is_binary(url) and url != "" -> fold(state, type, url, payload)
      _none -> state
    end
  end

  defp fold(state, type, url, payload) when type in ["PrUpdated", "PrReady"] do
    watch(state, url, fn rec ->
      rec
      |> put_present(:status, status_of(type, payload))
      |> put_present(:head_sha, Aggregate.get(payload, :head_sha))
      |> put_present(:base_branch, Aggregate.get(payload, :base_branch))
    end)
  end

  defp fold(state, "PrMerged", url, _payload),
    do: watch(state, url, fn rec -> %{rec | status: "merged"} end)

  defp fold(state, "PrChecksChanged", url, payload) do
    watch(state, url, fn rec ->
      rec
      |> put_present(:status, Aggregate.get(payload, :pr_status))
      |> Map.put(:head_sha, Aggregate.get(payload, :head_sha) || rec.head_sha)
      |> Map.put(:checks_state, Aggregate.get(payload, :checks_state))
      |> Map.put(:checks_digest, Aggregate.get(payload, :digest))
    end)
  end

  defp fold(state, "PrReviewChanged", url, payload) do
    watch(state, url, fn rec ->
      rec
      |> put_present(:status, Aggregate.get(payload, :pr_status))
      |> Map.put(:head_sha, Aggregate.get(payload, :head_sha) || rec.head_sha)
      |> Map.put(:review_decision, Aggregate.get(payload, :review_decision))
      |> Map.put(:review_digest, Aggregate.get(payload, :digest))
    end)
  end

  defp fold(state, "PrWatchStopped", url, _payload),
    do: watch(state, url, fn rec -> %{rec | watching: false} end)

  defp fold(state, "PrWatchStarted", url, _payload),
    do: watch(state, url, fn rec -> %{rec | watching: true} end)

  defp fold(state, "PrFixRequested", url, payload) do
    kind = Aggregate.get(payload, :kind)
    attempt = Aggregate.get(payload, :attempt)

    fixes(state, url, fn fx ->
      %{
        fx
        | attempts: Map.put(fx.attempts, kind, attempt),
          in_flight: :requested,
          in_flight_kind: kind,
          in_flight_attempt: attempt,
          in_flight_head_sha: Aggregate.get(payload, :head_sha)
      }
    end)
  end

  defp fold(state, "PrFixStarted", url, payload) do
    fixes(state, url, fn fx -> %{fx | in_flight: Aggregate.get(payload, :jobsite_id)} end)
  end

  defp fold(state, "PrFixFinished", url, payload) do
    kind = Aggregate.get(payload, :kind)

    fixes(state, url, fn fx ->
      %{
        fx
        | in_flight: nil,
          in_flight_kind: nil,
          in_flight_attempt: nil,
          in_flight_head_sha: nil,
          last_outcome: Map.put(fx.last_outcome, kind, Aggregate.get(payload, :outcome)),
          last_finished_at: Aggregate.get(payload, :finished_at),
          # A fix that changed nothing leaves the head where the request saw it: the
          # next automatic attempt on that same head is refused (no progress).
          last_fix_head_sha:
            Aggregate.get(payload, :new_head_sha) || fx.in_flight_head_sha || fx.last_fix_head_sha
      }
    end)
  end

  defp fold(state, "PrFixExhausted", url, payload) do
    kind = Aggregate.get(payload, :kind)

    fixes(state, url, fn fx ->
      %{fx | exhausted: Map.put(fx.exhausted, kind, Aggregate.get(payload, :head_sha))}
    end)
  end

  defp fold(state, _type, _url, _payload), do: state

  defp status_of("PrReady", _payload), do: "open"

  defp status_of("PrUpdated", payload) do
    case Aggregate.get(payload, :pr_status) do
      status when is_atom(status) and not is_nil(status) -> Atom.to_string(status)
      status -> status
    end
  end

  defp watch(state, url, fun) do
    rec = Map.get(state.pr_watch, url, new_record())
    %{state | pr_watch: Map.put(state.pr_watch, url, fun.(rec))}
  end

  defp fixes(state, url, fun) do
    fx = Map.get(state.pr_fixes, url, new_fixes())
    %{state | pr_fixes: Map.put(state.pr_fixes, url, fun.(fx))}
  end

  defp new_record do
    %{
      status: nil,
      head_sha: nil,
      base_branch: nil,
      checks_state: nil,
      checks_digest: nil,
      review_digest: nil,
      review_decision: nil,
      watching: true
    }
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
