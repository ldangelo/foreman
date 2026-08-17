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
    :sys.replace_state(ForemanServer.ProjectionStore, fn _state ->
      empty_initial_state(opts)
    end)
    :ok
  end

  defp empty_initial_state(opts) do
    subscribers =
      if Keyword.get(opts, :keep_subscribers, false) and
           Process.whereis(ForemanServer.ProjectionStore) do
        try do
          :sys.get_state(ForemanServer.ProjectionStore).subscribers || %{}
        catch
          :exit, _ -> %{}
        end
      else
        %{}
      end

    %{
      projects: %{},
      runs: %{},
      tasks: %{},
      phases: %{},
      pr_associations: %{},
      scheduler_intents: %{},
      subscribers: subscribers,
      project_active_runs: %{},
      worktrees: %{},
      worktree_create_orphans: %{},
      run_slots: %{capacity: 0, holders: %{}, waiters: []},
      works: %{}
    }
  end
end
