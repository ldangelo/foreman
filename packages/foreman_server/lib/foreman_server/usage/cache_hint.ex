defmodule ForemanServer.Usage.CacheHint do
  @moduledoc """
  Prompt-cache warmth of one thread, computed purely from its recent usage
  events and an injected clock (no `DateTime.utc_now/0` here).

    * `cache_read_ratio` = cache_read / (input + cache_read + cache_write) over
      the thread's last events; `nil` when no event reported any cache figure
      (a provider that does not report caching is unknown, not a 0.0 ratio).
    * `idle_seconds` = `now - last_usage_at`.
    * `likely_cold?` = `idle_seconds > ttl` for the thread's provider; `nil` when
      the provider has no configured TTL (never defaulted to `false`).

  TTLs come from `config :foreman_server, :usage, cache_ttl_seconds:` (a map of
  provider name to seconds). The claude default of 300 is the documented
  5-minute prompt-cache lifetime and is an assumption to tune per provider.
  """

  alias ForemanServer.Usage.ThreadUsage

  @type t :: %__MODULE__{
          thread_id: String.t(),
          cache_read_ratio: float() | nil,
          idle_seconds: non_neg_integer(),
          likely_cold?: boolean() | nil,
          last_usage_at: String.t()
        }
  @enforce_keys [:thread_id, :idle_seconds, :last_usage_at]
  defstruct [:thread_id, :cache_read_ratio, :idle_seconds, :likely_cold?, :last_usage_at]

  @type ttl_by_provider :: %{optional(String.t()) => pos_integer()}

  @spec compute(ThreadUsage.t(), DateTime.t(), ttl_by_provider()) :: t()
  def compute(%ThreadUsage{} = thread, %DateTime{} = now, ttl_by_provider) do
    {:ok, last, _} = DateTime.from_iso8601(thread.last_at)
    idle = max(DateTime.diff(now, last, :second), 0)
    ttl = thread.provider && Map.get(ttl_by_provider, thread.provider)

    %__MODULE__{
      thread_id: thread.thread_id,
      cache_read_ratio: ratio(thread.recent),
      idle_seconds: idle,
      likely_cold?: if(is_integer(ttl), do: idle > ttl),
      last_usage_at: thread.last_at
    }
  end

  @doc "Configured TTLs with string provider keys."
  @spec configured_ttls() :: ttl_by_provider()
  def configured_ttls do
    :foreman_server
    |> Application.get_env(:usage, [])
    |> Keyword.get(:cache_ttl_seconds, %{})
    |> Map.new(fn {provider, seconds} -> {to_string(provider), seconds} end)
  end

  defp ratio(recent) do
    usages = Enum.map(recent, & &1.usage)

    if Enum.all?(usages, &(is_nil(&1.cache_read_tokens) and is_nil(&1.cache_write_tokens))) do
      nil
    else
      read = sum(usages, :cache_read_tokens)
      denominator = read + sum(usages, :input_tokens) + sum(usages, :cache_write_tokens)
      if denominator > 0, do: read / denominator
    end
  end

  defp sum(usages, field), do: usages |> Enum.map(&(Map.fetch!(&1, field) || 0)) |> Enum.sum()
end
