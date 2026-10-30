defmodule ForemanServer.Threads.Transcript do
  @moduledoc """
  Structured, cursor-paged transcript of a thread (`ForemanServer.Threads.Turn`).

  `build_turns/1` is pure; `page/2` gathers projection data and slices the
  result by cursor. Both doors are supported.

  ## Sources

  Workflow door (`run:<id>`)

    * `WorkerStdout` / `WorkerStderr` entries from `ProjectionStore.run_logs/1`:
      consecutive entries of one channel inside one phase, with no other turn
      between them and no gap longer than `gap_ms`, collapse into one `:agent`
      turn (stderr turns carry `source: "stderr"`).
    * `RunSteerQueued` on the run stream -> `:operator` / `:steer` turn.
    * `RunPaused` / `RunResumed` / `RunFailed` / `RunCompleted` / `RunCancelled` /
      `RunBlocked` -> `:system` / `:status` turn; so are the steering delivery
      events `RunSteerDelivered` / `RunSteerConsumed` / `RunSteerUndelivered`.
    * Phase boundaries (`ProjectionStore.phases_for_run/1`) only split agent
      turns; they are not turns themselves.

  Jobsite door (`jobsite:<id>`)

    * One `:agent` turn per recorded iteration (`JobsiteIterationCompleted`
      text, capped at 64 KiB by the event; `truncated` is set when that cap
      bit), a `:system` turn per failed iteration, and the captured
      `JobsiteOutputCaptured` value.
    * Jobsite events carry no per-iteration timestamp, so those turns have
      `at: nil` and are ordered by iteration index.
    * Jobsite resume prompts (the operator steer of E6-S5) are NOT persisted as
      events, so jobsite threads have no operator turns. The transcript says
      nothing about them rather than implying completeness.

  Both doors add a `:verdict` turn from `ReviewRecorded`.

  ## Ordering, cursor and boundedness

  Turns are ordered by `{time, source rank, arrival}` and numbered `0..n-1`, so
  an append never changes an existing `seq`. A growing agent turn would break
  that, so the trailing agent turn is withheld until it is final: the thread is
  terminal, its phase has ended, or `now_ms - last line > gap_ms` (a later line
  would then start a new turn anyway).

  Sources are bounded: `run_logs/1` keeps a bounded tail. When it dropped
  entries `omitted_entries` is non-zero and `truncated` is true; `seq` then
  counts from the oldest retained entry, so cursors are only stable while
  `omitted_entries` does not grow. `omitted_entries` counts raw log entries,
  not turns.

  Text is passed through `Coordinator.Redact`: the built-in patterns of
  `Overwatch.WorkerLogPolicy.redact/2` (the redactor that already scrubs worker log lines
  before `run_logs` stores them) AND every secret value of the thread's project
  (`ProjectEnvironment.secrets/1`, whatever the secret's name), so a value an agent echoed into
  its output, or an event recorded before the redaction existed, is covered at read time. The
  list is resolved ONCE per `page/2`, never per entry; a thread with no project, or a project
  whose list cannot be built, is redacted by the patterns alone.
  """

  alias ForemanServer.Coordinator.Redact
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Threads
  alias ForemanServer.Threads.Turn

  @default_limit 200
  @max_limit 1000
  @default_gap_ms 10_000
  @terminal_run_statuses ~w(completed failed blocked cancelled deleted)

  @type built :: %{
          turns: [Turn.t()],
          truncated: boolean(),
          omitted_entries: non_neg_integer()
        }

  @type log_entry :: %{channel: String.t(), at: integer() | nil, content: String.t()}
  @type phase :: %{index: integer(), started_at: integer() | nil, ended_at: integer() | nil}
  @type run_event :: %{event_type: String.t(), at: integer() | nil, reason: String.t() | nil}
  @type steer :: %{at: integer() | nil, text: String.t()}
  @type iteration :: %{
          index: integer(),
          status: String.t() | nil,
          text: String.t() | nil,
          text_truncated?: boolean(),
          message: String.t() | nil
        }
  @type review :: %{verdict: String.t(), summary: String.t() | nil, at: integer() | nil}

  @type inputs :: %{
          optional(:door) => :workflow | :jobsite,
          optional(:log_entries) => [log_entry()],
          optional(:phases) => [phase()],
          optional(:run_events) => [run_event()],
          optional(:steer) => [steer()],
          optional(:jobsite_iterations) => [iteration()],
          optional(:jobsite_output) => String.t() | nil,
          optional(:review) => review() | nil,
          optional(:omitted_entries) => non_neg_integer(),
          optional(:terminal?) => boolean(),
          optional(:now_ms) => integer() | nil,
          optional(:gap_ms) => non_neg_integer()
        }

  defmodule Page do
    @moduledoc "One page of transcript turns."
    @enforce_keys [:turns, :next_cursor, :truncated, :omitted_entries, :terminal]
    defstruct [:turns, :next_cursor, :truncated, :omitted_entries, :terminal]

    @type t :: %__MODULE__{
            turns: [ForemanServer.Threads.Turn.t()],
            next_cursor: integer(),
            truncated: boolean(),
            omitted_entries: non_neg_integer(),
            terminal: boolean()
          }

    @doc "Whitelisted string-keyed JSON shape shared by HTTP and MCP."
    @spec to_dto(t()) :: %{String.t() => term()}
    def to_dto(%__MODULE__{} = page) do
      %{
        "turns" => Enum.map(page.turns, &ForemanServer.Threads.Turn.to_dto/1),
        "next_cursor" => page.next_cursor,
        "truncated" => page.truncated,
        "omitted_entries" => page.omitted_entries,
        "terminal" => page.terminal
      }
    end
  end

  @doc "Default and maximum page size."
  @spec limits() :: %{default: pos_integer(), max: pos_integer()}
  def limits, do: %{default: @default_limit, max: @max_limit}

  # ---------------------------------------------------------------------------
  # Pure builder
  # ---------------------------------------------------------------------------

  @doc """
  Merge already-redacted source data into ordered turns (see moduledoc).

  `terminal?` defaults to `true` (every agent turn is final); `now_ms` is only
  consulted when `terminal?` is false.
  """
  @spec build_turns(inputs()) :: built()
  def build_turns(inputs) when is_map(inputs) do
    gap_ms = Map.get(inputs, :gap_ms, @default_gap_ms)
    phases = Map.get(inputs, :phases, [])
    omitted = Map.get(inputs, :omitted_entries, 0)
    iterations = Map.get(inputs, :jobsite_iterations, [])

    items =
      log_items(Map.get(inputs, :log_entries, []), phases) ++
        steer_items(Map.get(inputs, :steer, [])) ++
        system_items(Map.get(inputs, :run_events, [])) ++
        iteration_items(iterations) ++
        output_items(Map.get(inputs, :jobsite_output)) ++
        review_items(Map.get(inputs, :review))

    closed? = closed_fun(inputs, phases, gap_ms)

    turns =
      items
      |> Enum.with_index()
      |> Enum.sort_by(fn {item, arrival} -> {item.sort_at, item.rank, arrival} end)
      |> Enum.map(fn {item, _arrival} -> item end)
      |> fold_items(gap_ms, closed?)
      |> Enum.with_index()
      |> Enum.map(fn {%Turn{} = turn, seq} -> %Turn{turn | seq: seq} end)

    %{
      turns: turns,
      truncated: omitted > 0 or Enum.any?(iterations, &(&1[:text_truncated?] == true)),
      omitted_entries: omitted
    }
  end

  # rank breaks timestamp ties: operator intent, then lifecycle, then output, then verdict
  @rank_steer 0
  @rank_system 1
  @rank_agent 2
  @rank_review 3

  defp log_items(entries, phases) do
    {items, _} =
      Enum.map_reduce(entries, 0, fn entry, floor ->
        at = Map.get(entry, :at)
        # worker clocks may disagree; arrival order wins, so time never goes backwards
        sort_at = max(at || floor, floor)

        item = %{
          rank: @rank_agent,
          sort_at: sort_at,
          at: at,
          type: :log,
          channel: entry.channel,
          text: entry.content,
          phase: phase_of(phases, sort_at)
        }

        {item, sort_at}
      end)

    items
  end

  defp steer_items(steer) do
    Enum.map(steer, fn s ->
      %{
        rank: @rank_steer,
        sort_at: s.at || 0,
        at: s.at,
        type: :turn,
        turn: turn(:operator, :steer, s.text, s.at, "steer")
      }
    end)
  end

  @system_labels %{
    "RunPaused" => "Run paused",
    "RunResumed" => "Run resumed",
    "RunFailed" => "Run failed",
    "RunCompleted" => "Run completed",
    "RunCancelled" => "Run cancelled",
    "RunBlocked" => "Run blocked",
    # Mid-phase steering delivery state (the suffix is the delivery mode / reason).
    "RunSteerDelivered" => "Steer delivered to the running agent",
    "RunSteerConsumed" => "Steer taken by the agent",
    "RunSteerUndelivered" => "Steer NOT delivered"
  }

  defp system_items(events) do
    for %{event_type: type} = event <- events, Map.has_key?(@system_labels, type) do
      at = Map.get(event, :at)

      text =
        case Map.get(event, :reason) do
          reason when is_binary(reason) and reason != "" -> "#{@system_labels[type]}: #{reason}"
          _ -> @system_labels[type]
        end

      %{
        rank: @rank_system,
        sort_at: at || 0,
        at: at,
        type: :turn,
        turn: turn(:system, :status, text, at, "run_event")
      }
    end
  end

  defp iteration_items(iterations) do
    iterations
    |> Enum.sort_by(& &1.index)
    |> Enum.flat_map(fn iteration ->
      text = Map.get(iteration, :text)
      message = Map.get(iteration, :message)

      cond do
        iteration.status == "failed" ->
          body = "Iteration #{iteration.index} failed" <> failure_suffix(message)
          [jobsite_item(:system, :status, body, "jobsite_iteration")]

        is_binary(text) and String.trim(text) != "" ->
          [jobsite_item(:agent, :text, text, "jobsite_iteration")]

        true ->
          []
      end
    end)
  end

  defp failure_suffix(message) when is_binary(message) and message != "", do: ": " <> message
  defp failure_suffix(_), do: ""

  defp output_items(value) when is_binary(value) and value != "",
    do: [jobsite_item(:agent, :text, value, "jobsite_output")]

  defp output_items(_), do: []

  # No jobsite event carries a timestamp: arrival order (iterations by index,
  # then output) is the order, via the stable sort.
  defp jobsite_item(role, kind, text, source) do
    %{
      rank: @rank_agent,
      sort_at: 0,
      at: nil,
      type: :turn,
      turn: turn(role, kind, text, nil, source)
    }
  end

  defp review_items(%{verdict: verdict} = review) when is_binary(verdict) do
    at = Map.get(review, :at)

    text =
      case Map.get(review, :summary) do
        summary when is_binary(summary) and summary != "" -> "#{verdict}: #{summary}"
        _ -> verdict
      end

    [
      %{
        rank: @rank_review,
        sort_at: at || 0,
        at: at,
        type: :turn,
        turn: turn(:system, :verdict, text, at, "review")
      }
    ]
  end

  defp review_items(_), do: []

  defp turn(role, kind, text, at, source),
    do: %Turn{seq: 0, role: role, kind: kind, text: text, at: at, source: source}

  defp phase_of(phases, at) do
    phases
    |> Enum.filter(fn p -> is_integer(p.started_at) and p.started_at <= at end)
    |> Enum.sort_by(fn p -> {p.started_at, p.index} end, :desc)
    |> case do
      [%{index: index} | _] -> index
      [] -> nil
    end
  end

  defp closed_fun(inputs, phases, gap_ms) do
    terminal? = Map.get(inputs, :terminal?, true)
    now_ms = Map.get(inputs, :now_ms)

    fn group ->
      terminal? or phase_ended?(phases, group.phase) or
        (is_integer(now_ms) and now_ms - group.last_at > gap_ms)
    end
  end

  defp phase_ended?(_phases, nil), do: false

  defp phase_ended?(phases, index),
    do: Enum.any?(phases, fn p -> p.index == index and is_integer(p.ended_at) end)

  # Fold sorted items into turns, collapsing runs of log items. A group is
  # {channel, phase, last_at, lines, first_at}.
  defp fold_items(items, gap_ms, closed?) do
    {acc, group} =
      Enum.reduce(items, {[], nil}, fn
        %{type: :log} = item, {acc, nil} ->
          {acc, new_group(item)}

        %{type: :log} = item, {acc, group} ->
          if item.channel == group.channel and item.phase == group.phase and
               item.sort_at - group.last_at <= gap_ms do
            {acc, %{group | last_at: item.sort_at, lines: [item.text | group.lines]}}
          else
            {[group_turn(group) | acc], new_group(item)}
          end

        %{type: :turn, turn: turn}, {acc, nil} ->
          {[turn | acc], nil}

        %{type: :turn, turn: turn}, {acc, group} ->
          {[turn, group_turn(group) | acc], nil}
      end)

    acc =
      cond do
        group == nil -> acc
        closed?.(group) -> [group_turn(group) | acc]
        true -> acc
      end

    Enum.reverse(acc)
  end

  defp new_group(item) do
    %{
      channel: item.channel,
      phase: item.phase,
      first_at: item.at,
      last_at: item.sort_at,
      lines: [item.text]
    }
  end

  defp group_turn(group) do
    turn(
      :agent,
      :text,
      group.lines |> Enum.reverse() |> Enum.join("\n"),
      group.first_at,
      group.channel
    )
  end

  # ---------------------------------------------------------------------------
  # Paging over projections
  # ---------------------------------------------------------------------------

  @doc """
  Page of turns with `seq > after`.

  Options: `:after` (integer >= -1, default -1), `:limit` (1..#{@max_limit},
  default #{@default_limit}), `:gap_ms`, `:now_ms`. `next_cursor` is the last
  returned `seq`, or the input cursor when the page is empty.
  """
  @spec page(String.t(), keyword()) ::
          {:ok, Page.t()}
          | {:error, :thread_not_found | {:invalid_option, :after | :limit} | term()}
  def page(thread_id, opts \\ []) when is_binary(thread_id) and is_list(opts) do
    cursor = Keyword.get(opts, :after, -1)
    limit = Keyword.get(opts, :limit, @default_limit)

    cond do
      not (is_integer(cursor) and cursor >= -1) ->
        {:error, {:invalid_option, :after}}

      not (is_integer(limit) and limit >= 1 and limit <= @max_limit) ->
        {:error, {:invalid_option, :limit}}

      true ->
        with {:ok, thread} <- Threads.get(thread_id),
             {:ok, inputs} <- gather(thread, Redact.redactor(thread.project_id), opts) do
          built = build_turns(inputs)
          turns = built.turns |> Enum.filter(&(&1.seq > cursor)) |> Enum.take(limit)

          {:ok,
           %Page{
             turns: turns,
             next_cursor: turns |> List.last() |> then(&if(&1, do: &1.seq, else: cursor)),
             truncated: built.truncated,
             omitted_entries: built.omitted_entries,
             terminal: inputs.terminal?
           }}
        end
    end
  end

  defp gather(%Threads.Thread{door: :workflow, id: "run:" <> run_id}, redact, opts) do
    # Read the run (and so `terminal?`) FIRST. Each ProjectionStore call is a
    # separate GenServer call, so a terminal event can land between them. The
    # projection only ever grows, so logs/events read after the status are a
    # superset of what the status implies; the reverse order let a stream see
    # `terminal? = true` with events that lacked the closing turn and end
    # without ever emitting it.
    with %{} = run <- ProjectionStore.run(run_id),
         {:ok, logs} <- ProjectionStore.run_logs(run_id),
         {:ok, events} <- ProjectionStore.run_events(run_id) do
      {steer, system} = split_events(events, redact)

      {:ok,
       %{
         door: :workflow,
         log_entries: Enum.map(logs.entries, &log_entry(&1, redact)),
         phases: run_id |> ProjectionStore.phases_for_run() |> Enum.map(&phase/1),
         run_events: system,
         steer: steer,
         review: run_review(ProjectionStore.review("run", run_id), redact),
         omitted_entries: logs.omitted_entries,
         terminal?: fetch(run, :status) in @terminal_run_statuses
       }
       |> with_opts(opts)}
    else
      {:error, :run_not_found} -> {:error, :thread_not_found}
      nil -> {:error, :thread_not_found}
      {:error, _} = error -> error
    end
  end

  defp gather(%Threads.Thread{door: :jobsite, id: "jobsite:" <> jobsite_id}, redact, opts) do
    case ProjectionStore.jobsite(jobsite_id) do
      nil ->
        {:error, :thread_not_found}

      jobsite ->
        {:ok,
         %{
           door: :jobsite,
           jobsite_iterations:
             jobsite |> fetch(:iterations) |> List.wrap() |> Enum.map(&iteration(&1, redact)),
           jobsite_output: jobsite_output(fetch(jobsite, :output), redact),
           review: run_review(ProjectionStore.review("jobsite", jobsite_id), redact),
           omitted_entries: 0,
           terminal?: fetch(jobsite, :terminal?) == true
         }
         |> with_opts(opts)}
    end
  end

  defp with_opts(inputs, opts) do
    opts
    |> Keyword.take([:gap_ms, :now_ms])
    |> Enum.reduce(inputs, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  defp log_entry(entry, redact) do
    %{
      channel: fetch(entry, :channel),
      at: parse_time(fetch(entry, :timestamp)),
      content: redact.(fetch(entry, :content) || "")
    }
  end

  defp phase(phase) do
    status = fetch(phase, :status)

    %{
      index: fetch(phase, :index) || 0,
      started_at: fetch(phase, :started_at_ms),
      ended_at: if(status == "in_progress", do: nil, else: fetch(phase, :last_event_at_ms))
    }
  end

  defp split_events(events, redact) do
    {steer, system} =
      Enum.reduce(events, {[], []}, fn event, {steer, system} ->
        type = fetch(event, :event_type)
        data = fetch(event, :data) || %{}
        at = parse_time(fetch(event, :created_at))

        case type do
          "RunSteerQueued" ->
            {[%{at: at, text: redact.(to_text(fetch(data, :text)))} | steer], system}

          _ ->
            reason = fetch(data, :reason) || fetch(data, :mode) || fetch(data, :delivery)

            entry = %{
              event_type: type,
              at: at,
              reason: if(is_binary(reason), do: redact.(reason), else: nil)
            }

            {steer, [entry | system]}
        end
      end)

    {Enum.reverse(steer), Enum.reverse(system)}
  end

  defp iteration(record, redact) do
    %{
      index: fetch(record, :index) || 0,
      status: fetch(record, :status),
      text: record |> fetch(:text) |> maybe_redact(redact),
      text_truncated?: fetch(record, :text_truncated?) == true,
      message: record |> fetch(:message) |> maybe_redact(redact)
    }
  end

  defp jobsite_output(%{} = output, redact) do
    case fetch(output, :value) do
      value when is_binary(value) -> redact.(value)
      nil -> nil
      value -> value |> inspect(limit: 50, printable_limit: 4_000) |> redact.()
    end
  end

  defp jobsite_output(_, _redact), do: nil

  defp run_review(nil, _redact), do: nil

  defp run_review(review, redact) do
    %{
      verdict: fetch(review, :verdict),
      summary: review |> fetch(:summary) |> maybe_redact(redact),
      at: parse_time(fetch(review, :at))
    }
  end

  defp maybe_redact(text, redact) when is_binary(text), do: redact.(text)
  defp maybe_redact(_, _redact), do: nil
  defp to_text(text) when is_binary(text), do: text
  defp to_text(_), do: ""

  defp parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      {:error, _} -> nil
    end
  end

  defp parse_time(_), do: nil

  defp fetch(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
