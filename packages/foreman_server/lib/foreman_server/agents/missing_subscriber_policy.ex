defmodule ForemanServer.Agents.MissingSubscriberPolicy do
  @moduledoc """
  Foreman-side policy for what to do when a Jido signal is published
  to a topic with no subscribers (TRD-2026-4212be7e, JSI-T003).

  Per the TRD:
    "Implement missing-subscriber configurable policy (silent/warn/
     error, default warn) in Foreman config."

  The policy is configured via:

      config :foreman_server, ForemanServer.Agents.MissingSubscriberPolicy,
        default: :warn,
        per_topic: %{
          "com.foreman.critical" => :error
        }

  `apply/3` returns `:ok | :warn | :error` for a given topic. The
  default is `:warn` (log a warning, do not crash or escalate).
  Per-topic overrides take precedence over the default. A topic
  with no override falls back to the default.
  """

  require Logger

  @type verdict :: :ok | :warn | :error

  @doc """
  Default policy when none is configured.
  """
  @spec default() :: :warn
  def default, do: :warn

  @doc """
  Apply the configured policy for a topic.

  ## Arguments

    - `topic` — the Jido topic (or pattern) being published to.
    - `bus` — the bus pid/name (used for logging; can be `nil`).
    - `signal` — the signal being published (used for logging).

  ## Returns

  `:ok` (silent), `:warn` (default), or `:error`. The policy
  behavior (log/callback) is the side effect; the return value is
  what callers should branch on.
  """
  @spec apply(String.t(), GenServer.server() | nil, struct() | map()) :: verdict()
  def apply(topic, bus, _signal) when is_binary(topic) do
    policy = effective_policy(topic)

    case policy do
      # `:silent` is the user-facing name (in the test and in the TRD);
      # `:ok` is the internal return value. Normalize here.
      :silent ->
        :ok

      :ok ->
        :ok

      :warn ->
        Logger.warning(
          "MissingSubscriberPolicy: published signal to #{inspect(topic)} " <>
            "(bus=#{inspect(bus)}) but no subscribers match — default warn"
        )

        :warn

      :error ->
        Logger.error(
          "MissingSubscriberPolicy: published signal to #{inspect(topic)} " <>
            "(bus=#{inspect(bus)}) but no subscribers match — error policy"
        )

        :error
    end
  end

  # Resolve the effective policy for a topic: per-topic override
  # takes precedence over the default; absent both, return the
  # default (:warn).
  @spec effective_policy(String.t()) :: verdict()
  defp effective_policy(topic) do
    config = Application.get_env(:foreman_server, __MODULE__, [])

    per_topic = Keyword.get(config, :per_topic, %{})
    default = Keyword.get(config, :default, default())

    Map.get(per_topic, topic, default)
  end
end
