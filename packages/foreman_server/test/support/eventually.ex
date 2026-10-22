defmodule ForemanServer.TestSupport.Eventually do
  @moduledoc """
  Polling-with-deadline helpers that replace `Process.sleep/1`-as-wait.

  `await/2` re-evaluates `fun` until it returns a truthy value (which is
  returned) or the deadline passes, in which case the test fails with the
  last observed value. Returns as soon as the condition holds, so a passing
  run is never slower than the event it waits for, and a slow machine gets the
  whole deadline instead of a fixed guess.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @default_timeout_ms 5_000
  @default_interval_ms 10

  @type opts :: [timeout: pos_integer(), interval: pos_integer(), message: String.t()]

  @spec await((-> term()), opts()) :: term()
  def await(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    interval = Keyword.get(opts, :interval, @default_interval_ms)
    message = Keyword.get(opts, :message, "condition not met")
    deadline = System.monotonic_time(:millisecond) + timeout
    loop(fun, interval, deadline, message)
  end

  defp loop(fun, interval, deadline, message) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out: #{message}")
        else
          Process.sleep(interval)
          loop(fun, interval, deadline, message)
        end

      value ->
        value
    end
  end

  @doc """
  Sets `app` env `key` to `value` (or deletes it when `nil`) for the current
  test and registers an `on_exit` that restores the original, deleting the key
  when it was originally unset.
  """
  @spec put_env_for_test(atom(), atom(), term()) :: :ok
  def put_env_for_test(app, key, value) do
    original = Application.fetch_env(app, key)

    ExUnit.Callbacks.on_exit({__MODULE__, app, key}, fn ->
      case original do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)

    if is_nil(value),
      do: Application.delete_env(app, key),
      else: Application.put_env(app, key, value)

    :ok
  end
end
