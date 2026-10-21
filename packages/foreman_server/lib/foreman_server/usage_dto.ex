defmodule ForemanServer.UsageDTO do
  @moduledoc """
  The one wire shape of a project's usage read (`GET /api/projects/:id/usage`,
  the MCP `foreman_usage_get` tool, `foreman usage`): fixed string keys,
  explicit `null`s, never a bare rollup struct.

      %{
        "project_id" => "...", "from" => "2026-01-01" | nil, "to" => nil, "group_by" => nil,
        "totals" => bucket, "by_day" => [%{"date" => ..} ++ bucket],
        "by_thread" => [...], "by_model" => [%{"model" => ..} ++ bucket],
        "by_provider" => [...], "by_role" => [...],
        "limits" => %{...}, "cache_hints" => [...]
      }

  A `bucket` is `input_tokens`, `output_tokens`, `cache_read_tokens`,
  `cache_write_tokens`, `total_tokens`, `cost_usd`, `events`,
  `cost_unknown_events`. `cost_usd` is `null` when no event in the bucket
  reported a cost; when only some did it is the sum of those and
  `cost_unknown_events` says how many events are unpriced.

  With `group_by` (`day|model|provider|role|thread`) only that breakdown is
  returned, besides totals, limits and cache hints.
  """

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Usage.{Bucket, CacheHint, Rollup, ThreadUsage}

  @group_bys ~w(day model provider role thread)
  @max_span_days 366
  @default_limit 50
  @max_limit 500

  @type error ::
          {:invalid_range, String.t()}
          | {:range_too_large, String.t()}
          | {:invalid_group_by, String.t()}
          | {:invalid_limit, String.t()}

  @type params :: %{
          from: Date.t() | nil,
          to: Date.t() | nil,
          group_by: String.t() | nil,
          limit: pos_integer()
        }

  @doc """
  Parse request params (string or atom keys, string values) once for every
  surface. Error codes: `invalid_range`, `range_too_large`, `invalid_group_by`,
  `invalid_limit`.
  """
  @spec parse_params(map()) :: {:ok, params()} | {:error, error()}
  def parse_params(raw) when is_map(raw) do
    raw = Map.new(raw, fn {key, value} -> {to_string(key), value} end)

    with {:ok, from} <- parse_date(raw["from"], "from"),
         {:ok, to} <- parse_date(raw["to"], "to"),
         :ok <- check_range(from, to),
         {:ok, group_by} <- parse_group_by(raw["group_by"]),
         {:ok, limit} <- parse_limit(raw["limit"]) do
      {:ok, %{from: from, to: to, group_by: group_by, limit: limit}}
    end
  end

  @doc "Build the DTO for `project_id`, or `:not_found` for an unknown project."
  @spec build(String.t(), params(), DateTime.t()) :: {:ok, map()} | :not_found
  def build(project_id, %{} = params, %DateTime{} = now) when is_binary(project_id) do
    with %Rollup{} = rollup <-
           ProjectionStore.usage(project_id,
             from: params.from && Date.to_iso8601(params.from),
             to: params.to && Date.to_iso8601(params.to)
           ),
         %{} = limits <- ProjectionStore.project_limits(project_id, now) do
      {:ok, assemble(project_id, params, rollup, limits, now)}
    else
      nil -> :not_found
    end
  end

  # -- assembly ----------------------------------------------------------------

  defp assemble(project_id, params, %Rollup{} = rollup, limits, now) do
    breakdowns = breakdowns(rollup, params.limit)

    base = %{
      "project_id" => project_id,
      "from" => params.from && Date.to_iso8601(params.from),
      "to" => params.to && Date.to_iso8601(params.to),
      "group_by" => params.group_by,
      "totals" => bucket(rollup.total),
      "limits" => Map.new(limits, fn {key, value} -> {Atom.to_string(key), value} end),
      "cache_hints" => cache_hints(rollup, now),
      "thread_count" => map_size(rollup.by_thread)
    }

    selected =
      case params.group_by do
        nil -> breakdowns
        group -> Map.take(breakdowns, ["by_" <> group])
      end

    Map.merge(base, selected)
  end

  defp breakdowns(%Rollup{} = rollup, limit) do
    %{
      "by_day" => keyed(rollup.by_day, "date"),
      "by_thread" => threads(rollup.by_thread, limit),
      "by_model" => keyed(rollup.by_model, "model"),
      "by_provider" => keyed(rollup.by_provider, "provider"),
      "by_role" => keyed(rollup.by_role, "role")
    }
  end

  defp keyed(buckets, label) do
    buckets
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, %Bucket{} = bucket} -> Map.put(bucket(bucket), label, key) end)
  end

  # Highest cost first, unknown cost last; ties broken by tokens then id so the
  # order is stable.
  defp threads(by_thread, limit) do
    by_thread
    |> Map.values()
    |> Enum.sort_by(fn %ThreadUsage{bucket: %Bucket{usage: usage}} = thread ->
      {-(usage.cost_usd || -1.0), -(usage.total_tokens || 0), thread.thread_id}
    end)
    |> Enum.take(limit)
    |> Enum.map(fn %ThreadUsage{} = thread ->
      thread.bucket
      |> bucket()
      |> Map.merge(%{
        "thread_id" => thread.thread_id,
        "thread_kind" => thread.thread_kind,
        "role" => thread.role,
        "provider" => thread.provider,
        "last_at" => thread.last_at
      })
    end)
  end

  defp cache_hints(%Rollup{by_thread: by_thread}, now) do
    ttls = CacheHint.configured_ttls()

    by_thread
    |> Map.values()
    |> Enum.sort_by(& &1.thread_id)
    |> Enum.map(fn %ThreadUsage{} = thread ->
      hint = CacheHint.compute(thread, now, ttls)

      %{
        "thread_id" => hint.thread_id,
        "cache_read_ratio" => hint.cache_read_ratio,
        "idle_seconds" => hint.idle_seconds,
        "likely_cold" => hint.likely_cold?,
        "last_usage_at" => hint.last_usage_at
      }
    end)
  end

  defp bucket(%Bucket{usage: usage} = bucket) do
    %{
      "input_tokens" => usage.input_tokens,
      "output_tokens" => usage.output_tokens,
      "cache_read_tokens" => usage.cache_read_tokens,
      "cache_write_tokens" => usage.cache_write_tokens,
      "total_tokens" => usage.total_tokens,
      "cost_usd" => usage.cost_usd,
      "events" => bucket.events,
      "cost_unknown_events" => bucket.cost_unknown_events
    }
  end

  # -- params ------------------------------------------------------------------

  defp parse_date(nil, _name), do: {:ok, nil}

  defp parse_date(value, name) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, {:invalid_range, "#{name} must be a YYYY-MM-DD date"}}
    end
  end

  defp parse_date(_value, name),
    do: {:error, {:invalid_range, "#{name} must be a YYYY-MM-DD date"}}

  defp check_range(%Date{} = from, %Date{} = to) do
    cond do
      Date.compare(to, from) == :lt ->
        {:error, {:invalid_range, "to must not be before from"}}

      Date.diff(to, from) + 1 > @max_span_days ->
        {:error, {:range_too_large, "range must span at most #{@max_span_days} days"}}

      true ->
        :ok
    end
  end

  defp check_range(_from, _to), do: :ok

  defp parse_group_by(nil), do: {:ok, nil}
  defp parse_group_by(value) when value in @group_bys, do: {:ok, value}

  defp parse_group_by(_),
    do: {:error, {:invalid_group_by, "group_by must be one of: " <> Enum.join(@group_bys, ", ")}}

  defp parse_limit(nil), do: {:ok, @default_limit}
  defp parse_limit(value) when is_integer(value) and value in 1..@max_limit, do: {:ok, value}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..@max_limit -> {:ok, limit}
      _ -> invalid_limit()
    end
  end

  defp parse_limit(_), do: invalid_limit()

  defp invalid_limit, do: {:error, {:invalid_limit, "limit must be an integer 1..#{@max_limit}"}}
end
