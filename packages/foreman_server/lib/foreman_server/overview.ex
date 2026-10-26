defmodule ForemanServer.Overview do
  @moduledoc """
  The operator's single glance at a project: its threads grouped into
  `Overview.Group` buckets, counts, and an attention flag.

  Composes only existing read models: `ForemanServer.Threads` (E6), the PR /
  merge-gate state folded into `ProjectionStore` (`pr_states_for_project/1`),
  review verdicts carried on each thread's `last_report`, and
  `Overview.Signals` (E8 counts, zero until E8 lands). Nothing here dispatches a
  command; **merging stays operator-only** (`merge_approve` -> `run.pr.merge`).

  Cost: every call classifies a project's threads, which is O(threads) plus one
  bulk projection read and one thread build for all projects (`Threads.by_project/0`),
  one bulk read of the project's approval and question counts (`Signals.for_threads/1`:
  one scan of each, whatever the number of threads), and a keyed lookup per paused
  thread (its pending steering) and per thread with a live PR (its PR watch).
  `attention/1` skips card building and sorting but not that pass.
  `project_fields_many/1` shares one thread build across a whole project list.

  Bound: only the newest `Threads.max_limit/0` (500) threads of a project are
  classified. When the project has more, `truncated` is `true` and `counts` /
  `attention` / `groups` omit the older threads (they are the least recently
  updated).

  Options for `build/2`:

    * `:include_resolved` - include resolved cards (default `false`; counts always
      include them)
    * `:resolved_limit` - maximum resolved cards (default 20)
    * `:now_fun` - `() -> integer` ms clock for idle time (default system time)

  Configuration (`config :foreman_server, :overview`): `attention_groups`
  (default `[:waiting_on_you, :ready_for_review]`) - groups that raise the
  attention flag.
  """

  alias ForemanServer.Overview.{Group, Input, Signals, Tabs, ThreadCard}
  alias ForemanServer.{ProjectionStore, Threads}
  alias ForemanServer.Threads.Thread

  @default_resolved_limit 20
  @default_attention_groups [:waiting_on_you, :ready_for_review]

  @type attention :: %{needed: boolean(), count: non_neg_integer(), reasons: [Group.reason()]}
  @type t :: %__MODULE__{
          project_id: String.t(),
          groups: %{Group.group() => [ThreadCard.t()]},
          counts: %{Group.group() => non_neg_integer()},
          attention: attention(),
          truncated: boolean(),
          tabs: Tabs.t(),
          generated_at: integer()
        }
  @enforce_keys [:project_id, :groups, :counts, :attention, :truncated, :tabs, :generated_at]
  defstruct [:project_id, :groups, :counts, :attention, :truncated, :tabs, :generated_at]

  @doc "Default number of resolved cards returned."
  @spec default_resolved_limit() :: pos_integer()
  def default_resolved_limit, do: @default_resolved_limit

  @spec build(String.t(), keyword()) :: {:ok, t()}
  def build(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    now = now(opts)
    %{classified: classified, truncated: truncated} = classify_project(project_id, now)
    include_resolved = Keyword.get(opts, :include_resolved, false)
    resolved_limit = Keyword.get(opts, :resolved_limit, @default_resolved_limit)

    by_group = Enum.group_by(classified, fn {_card_args, {group, _}} -> group end)

    groups =
      Map.new(Group.all(), fn group ->
        cards =
          by_group
          |> Map.get(group, [])
          |> Enum.map(fn {{thread, pr, watch}, classification} ->
            ThreadCard.build(thread, pr, classification, watch)
          end)

        {group, bound(group, cards, include_resolved, resolved_limit)}
      end)

    counts = counts(by_group)

    {:ok,
     %__MODULE__{
       project_id: project_id,
       groups: groups,
       counts: counts,
       attention: attention_from(classified),
       truncated: truncated,
       tabs: Tabs.build(project_id),
       generated_at: now
     }}
  end

  @type summary :: %{
          counts: %{Group.group() => non_neg_integer()},
          attention: attention(),
          truncated: boolean()
        }

  @doc """
  Attention, group counts and the `truncated` bound flag for a project without
  building cards, sorting or reading tabs. Same pass and rules as `build/2`, so
  the two can never disagree.
  """
  @spec summary(String.t(), keyword()) :: summary()
  def summary(project_id, opts \\ []) when is_binary(project_id) do
    project_id |> classify_project(now(opts)) |> summarize()
  end

  @doc """
  `summary/2` for several projects as `%{project_id => summary}`, reading and
  building the threads of all projects once.
  """
  @spec summaries([String.t()], keyword()) :: %{String.t() => summary()}
  def summaries(project_ids, opts \\ []) when is_list(project_ids) do
    by_project = Threads.by_project()
    now = now(opts)

    Map.new(project_ids, fn project_id ->
      {project_id,
       project_id |> classify_threads(Map.get(by_project, project_id, []), now) |> summarize()}
    end)
  end

  defp summarize(%{classified: classified, truncated: truncated}) do
    by_group = Enum.group_by(classified, fn {_card_args, {group, _}} -> group end)
    %{counts: counts(by_group), attention: attention_from(classified), truncated: truncated}
  end

  @doc "Attention for a project (see `summary/2`)."
  @spec attention(String.t(), keyword()) :: attention()
  def attention(project_id, opts \\ []) when is_binary(project_id) do
    summary(project_id, opts).attention
  end

  @type project_fields :: %{attention: map(), attention_count: non_neg_integer()}

  @doc """
  The `attention` / `attention_count` fields added to a project payload. An
  archived project never needs attention. Keys are atoms; the attention value is
  the string-keyed DTO.
  """
  @spec project_fields(map()) :: project_fields()
  def project_fields(project) when is_map(project), do: hd(project_fields_many([project]))

  @doc """
  `project_fields/1` for a list of projects (same order), reading and building
  the threads of all projects once instead of once per project.
  """
  @spec project_fields_many([map()]) :: [project_fields()]
  def project_fields_many(projects) when is_list(projects) do
    by_project =
      if Enum.any?(projects, &attention_project_id/1), do: Threads.by_project(), else: %{}

    now = now([])

    Enum.map(projects, fn project ->
      attention =
        case attention_project_id(project) do
          nil ->
            %{needed: false, count: 0, reasons: []}

          project_id ->
            %{classified: classified} =
              classify_threads(project_id, Map.get(by_project, project_id, []), now)

            attention_from(classified)
        end

      %{attention: attention_dto(attention), attention_count: attention.count}
    end)
  end

  # An archived project, or one without a binary id, never needs attention.
  defp attention_project_id(project) do
    if Map.get(project, :archived?) != true and is_binary(project[:project_id]),
      do: project[:project_id]
  end

  defp counts(by_group) do
    Map.new(Group.all(), fn g -> {g, by_group |> Map.get(g, []) |> length()} end)
  end

  @doc """
  Groups that raise the attention flag. Raises `ArgumentError` when the
  configured list names a group `Overview.Group` does not define: a typo would
  otherwise silently report "no attention needed" for every project.
  """
  @spec attention_groups() :: [Group.group()]
  def attention_groups do
    groups =
      Application.get_env(:foreman_server, :overview, [])
      |> Keyword.get(:attention_groups, @default_attention_groups)

    case Enum.reject(groups, &(&1 in Group.all())) do
      [] ->
        groups

      unknown ->
        raise ArgumentError,
              "config :foreman_server, :overview, attention_groups has unknown groups " <>
                "#{inspect(unknown)}; valid groups: #{inspect(Group.all())}"
    end
  end

  defp bound(:resolved, _cards, false, _limit), do: []
  defp bound(:resolved, cards, true, limit), do: Enum.take(cards, limit)
  defp bound(_group, cards, _include_resolved, _limit), do: cards

  defp attention_from(classified) do
    groups = attention_groups()

    attending =
      for {_args, {group, reason}} <- classified, group in groups, do: reason

    %{
      needed: attending != [],
      count: length(attending),
      reasons: attending |> Enum.uniq() |> Enum.sort()
    }
  end

  defp classify_project(project_id, now) do
    classify_threads(project_id, Map.get(Threads.by_project(), project_id, []), now)
  end

  # `threads` arrive newest-first (`Threads.by_project/0`), so each group keeps
  # `updated_at desc` order; only the newest `Threads.max_limit/0` are classified.
  defp classify_threads(project_id, threads, now) do
    pr_states = ProjectionStore.pr_states_for_project(project_id)
    {window, rest} = Enum.split(threads, Threads.max_limit())
    signals = Signals.for_threads(window)

    classified =
      Enum.map(window, fn %Thread{} = thread ->
        pr = Map.get(pr_states, head_run_id(thread))
        watch = watch_records(thread, pr)
        input = input(thread, pr, watch, Map.fetch!(signals, thread.id), now)
        {{thread, pr, watch}, Group.classify(input)}
      end)

    %{classified: classified, truncated: rest != []}
  end

  defp input(%Thread{} = thread, pr, watch, signals, now) do
    %Input{
      door: thread.door,
      status: thread.status,
      resolved?: thread.resolved,
      pr_state: pr && pr.pr_state,
      merge_gate: (pr && pr.merge_gate) || :none,
      checks_state: checks_state(watch),
      review_state: review_state(watch),
      pending_approvals: signals.pending_approvals,
      open_questions: signals.open_questions,
      expired_approvals: signals.expired_approvals,
      expired_questions: signals.expired_questions,
      failed_approval_deliveries: signals.failed_approval_deliveries,
      failure_reason: pr && pr.failure_reason,
      review_verdict: thread.last_report && thread.last_report.verdict,
      paused_reason: paused_reason(thread),
      idle_ms: max(now - (thread.updated_at || now), 0)
    }
  end

  # The E9 PR watch fold (`PrChecksChanged` et al.) of the head run, read only
  # while its PR is still live (open or conflicted): that is all CI state and the
  # PR action buttons need, and it keeps merged/closed/no-PR threads free of the call.
  defp watch_records(%Thread{door: :workflow, run_ids: [run_id | _]}, %{pr_state: state})
       when state in [:open, :conflicted],
       do: ProjectionStore.pr_watch(run_id)

  defp watch_records(_thread, _pr), do: []

  # A failing rollup on any still-live watched PR of the head run counts.
  defp checks_state(watch) do
    if Enum.any?(
         watch,
         &(&1.status not in ["merged", "closed"] and &1.checks_state == "failing")
       ),
       do: :failing,
       else: :none
  end

  # An outstanding CHANGES_REQUESTED review, else an unresolved review thread, on
  # any still-live watched PR of the head run. This is the same predicate as
  # `PrWatcher.AutoFix`'s `comments` trigger; conversation comments are left out
  # because they have no resolved state and could never clear.
  defp review_state(watch) do
    live = Enum.filter(watch, &(&1.status not in ["merged", "closed"]))

    cond do
      Enum.any?(live, &(&1.review_decision == "changes_requested")) -> :changes_requested
      Enum.any?(live, &(&1.thread_ids != [])) -> :threads_unresolved
      true -> :none
    end
  end

  # The newest run of a workflow thread owns its PR state; jobsites have none.
  defp head_run_id(%Thread{door: :workflow, run_ids: [run_id | _]}), do: run_id
  defp head_run_id(_thread), do: nil

  # A pause that only holds an operator steer message is not the operator's
  # decision to make: it resumes by itself.
  defp paused_reason(%Thread{door: :workflow, status: "paused", run_ids: [run_id | _]}) do
    if ProjectionStore.pending_steering(run_id) != [], do: "steer"
  end

  defp paused_reason(_thread), do: nil

  defp now(opts) do
    case Keyword.get(opts, :now_fun) do
      fun when is_function(fun, 0) -> fun.()
      nil -> System.os_time(:millisecond)
    end
  end

  @doc "String-keyed whitelisted DTO shared by HTTP and MCP."
  @spec to_dto(t()) :: %{String.t() => term()}
  def to_dto(%__MODULE__{} = overview) do
    %{
      "project_id" => overview.project_id,
      "groups" =>
        Map.new(Group.all(), fn group ->
          {Atom.to_string(group), Enum.map(overview.groups[group], &ThreadCard.to_dto/1)}
        end),
      "counts" => Map.new(overview.counts, fn {g, n} -> {Atom.to_string(g), n} end),
      "attention" => attention_dto(overview.attention),
      "truncated" => overview.truncated,
      "tabs" => Tabs.to_dto(overview.tabs),
      "generated_at" =>
        DateTime.to_iso8601(DateTime.from_unix!(overview.generated_at, :millisecond))
    }
  end

  @doc "String-keyed attention DTO."
  @spec attention_dto(attention()) :: %{String.t() => term()}
  def attention_dto(%{needed: needed, count: count, reasons: reasons}) do
    %{"needed" => needed, "count" => count, "reasons" => Enum.map(reasons, &Atom.to_string/1)}
  end
end
