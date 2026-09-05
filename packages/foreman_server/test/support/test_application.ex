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
  # production `initial_state/0` defines. Pass `:keep_subscribers` to
  # avoid clobbering active subscribers (the default clobbers them,
  # which matches the existing test-suite behavior in
  # `queue_controller_test.exs`).
  @spec reset!(keyword()) :: :ok
  def reset!(opts \\ []) when is_list(opts) do
    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      empty_initial_state(opts, state)
    end)

    :ok
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
  defp empty_initial_state(opts, current_state) do
    subscribers =
      if Keyword.get(opts, :keep_subscribers, false) do
        Map.get(current_state, :subscribers, %{})
      else
        %{}
      end

    %{
      projects: %{},
      runs: %{},
      tasks: %{},
      phases: %{},
      pr_associations: %{},
      run_logs: %{},
      scheduler_intents: %{},
      subscribers: subscribers,
      project_active_runs: %{},
      worktrees: %{},
      worktree_create_orphans: %{},
      run_slots: %{capacity: 0, holders: %{}, waiters: []},
      works: %{},
      inbox_threads: %{}
    }
  end
end
