defmodule ForemanServer.Overview do
  @moduledoc """
  The operator's single glance at a project: its threads grouped into
  `Overview.Group` buckets, counts, and an attention flag.

  Composes only existing read models: `ForemanServer.Threads` (E6), the PR /
  merge-gate state folded into `ProjectionStore` (`pr_states_for_project/1`),
  review verdicts carried on each thread's `last_report`, and
  `Overview.Signals` (E8 counts, zero until E8 lands). Nothing here dispatches a
  command; **merging stays operator-only** (`merge_approve` -> `run.pr.merge`).

  Cost: every call classifies all of a project's threads (at most
  `Threads.max_limit/0`), which is O(threads) plus one bulk projection read.
  `attention/1` skips card building and sorting but not that pass.

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
          tabs: Tabs.t(),
          generated_at: integer()
        }
  @enforce_keys [:project_id, :groups, :counts, :attention, :tabs, :generated_at]
  defstruct [:project_id, :groups, :counts, :attention, :tabs, :generated_at]

  @doc "Default number of resolved cards returned."
  @spec default_resolved_limit() :: pos_integer()
  def default_resolved_limit, do: @default_resolved_limit

  @spec build(String.t(), keyword()) :: {:ok, t()}
  def build(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    now = now(opts)
    classified = classify_all(project_id, now)
    include_resolved = Keyword.get(opts, :include_resolved, false)
    resolved_limit = Keyword.get(opts, :resolved_limit, @default_resolved_limit)

    by_group = Enum.group_by(classified, fn {_card_args, {group, _}} -> group end)

    groups =
      Map.new(Group.all(), fn group ->
        cards =
          by_group
          |> Map.get(group, [])
          |> Enum.map(fn {{thread, pr}, classification} ->
            ThreadCard.build(thread, pr, classification)
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
       tabs: Tabs.build(project_id),
       generated_at: now
     }}
  end

  @doc """
  Attention and group counts for a project without building cards, sorting or
  reading tabs. Same pass and rules as `build/2`, so the two can never disagree.
  """
  @spec summary(String.t(), keyword()) :: %{
          counts: %{Group.group() => non_neg_integer()},
          attention: attention()
        }
  def summary(project_id, opts \\ []) when is_binary(project_id) do
    classified = classify_all(project_id, now(opts))

    by_group = Enum.group_by(classified, fn {_card_args, {group, _}} -> group end)
    %{counts: counts(by_group), attention: attention_from(classified)}
  end

  @doc "Attention for a project (see `summary/2`)."
  @spec attention(String.t(), keyword()) :: attention()
  def attention(project_id, opts \\ []) when is_binary(project_id) do
    summary(project_id, opts).attention
  end

  @doc """
  The `attention` / `attention_count` fields added to a project payload. An
  archived project never needs attention. Keys are atoms; the attention value is
  the string-keyed DTO.
  """
  @spec project_fields(map()) :: %{attention: map(), attention_count: non_neg_integer()}
  def project_fields(project) when is_map(project) do
    attention =
      cond do
        archived?(project) -> %{needed: false, count: 0, reasons: []}
        is_binary(project[:project_id]) -> attention(project[:project_id])
        true -> %{needed: false, count: 0, reasons: []}
      end

    %{attention: attention_dto(attention), attention_count: attention.count}
  end

  defp archived?(project), do: Map.get(project, :archived?) == true

  defp counts(by_group) do
    Map.new(Group.all(), fn g -> {g, by_group |> Map.get(g, []) |> length()} end)
  end

  @doc "Groups that raise the attention flag."
  @spec attention_groups() :: [Group.group()]
  def attention_groups do
    Application.get_env(:foreman_server, :overview, [])
    |> Keyword.get(:attention_groups, @default_attention_groups)
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

  # Threads arrive newest-first from Threads.list, so each group keeps
  # `updated_at desc` order.
  defp classify_all(project_id, now) do
    pr_states = ProjectionStore.pr_states_for_project(project_id)

    project_id
    |> Threads.list(limit: Threads.max_limit())
    |> Enum.map(fn %Thread{} = thread ->
      pr = Map.get(pr_states, head_run_id(thread))
      {{thread, pr}, Group.classify(input(thread, pr, now))}
    end)
  end

  defp input(%Thread{} = thread, pr, now) do
    signals = Signals.for_thread(thread)

    %Input{
      door: thread.door,
      status: thread.status,
      resolved?: thread.resolved,
      pr_state: pr && pr.pr_state,
      merge_gate: (pr && pr.merge_gate) || :none,
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
