defmodule ForemanServer.Usage do
  @moduledoc """
  Normalised token usage and provider-reported cost for one agent run.

  This is the single parsing site for provider usage shapes; everything
  downstream (the `UsageRecorded` and `CoordinatorUsageRecorded` events, the run
  projection, the future E14 rollups) consumes `%ForemanServer.Usage{}` and never
  a raw provider map.

  Every field is `non_neg_integer() | nil` (cost: `float() | nil`). **`nil`
  means unknown, never zero**: a provider that did not report cost is not a
  provider that charged nothing, so cost is a number only when the provider
  reported one.

  ## Provider shapes

  Raw maps are STRING-keyed (the `Jido.Harness` contract, see the comment on
  `JidoHarnessWorker.log_events/1`); only string keys are read.

    * `:claude` - `input_tokens`, `output_tokens`, `cache_read_input_tokens`,
      `cache_creation_input_tokens`. Cost is NOT in the usage map; the CLI
      reports it on the terminal `:run_completed` event (`"cost_usd"`), which
      callers pass as `events_cost_usd`.
    * `:pi` - verified against a real `pi 1.3.0` run
      (`minimax/MiniMax-M2.7-highspeed`, 2026-10): each assistant
      `message_end` carries `"usage"` =
      `%{"input" => 40940, "output" => 3, "cacheRead" => 128, "cacheWrite" => 0,
      "totalTokens" => 41071, "cost" => %{"input" => _, "output" => _,
      "cacheRead" => _, "cacheWrite" => _, "total" => 0.0245...}}`.
      `totalTokens` includes cache reads. Pi computes `cost.total` from its own
      price table, so it is provider-reported, but a model without pricing
      reports `0` there and that is indistinguishable from free. Usage is
      PER MESSAGE, so `from_run/4` sums the `:usage` events of a pi run;
      `Jido.Harness.Run.Worker` merges them last-write-wins, which would count
      only the final message.
    * any other provider - tokens are `nil` (unknown shape), not guessed.

  ## Why not `Jido.AI.Usage`

  Evaluated and not adopted for the merge step. It re-keys maps to atoms and
  merges untyped maps, treating a missing key and zero alike and having no
  notion of "unknown cost". Foreman needs a typed struct with nil-preserving
  addition (`nil + nil = nil`, `nil + 3 = 3`), so `merge/2` here is the
  contract and `Jido.AI.Usage` stays out of the boundary.
  """

  alias Jido.Harness.{Event, RunResult}

  @derive Jason.Encoder
  defstruct input_tokens: nil,
            output_tokens: nil,
            cache_read_tokens: nil,
            cache_write_tokens: nil,
            total_tokens: nil,
            cost_usd: nil

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_read_tokens: non_neg_integer() | nil,
          cache_write_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil,
          cost_usd: float() | nil
        }

  @token_fields [
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :total_tokens
  ]
  @part_fields [:input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens]

  @doc """
  Normalise one provider usage map.

  `events_cost_usd` is the cost the provider reported outside the usage map
  (Claude's `run_completed` event); when it is a non-negative number it wins
  over any cost found inside `raw_usage`. Never raises: anything that is not a
  non-negative integer (strings, negatives, floats) becomes `nil`.
  """
  @spec normalize(atom(), map(), number() | nil) :: t()
  def normalize(provider, raw_usage, events_cost_usd) when is_atom(provider) do
    raw = if is_map(raw_usage), do: raw_usage, else: %{}

    parts = provider_parts(provider, raw)

    %__MODULE__{
      input_tokens: parts.input_tokens,
      output_tokens: parts.output_tokens,
      cache_read_tokens: parts.cache_read_tokens,
      cache_write_tokens: parts.cache_write_tokens,
      total_tokens: parts.total_tokens || sum_parts(parts),
      cost_usd: cost(events_cost_usd) || cost(provider_cost(provider, raw))
    }
  end

  @doc """
  Normalise a whole finished run.

  `raw_usage` is `RunResult.usage`; `usage_events` are the payloads of the
  run's `:usage` events in order. For `:pi` (per-message usage) the events are
  summed; every other provider reports cumulative usage once, so `raw_usage`
  is used as is. A pi run with no usage events falls back to `raw_usage`.
  """
  @spec from_run(atom(), map(), [map()], number() | nil) :: t()
  def from_run(:pi, raw_usage, [_ | _] = usage_events, events_cost_usd) do
    usage_events
    |> Enum.map(&normalize(:pi, &1, nil))
    |> Enum.reduce(%__MODULE__{}, &merge(&2, &1))
    |> override_cost(events_cost_usd)
    |> keep_when_nonempty(normalize(:pi, raw_usage, events_cost_usd))
  end

  def from_run(provider, raw_usage, _usage_events, events_cost_usd),
    do: normalize(provider, raw_usage, events_cost_usd)

  @doc """
  Normalise a finished `Jido.Harness.RunResult`: `from_run/4` over its merged `usage`, the
  payloads of its `:usage` events and the cost its terminal event reports. This is the one
  place a run's usage is read, for the worker door and for the reviewer alike: reading only
  `RunResult.usage` counts a pi run's last message and nothing before it.
  """
  @spec from_run_result(atom(), RunResult.t()) :: t()
  def from_run_result(provider, %RunResult{usage: usage, events: events}) when is_atom(provider),
    do: from_run(provider, usage, usage_events(events), events_cost_usd(events))

  @doc "The payloads of the `:usage` events of a run, in order (what `from_run/4` sums for pi)."
  @spec usage_events([Event.t()]) :: [map()]
  def usage_events(events) do
    for %Event{type: :usage, payload: payload} <- events,
        is_map(payload),
        do: payload
  end

  @doc """
  Claude reports the dollar cost only on the terminal `:run_completed` event
  (`claude_stream.ex:71`), never in `RunResult.usage`. Last one wins; `nil` when absent.
  """
  @spec events_cost_usd([Event.t()]) :: number() | nil
  def events_cost_usd(events) do
    events
    |> Enum.filter(&match?(%Event{type: :run_completed}, &1))
    |> List.last()
    |> case do
      %Event{payload: %{"cost_usd" => cost}} when is_number(cost) -> cost
      _ -> nil
    end
  end

  @doc """
  Normalise the usage of one finished harness run (`Jido.Harness.RunResult`),
  whatever its status: a failed or cancelled run spent its tokens too.

  Gathers the inputs `from_run/4` takes the way the workflow worker does
  (`JidoHarnessWorker.build_meta/2`): the result's `provider` and `usage`, the
  payload maps of its `:usage` events (maps only, in order) and the
  `"cost_usd"` of its LAST `:run_completed` event (Claude reports its cost only
  there), `nil` when absent. A provider without a known usage shape gives an
  all-nil usage, and so does a result that reported nothing.
  """
  @spec from_run_result(RunResult.t()) :: t()
  def from_run_result(%RunResult{provider: provider} = result),
    do: from_run_result(provider, result)

  @doc """
  Build a usage from already-normalised fields (an event payload or projection
  map), re-validating each one so a malformed historical event cannot put a
  string or a negative number into a run total. Unknown keys are ignored.
  """
  @spec from_fields(map()) :: t()
  def from_fields(fields) when is_map(fields) do
    %__MODULE__{
      input_tokens: count(Map.get(fields, :input_tokens)),
      output_tokens: count(Map.get(fields, :output_tokens)),
      cache_read_tokens: count(Map.get(fields, :cache_read_tokens)),
      cache_write_tokens: count(Map.get(fields, :cache_write_tokens)),
      total_tokens: count(Map.get(fields, :total_tokens)),
      cost_usd: cost(Map.get(fields, :cost_usd))
    }
  end

  @doc """
  Sum two usages. Associative and nil-preserving: `nil + nil = nil`,
  `nil + n = n`. `nil` on either side is the identity.
  """
  @spec merge(t() | nil, t() | nil) :: t()
  def merge(nil, nil), do: %__MODULE__{}
  def merge(nil, %__MODULE__{} = b), do: b
  def merge(%__MODULE__{} = a, nil), do: a

  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    Enum.reduce(@token_fields ++ [:cost_usd], %__MODULE__{}, fn field, acc ->
      Map.put(acc, field, add(Map.fetch!(a, field), Map.fetch!(b, field)))
    end)
  end

  @doc "True when no field carries a value (nothing worth recording)."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = usage),
    do: Enum.all?(@token_fields ++ [:cost_usd], &is_nil(Map.fetch!(usage, &1)))

  @doc "The six usage fields as a plain map, for event payloads."
  @spec to_event_fields(t()) :: %{atom() => number() | nil}
  def to_event_fields(%__MODULE__{} = usage), do: Map.from_struct(usage)

  # -- internals ---------------------------------------------------------

  defp provider_parts(:claude, raw) do
    %{
      input_tokens: count(raw["input_tokens"]),
      output_tokens: count(raw["output_tokens"]),
      cache_read_tokens: count(raw["cache_read_input_tokens"]),
      cache_write_tokens: count(raw["cache_creation_input_tokens"]),
      total_tokens: count(raw["total_tokens"])
    }
  end

  defp provider_parts(:pi, raw) do
    %{
      input_tokens: count(raw["input"]),
      output_tokens: count(raw["output"]),
      cache_read_tokens: count(raw["cacheRead"]),
      cache_write_tokens: count(raw["cacheWrite"]),
      total_tokens: count(raw["totalTokens"])
    }
  end

  defp provider_parts(_unknown, _raw) do
    %{
      input_tokens: nil,
      output_tokens: nil,
      cache_read_tokens: nil,
      cache_write_tokens: nil,
      total_tokens: nil
    }
  end

  defp provider_cost(:pi, %{"cost" => %{"total" => total}}), do: total
  defp provider_cost(_provider, _raw), do: nil

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: nil

  defp cost(value) when is_number(value) and value >= 0, do: value * 1.0
  defp cost(_value), do: nil

  defp sum_parts(parts) do
    parts |> Map.take(@part_fields) |> Map.values() |> Enum.reduce(nil, &add/2)
  end

  defp add(nil, nil), do: nil
  defp add(nil, n), do: n
  defp add(n, nil), do: n
  defp add(a, b), do: a + b

  defp override_cost(%__MODULE__{} = usage, events_cost_usd) do
    case cost(events_cost_usd) do
      nil -> usage
      value -> %__MODULE__{usage | cost_usd: value}
    end
  end

  # Prefer the summed events; if they yielded nothing at all, the aggregate map.
  defp keep_when_nonempty(%__MODULE__{} = summed, %__MODULE__{} = fallback) do
    if empty?(summed), do: fallback, else: summed
  end
end
