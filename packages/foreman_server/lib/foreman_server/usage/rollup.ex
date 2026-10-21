defmodule ForemanServer.Usage.Rollup do
  @moduledoc """
  Pure read model over normalised usage records (`ForemanServer.Usage`): totals
  per project, UTC day, thread, model, provider and role. No process, no I/O:
  `ForemanServer.ProjectionStore` keeps the records and folds them here.

  Honesty rules (the reason this is not a bare map sum):

    * Cost is provider-reported or unknown. `Usage.merge/2` is nil-preserving, so
      a bucket whose events all lack a cost has `cost_usd: nil`, never `0.0`.
    * Every event without a cost increments `cost_unknown_events`, so a mixed
      bucket (some events priced, some not) reads as a *partial* cost and a
      consumer can tell it from a complete one.
    * A record without a model or provider lands in the reserved bucket
      `"unknown"` rather than being dropped.

  A record is a map with `:thread_kind` (`"workflow" | "jobsite"`), `:thread_id`,
  `:role` (`"thread" | "coordinator" | "review"`), `:model`, `:provider`, `:at`
  (ISO-8601 UTC) and `:usage` (`%Usage{}`).

  Day buckets older than #{366} days before the newest day seen are pruned from
  `by_day` on `add/2` (they stay in `total` and the other breakdowns).
  """

  alias ForemanServer.Usage

  @unknown "unknown"
  @retention_days 366
  @recent_events 5

  defmodule Bucket do
    @moduledoc "Summed usage of a set of events plus how many of them had no cost."
    @type t :: %__MODULE__{
            usage: Usage.t(),
            events: non_neg_integer(),
            cost_unknown_events: non_neg_integer()
          }
    defstruct usage: %Usage{}, events: 0, cost_unknown_events: 0
  end

  defmodule ThreadUsage do
    @moduledoc "One thread's (run or jobsite) bucket, its last activity and its most recent events."
    @type recent :: %{at: String.t(), usage: Usage.t()}
    @type t :: %__MODULE__{
            thread_kind: String.t(),
            thread_id: String.t(),
            role: String.t(),
            last_at: String.t(),
            bucket: ForemanServer.Usage.Rollup.Bucket.t(),
            recent: [recent()]
          }
    @enforce_keys [:thread_kind, :thread_id, :role, :last_at]
    defstruct [:thread_kind, :thread_id, :role, :last_at, bucket: %Bucket{}, recent: []]
  end

  @type t :: %__MODULE__{
          total: Bucket.t(),
          by_day: %{String.t() => Bucket.t()},
          by_thread: %{String.t() => ThreadUsage.t()},
          by_model: %{String.t() => Bucket.t()},
          by_provider: %{String.t() => Bucket.t()},
          by_role: %{String.t() => Bucket.t()}
        }

  defstruct total: %Bucket{},
            by_day: %{},
            by_thread: %{},
            by_model: %{},
            by_provider: %{},
            by_role: %{}

  @type record :: %{
          required(:thread_kind) => String.t(),
          required(:thread_id) => String.t(),
          required(:role) => String.t(),
          required(:model) => String.t() | nil,
          required(:provider) => String.t() | nil,
          required(:at) => String.t(),
          required(:usage) => Usage.t()
        }

  @doc "The reserved bucket key for a missing model or provider."
  @spec unknown_key() :: String.t()
  def unknown_key, do: @unknown

  @doc "UTC day (`YYYY-MM-DD`) of an ISO-8601 timestamp; the key of `by_day`."
  @spec day(String.t()) :: String.t()
  def day(at) when is_binary(at), do: String.slice(at, 0, 10)

  @doc "Fold one record in. Pure and total."
  @spec add(t(), record()) :: t()
  def add(%__MODULE__{} = rollup, %{usage: %Usage{} = usage, at: at} = record)
      when is_binary(at) do
    day = day(at)
    model = record.model || @unknown
    provider = record.provider || @unknown

    %__MODULE__{
      rollup
      | total: add_bucket(rollup.total, usage),
        by_day: rollup.by_day |> bump(day, usage) |> prune_days(),
        by_thread: add_thread(rollup.by_thread, record),
        by_model: bump(rollup.by_model, model, usage),
        by_provider: bump(rollup.by_provider, provider, usage),
        by_role: bump(rollup.by_role, record.role, usage)
    }
  end

  @doc "Fold a list of records."
  @spec from_records([record()]) :: t()
  def from_records(records), do: Enum.reduce(records, %__MODULE__{}, &add(&2, &1))

  @doc "Add a whole bucket (used to carry the totals of pruned days)."
  @spec merge_bucket(Bucket.t(), Bucket.t()) :: Bucket.t()
  def merge_bucket(%Bucket{} = a, %Bucket{} = b) do
    %Bucket{
      usage: Usage.merge(a.usage, b.usage),
      events: a.events + b.events,
      cost_unknown_events: a.cost_unknown_events + b.cost_unknown_events
    }
  end

  @doc "Number of recent events kept per thread (the cache-hint window)."
  @spec recent_window() :: pos_integer()
  def recent_window, do: @recent_events

  # -- internals ---------------------------------------------------------------

  defp add_bucket(%Bucket{} = bucket, %Usage{} = usage) do
    %Bucket{
      usage: Usage.merge(bucket.usage, usage),
      events: bucket.events + 1,
      cost_unknown_events: bucket.cost_unknown_events + if(is_nil(usage.cost_usd), do: 1, else: 0)
    }
  end

  defp bump(map, key, usage), do: Map.update(map, key, add_bucket(%Bucket{}, usage), &add_bucket(&1, usage))

  defp add_thread(threads, %{thread_id: id, usage: usage, at: at} = record) do
    recent = %{at: at, usage: usage}

    Map.update(
      threads,
      id,
      %ThreadUsage{
        thread_kind: record.thread_kind,
        thread_id: id,
        role: record.role,
        last_at: at,
        bucket: add_bucket(%Bucket{}, usage),
        recent: [recent]
      },
      fn %ThreadUsage{} = thread ->
        %ThreadUsage{
          thread
          | last_at: max(thread.last_at, at),
            bucket: add_bucket(thread.bucket, usage),
            recent: thread.recent |> Kernel.++([recent]) |> newest(@recent_events)
        }
      end
    )
  end

  defp newest(events, count) do
    events |> Enum.sort_by(& &1.at) |> Enum.take(-count)
  end

  defp prune_days(by_day) when map_size(by_day) <= @retention_days, do: by_day

  defp prune_days(by_day) do
    newest = by_day |> Map.keys() |> Enum.max() |> Date.from_iso8601!()
    cutoff = newest |> Date.add(-@retention_days) |> Date.to_iso8601()
    Map.reject(by_day, fn {day, _} -> day < cutoff end)
  end
end
