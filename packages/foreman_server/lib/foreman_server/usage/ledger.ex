defmodule ForemanServer.Usage.Ledger do
  @moduledoc """
  One project's usage records, bucketed by UTC day, from which
  `ForemanServer.Usage.Rollup` is folded on read.

  Records are keyed (`put/3`), so applying the same event twice (live then
  replayed, or a worker's event re-delivered) replaces instead of double
  counting. Day buckets older than 366 days before the newest day are dropped;
  their summed totals are kept in `pruned` and added to the unfiltered `total`
  only, so an old event never vanishes from "all time" but cannot be sliced.
  """

  alias ForemanServer.Usage.Rollup
  alias ForemanServer.Usage.Bucket

  @retention_days 366

  @type key :: {String.t(), String.t(), {:worker | :iteration, term()}}
  @type t :: %__MODULE__{
          days: %{String.t() => %{key() => Rollup.usage_record()}},
          pruned: Bucket.t()
        }
  defstruct days: %{}, pruned: %Bucket{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Insert (or replace) one record under `key`.

  Keys are `{thread_kind, thread_id, {:worker, worker_id} | {:iteration, index}}`.
  A jobsite thread whose usage arrives as worker-sourced events (the Overwatch
  runner) must not also count its iteration records: worker records win, in
  either arrival order.
  """
  @spec put(t(), key(), Rollup.usage_record()) :: t()
  def put(%__MODULE__{} = ledger, {"jobsite", id, {:worker, _}} = key, record) do
    ledger |> drop_thread_records(id, :iteration) |> insert(key, record)
  end

  def put(%__MODULE__{} = ledger, {"jobsite", id, {:iteration, _}} = key, record) do
    if has_thread_records?(ledger, id, :worker), do: ledger, else: insert(ledger, key, record)
  end

  def put(%__MODULE__{} = ledger, key, record), do: insert(ledger, key, record)

  defp insert(%__MODULE__{} = ledger, key, %{at: at} = record) when is_binary(at) do
    day = Rollup.day(at)
    days = Map.update(ledger.days, day, %{key => record}, &Map.put(&1, key, record))
    prune(%__MODULE__{ledger | days: days})
  end

  defp has_thread_records?(ledger, id, tag) do
    Enum.any?(ledger.days, fn {_day, by_key} ->
      Enum.any?(by_key, fn
        {{"jobsite", rid, {t, _}}, _} -> rid == id and t == tag
        _ -> false
      end)
    end)
  end

  defp drop_thread_records(%__MODULE__{} = ledger, id, tag) do
    days =
      Map.new(ledger.days, fn {day, by_key} ->
        {day,
         Map.reject(by_key, fn
           {{"jobsite", rid, {t, _}}, _} -> rid == id and t == tag
           _ -> false
         end)}
      end)

    %__MODULE__{ledger | days: days}
  end

  @doc """
  Fold the records of `from..to` (inclusive ISO dates, either may be `nil`)
  into a rollup. Without a range the pruned totals are included.
  """
  @spec rollup(t(), String.t() | nil, String.t() | nil) :: Rollup.t()
  def rollup(%__MODULE__{} = ledger, from, to) do
    records =
      ledger.days
      |> Enum.filter(fn {day, _} ->
        (is_nil(from) or day >= from) and (is_nil(to) or day <= to)
      end)
      |> Enum.flat_map(fn {_day, by_key} -> Map.values(by_key) end)
      |> Enum.sort_by(&{&1.at, &1.thread_id})

    %Rollup{} = rollup = Rollup.from_records(records)

    if is_nil(from) and is_nil(to) do
      %Rollup{rollup | total: Rollup.merge_bucket(rollup.total, ledger.pruned)}
    else
      rollup
    end
  end

  defp prune(%__MODULE__{days: days, pruned: pruned} = ledger) do
    newest = days |> Map.keys() |> Enum.max() |> Date.from_iso8601!()
    cutoff = newest |> Date.add(-@retention_days) |> Date.to_iso8601()
    {old, kept} = Enum.split_with(days, fn {day, _} -> day < cutoff end)

    old_bucket =
      old
      |> Enum.flat_map(fn {_, by_key} -> Map.values(by_key) end)
      |> Rollup.from_records()
      |> Map.fetch!(:total)

    %__MODULE__{ledger | days: Map.new(kept), pruned: Rollup.merge_bucket(pruned, old_bucket)}
  end
end
