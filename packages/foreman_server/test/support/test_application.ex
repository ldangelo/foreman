defmodule ForemanServer.TestSupport.TestApplication do
  @moduledoc false

  @spec reset_application_child!(module()) :: pid()
  def reset_application_child!(child_module) do
    original_state = :sys.get_state(child_module)

    ExUnit.Callbacks.on_exit({child_module, make_ref()}, fn ->
      :sys.replace_state(child_module, fn _state -> original_state end)
    end)

    :ok = GenServer.call(child_module, :reload_config)
    :persistent_term.put({child_module, child_module, :boot_count}, 1)
    Process.whereis(child_module)
  end
end

defmodule ForemanServer.TestSupport.ProjectionStoreReset do
  @moduledoc false
  # Many tests `{:sys.replace_state, ForemanServer.ProjectionStore, fn state -> ...}`-style
  # partial resets that assume every `initial_state/0` key is already
  # present on `state`. A prior failing test that left the GenServer in
  # a partial shape (missing keys like `:project_active_runs` or
  # `:run_slots`) breaks the next test's setup.
  #
  # `reset!/1` performs a full reset that always seeds every key the
  # production `initial_state/0` defines. Subscribers are kept by default:
  # the live singletons (Dispatcher, RunLifecycleReconciler, ...) subscribe
  # once at boot, and dropping that subscription would silently disable them
  # for the rest of the run. Pass `keep_subscribers: false` to clear them.
  @spec reset!(keyword()) :: :ok
  def reset!(opts \\ []) when is_list(opts) do
    # Executors and Dispatcher work left by the previous test must finish
    # before the store is wiped (see `ForemanServer.TestSupport.RunDrain`).
    ForemanServer.TestSupport.RunDrain.drain!()

    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      empty_initial_state(opts, state)
    end)

    :ok
  end

  @doc """
  True when the process registered as `name` is in the live `ProjectionStore`'s subscriber map.
  """
  @spec subscribed?(atom() | pid()) :: boolean()
  def subscribed?(name_or_pid) do
    pid = if is_pid(name_or_pid), do: name_or_pid, else: Process.whereis(name_or_pid)
    is_pid(pid) and Map.has_key?(:sys.get_state(ForemanServer.ProjectionStore).subscribers, pid)
  end

  @doc """
  Raises at once if `name` is not subscribed to the live `ProjectionStore`.

  A live singleton that lost its subscription (`keep_subscribers: false`, or a throwaway/replaced
  store) never sees another event, so a test that waits for it to act on one hangs until its own
  timeout. This names the cause instead. (A supervisor restart of the real store keeps
  subscribers: `ProjectionStore.SubscriberLedger`, foreman-m75e9.)
  """
  @spec assert_subscribed!(atom()) :: :ok
  def assert_subscribed!(name) do
    if subscribed?(name) do
      :ok
    else
      raise "#{inspect(name)} (pid #{inspect(Process.whereis(name))}) is not subscribed to " <>
              "ForemanServer.ProjectionStore: an earlier test replaced the store or reset it " <>
              "with keep_subscribers: false, so no event will ever reach it. " <>
              "Crash-on-purpose tests must use ForemanServer.TestSupport.ThrowawayProjectionStore."
    end
  end

  # `current_state` is the GenServer's live state as handed to us by
  # `:sys.replace_state`'s callback — it is already the correct source
  # for "subscribers before this reset". Do NOT re-fetch it via
  # `:sys.get_state(ForemanServer.ProjectionStore)` here: that callback
  # already runs ON the ProjectionStore process (inside its own
  # `:sys.handle_system_msg`), so a nested `:sys.get_state` call on the
  # same pid is a self-call. OTP detects that and immediately exits
  # `{:calling_self, ...}` — which the old code silently caught and
  # treated as "no subscribers", making `keep_subscribers: true` a
  # permanent no-op regardless of what was actually subscribed.
  #
  # Derives from `ForemanServer.ProjectionStore.initial_state/0` directly
  # (exposed `@doc false` for exactly this) rather than a second
  # hand-maintained key list or a type-inferred guess: a new state field
  # is correct here by construction, for every key present or future,
  # with no special-casing of non-map shapes (e.g. `run_slots`) required.
  defp empty_initial_state(opts, current_state) do
    {subscribers, subscriber_replay} =
      if Keyword.get(opts, :keep_subscribers, true) do
        {Map.get(current_state, :subscribers, %{}), Map.get(current_state, :subscriber_replay, %{})}
      else
        {%{}, %{}}
      end

    %{
      ForemanServer.ProjectionStore.initial_state()
      | subscribers: subscribers,
        subscriber_replay: subscriber_replay
    }
  end
end
