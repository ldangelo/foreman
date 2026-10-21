defmodule ForemanServer.Coordinator.Context do
  @moduledoc """
  The bounded prompt a coordinator turn is given. The coordinator never sees the
  full conversation history: it gets the instructions, the recent messages, the
  project's thread cards, a memory index, the limits in force and the vocabulary,
  within a token budget (spike S1: 12k input tokens).

  Render order puts the stable prefix first so provider prompt caches hit, and
  the volatile parts last:

      SYSTEM -> WORKFLOWS -> PROJECT -> MEMORY -> THREADS -> LIMITS
             -> ACTIONS -> RECENT MESSAGES -> NEW MESSAGE(S)

  When the render is over `max_total_tokens` (estimated as bytes / 4) it is cut
  in the order decided by S1 section 6, one item at a time, and every cut is
  announced in the text:

    1. thread cards: resolved, then idle, oldest first
    2. older recent messages, down to the last `min_messages`
    3. memory index lines, oldest first (headers kept)
    4. working / ready cards collapse to `id | state | title`

  Never cut: the system skeleton, waiting-on-you and ready-for-review cards,
  the new message(s), the project instructions. All third-party text (messages,
  reports, thread titles, memory) is wrapped by `Coordinator.Untrusted`.
  """

  alias ForemanServer.Coordinator.{Conversation, Error, Untrusted}
  alias ForemanServer.Coordinator.Context.Sources.Live
  alias ForemanServer.Threads.Thread

  @enforce_keys [:project_id, :text, :trigger_key, :trigger_messages]
  @type t :: %__MODULE__{
          project_id: String.t(),
          text: String.t(),
          estimated_tokens: non_neg_integer(),
          trigger_key: String.t(),
          trigger_messages: [Conversation.message()],
          omitted_message_count: non_neg_integer(),
          truncations: [String.t()],
          over_budget?: boolean()
        }
  defstruct [
    :project_id,
    :text,
    :trigger_key,
    trigger_messages: [],
    estimated_tokens: 0,
    omitted_message_count: 0,
    truncations: [],
    over_budget?: false
  ]

  @defaults [
    max_total_tokens: 12_000,
    max_messages: 20,
    min_messages: 6,
    max_cards: 100,
    max_memory_lines: 100,
    max_history_message_bytes: 1_500,
    max_recent_actions: 12
  ]

  @system_prompt_file "coordinator/system_prompt.md"

  @doc "Defaults merged with `config :foreman_server, :coordinator, context: [...]`."
  @spec config() :: keyword()
  def config do
    configured =
      :foreman_server |> Application.get_env(:coordinator, []) |> Keyword.get(:context, [])

    Keyword.merge(@defaults, configured)
  end

  @doc """
  Build the context for `project_id`. Options: `:sources` (module, default
  `Sources.Live`), `:trigger_messages` (default: the conversation's pending
  trigger messages), plus any `config/0` key as an override.
  """
  @spec build(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def build(project_id, opts \\ []) when is_binary(project_id) do
    sources = Keyword.get(opts, :sources, Live)
    cfg = Keyword.merge(config(), Keyword.take(opts, Keyword.keys(@defaults)))

    with {:ok, conv} <- fetch(sources.conversation(project_id), project_id),
         {:ok, project} <- fetch(sources.project(project_id), project_id),
         triggers =
           Keyword.get_lazy(opts, :trigger_messages, fn -> Conversation.pending(conv) end),
         [first | _] <- triggers do
      model = %{
        project_id: project_id,
        project: project,
        conv: conv,
        triggers: triggers,
        cards: order_cards(sources.threads(project_id)),
        workflows: sources.workflows(),
        tuning: sources.tuning(project_id),
        limits: sources.limits(project_id),
        history: history(conv, first.seq),
        actions: recent_actions(conv, first, cfg),
        memory_lines: memory_lines(project.memory_index)
      }

      {:ok, fit(model, cfg)}
    else
      [] ->
        {:error,
         Error.new(:context_failed, "no trigger messages to answer", %{project_id: project_id})}

      {:error, %Error{}} = error ->
        error
    end
  rescue
    exception ->
      {:error,
       Error.new(:context_failed, "could not build coordinator context", %{
         reason: Exception.message(exception)
       })}
  end

  @doc "Estimated tokens of `text` (bytes / 4, rounded up)."
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  def estimate_tokens(text), do: div(byte_size(text) + 3, 4)

  @doc "Card state of a thread: `:waiting_on_you | :ready_for_review | :working | :idle | :resolved`."
  @spec card_state(Thread.t()) ::
          :waiting_on_you | :ready_for_review | :working | :idle | :resolved
  def card_state(%Thread{resolved: true}), do: :resolved

  def card_state(%Thread{status: status})
      when status in ~w(blocked stuck needs_recovery paused failed cancelled), do: :waiting_on_you

  def card_state(%Thread{last_report: %{verdict: _}}), do: :ready_for_review
  def card_state(%Thread{status: "completed"}), do: :ready_for_review

  def card_state(%Thread{status: status})
      when status in ~w(in_progress awaiting_worker starting running), do: :working

  def card_state(%Thread{}), do: :idle

  # ------------------------------------------------------------------ model

  defp fetch({:ok, value}, _project_id), do: {:ok, value}

  defp fetch({:error, :project_not_found}, project_id),
    do: {:error, Error.new(:context_failed, "project not found", %{project_id: project_id})}

  # Newest first within a state; cut order below walks resolved then idle from the end (oldest).
  defp order_cards(threads) do
    Enum.map(threads, fn thread ->
      %{thread: thread, state: card_state(thread), collapsed?: false}
    end)
  end

  defp history(conv, before_seq), do: Enum.filter(conv.messages, &(&1.seq < before_seq))

  defp recent_actions(conv, first, cfg) do
    started =
      conv.turns
      |> Map.values()
      |> Enum.filter(&(first.message_id in (&1.trigger_message_ids || [])))

    this_request = MapSet.new(started, & &1.turn_id)

    conv.action_order
    |> Enum.take(cfg[:max_recent_actions])
    |> Enum.map(&Map.fetch!(conv.actions, &1))
    |> Enum.reverse()
    |> Enum.map(fn action -> {MapSet.member?(this_request, action.turn_id), action} end)
  end

  defp memory_lines(nil), do: []
  defp memory_lines(text), do: String.split(text, "\n", trim: true)

  # -------------------------------------------------------------- budgeting

  # State of the cuts: counters the render reads. Each step bumps one counter.
  defp fit(model, cfg) do
    cuts = %{
      dropped_cards: 0,
      history_keep: min(length(model.history), cfg[:max_messages]),
      memory_dropped: 0,
      collapsed: false
    }

    drop_order = drop_order(model.cards)
    cuts = %{cuts | dropped_cards: cap_cards(model.cards, cfg[:max_cards], drop_order)}

    {cuts, text} = shrink(model, cfg, cuts, drop_order)
    tokens = estimate_tokens(text)

    %__MODULE__{
      project_id: model.project_id,
      text: text,
      estimated_tokens: tokens,
      trigger_key: hd(model.triggers).message_id,
      trigger_messages: model.triggers,
      omitted_message_count: length(model.history) - cuts.history_keep,
      truncations: truncations(model, cuts),
      over_budget?: tokens > cfg[:max_total_tokens]
    }
  end

  # Cards cut first: resolved then idle, oldest (last in list) first.
  defp drop_order(cards) do
    resolved = cards |> Enum.filter(&(&1.state == :resolved)) |> Enum.reverse()
    idle = cards |> Enum.filter(&(&1.state == :idle)) |> Enum.reverse()
    Enum.map(resolved ++ idle, & &1.thread.id)
  end

  defp cap_cards(cards, max, drop_order) do
    over = length(cards) - max
    if over > 0, do: min(over, length(drop_order)), else: 0
  end

  defp shrink(model, cfg, cuts, drop_order) do
    text = render(model, cfg, cuts, drop_order)

    cond do
      estimate_tokens(text) <= cfg[:max_total_tokens] ->
        {cuts, text}

      cuts.dropped_cards < length(drop_order) ->
        shrink(model, cfg, %{cuts | dropped_cards: cuts.dropped_cards + 1}, drop_order)

      cuts.history_keep > min(cfg[:min_messages], length(model.history)) ->
        shrink(model, cfg, %{cuts | history_keep: cuts.history_keep - 1}, drop_order)

      cuts.memory_dropped < droppable_memory(model.memory_lines) ->
        shrink(model, cfg, %{cuts | memory_dropped: cuts.memory_dropped + 1}, drop_order)

      not cuts.collapsed ->
        shrink(model, cfg, %{cuts | collapsed: true}, drop_order)

      true ->
        {cuts, text}
    end
  end

  defp droppable_memory(lines), do: Enum.count(lines, &(not header?(&1)))

  defp header?(line), do: String.starts_with?(line, "#")

  defp truncations(model, cuts) do
    [
      cuts.dropped_cards > 0 && "#{cuts.dropped_cards} older thread card(s) omitted",
      length(model.history) - cuts.history_keep > 0 &&
        "#{length(model.history) - cuts.history_keep} older message(s) omitted",
      cuts.memory_dropped > 0 && "#{cuts.memory_dropped} memory index line(s) omitted",
      cuts.collapsed && "working/ready thread cards collapsed"
    ]
    |> Enum.filter(& &1)
  end

  # ----------------------------------------------------------------- render

  defp render(model, cfg, cuts, drop_order) do
    dropped = drop_order |> Enum.take(cuts.dropped_cards) |> MapSet.new()

    [
      system_section(),
      workflows_section(model.workflows),
      project_section(model.project),
      memory_section(model.memory_lines, cuts.memory_dropped),
      threads_section(model.cards, dropped, cuts),
      limits_section(model),
      actions_section(model.actions),
      history_section(model.history, cuts.history_keep, cfg),
      new_section(model.triggers)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp system_section do
    path = Path.join(:code.priv_dir(:foreman_server), @system_prompt_file)
    File.read!(path) <> "\n\n" <> Untrusted.preamble()
  end

  defp workflows_section([]), do: "# WORKFLOWS\n(none installed)"

  defp workflows_section(workflows) do
    lines = Enum.map(workflows, fn w -> "- #{w.name}: #{one_line(w.description)}" end)
    "# WORKFLOWS\n" <> Enum.join(lines, "\n")
  end

  defp project_section(project) do
    head = "# PROJECT #{one_line(project.name)}"
    goal = project.goal && "Goal: #{one_line(project.goal)}"

    instructions =
      project.instructions && "Operator instructions for this project:\n" <> project.instructions

    repos =
      project.repositories != [] && "Repositories: " <> Enum.join(project.repositories, "; ")

    [head, goal, instructions, repos] |> Enum.filter(& &1) |> Enum.join("\n")
  end

  defp memory_section([], _dropped), do: "# MEMORY\n(empty)"

  defp memory_section(lines, dropped) do
    {kept, omitted} = drop_oldest_non_headers(lines, dropped)
    marker = if omitted > 0, do: "\n[#{omitted} older memory line(s) omitted]", else: ""
    "# MEMORY INDEX\n" <> Untrusted.wrap("project_memory", Enum.join(kept, "\n") <> marker)
  end

  defp drop_oldest_non_headers(lines, 0), do: {lines, 0}

  defp drop_oldest_non_headers(lines, count) do
    {kept, omitted} =
      Enum.reduce(lines, {[], count}, fn line, {acc, left} ->
        if left > 0 and not header?(line), do: {acc, left - 1}, else: {[line | acc], left}
      end)

    {Enum.reverse(kept), count - omitted}
  end

  defp threads_section([], _dropped, _cuts), do: "# THREADS\n(none)"

  defp threads_section(cards, dropped, cuts) do
    visible = Enum.reject(cards, &MapSet.member?(dropped, &1.thread.id))
    omitted = length(cards) - length(visible)

    lines =
      Enum.map(visible, fn card ->
        if cuts.collapsed and card.state in [:working, :idle],
          do: collapsed_card(card),
          else: full_card(card)
      end)

    marker = if omitted > 0, do: ["[#{omitted} older thread card(s) omitted]"], else: []

    "# THREADS (id | state | title ...)\n" <>
      Untrusted.wrap("threads", Enum.join(lines ++ marker, "\n"))
  end

  defp collapsed_card(%{thread: t, state: state}), do: "#{t.id} | #{state} | #{one_line(t.title)}"

  defp full_card(%{thread: t, state: state}) do
    extras =
      [
        t.status && "status #{t.status}",
        t.branch && "branch #{t.branch}",
        t.pr_url && "pr #{t.pr_url}",
        t.last_report && "report #{t.last_report.verdict}: #{one_line(t.last_report.summary)}"
      ]
      |> Enum.filter(& &1)
      |> Enum.map(&String.slice(&1, 0, 200))

    Enum.join(["#{t.id} | #{state} | #{one_line(t.title)}" | extras], " | ")
  end

  defp limits_section(model) do
    t = model.tuning
    l = model.limits

    lines = [
      "propose_before_start: #{t.propose_before_start}",
      "max_active_threads: #{t.max_active_threads || "none"}",
      "reuse_threads: #{t.reuse_threads}",
      l[:max_concurrent_runs] &&
        "max_concurrent_runs: #{l.max_concurrent_runs} (active #{l[:active_runs] || 0})",
      l[:daily_thread_cap] &&
        "daily_thread_cap: #{l.daily_thread_cap} (remaining today #{l[:remaining_today]})",
      "active threads now: #{Enum.count(model.cards, &(&1.state in [:working, :waiting_on_you]))}"
    ]

    "# LIMITS\n" <> (lines |> Enum.filter(& &1) |> Enum.join("\n"))
  end

  defp actions_section([]), do: nil

  defp actions_section(actions) do
    lines =
      Enum.map(actions, fn {this_request?, a} ->
        tag = if this_request?, do: "ALREADY TAKEN for this request", else: "earlier"
        ref = if a.result_ref in [nil, %{}], do: "", else: " " <> inspect(a.result_ref, limit: 8)
        reason = if a.reason, do: " (#{String.slice(a.reason, 0, 160)})", else: ""
        "- [#{tag}] #{a.kind} #{a.status}#{reason}#{ref}"
      end)

    "# ACTIONS (do not repeat those already taken)\n" <> Enum.join(lines, "\n")
  end

  defp history_section(_history, 0, _cfg), do: nil

  defp history_section(history, keep, cfg) do
    omitted = length(history) - keep
    recent = Enum.take(history, -keep)

    marker = if omitted > 0, do: "[#{omitted} older message(s) omitted]\n", else: ""

    body =
      Enum.map_join(recent, "\n", fn m ->
        "#{m.role}/#{m.kind}: " <> clip(m.text, cfg[:max_history_message_bytes])
      end)

    "# RECENT MESSAGES (oldest first)\n" <> marker <> Untrusted.wrap("conversation", body)
  end

  defp new_section(triggers) do
    blocks =
      Enum.map(triggers, fn m ->
        Untrusted.wrap("#{m.role}:#{m.source || m.kind}", m.text)
      end)

    "# NEW MESSAGE(S)\n" <> Enum.join(blocks, "\n")
  end

  defp clip(text, max) when byte_size(text) <= max, do: text

  defp clip(text, max) do
    String.slice(text, 0, max) <> " [truncated, #{byte_size(text) - max} more bytes]"
  end

  defp one_line(nil), do: ""

  defp one_line(text) when is_binary(text),
    do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
