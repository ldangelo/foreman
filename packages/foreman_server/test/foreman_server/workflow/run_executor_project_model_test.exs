defmodule ForemanServer.Workflow.RunExecutorProjectModelTest do
  # Project `thread_model` / `thread_effort` reach the agent launch on the
  # workflow door. Precedence: phase `models.default` > project thread_model >
  # provider default. Effort is delivered only where the provider declares it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.{ProjectionStore, ProjectSettings}
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.{PreflightFailure, RunExecutor}

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp state(settings, project_id \\ "model-proj") do
    %{
      run_id: "run-model",
      plan_context: %{},
      task: %{task_id: "t1", project_id: project_id},
      completed: [],
      phase_specs: [],
      artifact_base: System.tmp_dir!(),
      project_settings: settings
    }
  end

  defp launch(state, phase_spec) do
    {:ok, launch} =
      RunExecutor.__prepare_agent_launch_for_test__(
        state,
        Map.put_new(phase_spec, :name, :implement),
        0,
        1,
        nil
      )

    launch
  end

  defp driver_opts(launch), do: launch.driver_opts.(60_000)
  defp env(launch), do: Keyword.fetch!(launch.launch_opts, :env_map)

  test "phase models.default wins over the project thread_model" do
    launch =
      launch(state(%ProjectSettings{thread_model: "proj-m"}), %{models: %{default: "phase-m"}})

    assert driver_opts(launch)[:model] == "phase-m"
    assert env(launch)["FOREMAN_MODEL"] == "phase-m"
  end

  test "a phase without models launches with the project thread_model" do
    launch = launch(state(%ProjectSettings{thread_model: "proj-m"}), %{})

    assert driver_opts(launch)[:model] == "proj-m"
    assert env(launch)["FOREMAN_MODEL"] == "proj-m"
  end

  test "no project model and no phase model: no :model key at all" do
    launch = launch(state(%ProjectSettings{}), %{})

    refute Keyword.has_key?(driver_opts(launch), :model)
    refute Map.has_key?(env(launch), "FOREMAN_MODEL")
  end

  test "an unscoped run (no project settings) is unchanged" do
    launch = launch(state(nil, nil), %{})

    refute Keyword.has_key?(driver_opts(launch), :model)
    refute Keyword.has_key?(driver_opts(launch), :reasoning_effort)
  end

  # TRD-007-TEST (AC-005-2, AC-006-1, AC-006-2). Where the launch hands the driver
  # its model, one log line records WHICH model and WHICH rule chose it, plus the
  # workflow manifest the phase came from — so a later mismatch ("the run used a
  # model nobody declared") is attributable from the record instead of guessed.
  describe "per-phase model resolution record" do
    setup do
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)
    end

    defp launch_with_log(state, phase_spec) do
      parent = self()

      log =
        capture_log([level: :info], fn -> send(parent, {:launch, launch(state, phase_spec)}) end)

      assert_received {:launch, launch}
      {launch, log}
    end

    defp logged_model(log) do
      [_whole, model] = Regex.run(~r/ model=(\S+) source=/, log)
      model
    end

    test "a declared model beats the project's, and the record names the phase as the winner" do
      {launch, log} =
        launch_with_log(state(%ProjectSettings{thread_model: "proj-m"}), %{
          provider: "pi",
          models: %{default: "phase-m"}
        })

      assert driver_opts(launch)[:model] == "phase-m"
      assert log =~ ~s(model resolution: provider=pi model="phase-m" source=phase_declared)
      refute log =~ "proj-m"
    end

    test "a phase that declares none is filled from the project's thread_model, and says so" do
      {launch, log} = launch_with_log(state(%ProjectSettings{thread_model: "proj-m"}), %{})

      assert driver_opts(launch)[:model] == "proj-m"
      assert log =~ ~s(model="proj-m" source=project_thread_model)
    end

    test "with no declared and no project model nothing is passed, and the record says so" do
      {launch, log} = launch_with_log(state(%ProjectSettings{}), %{})

      refute Keyword.has_key?(driver_opts(launch), :model)
      assert log =~ "model=nil source=provider_default"
    end

    test "an unscoped run (no project settings) still records its resolution" do
      {launch, log} = launch_with_log(state(nil, nil), %{})

      refute Keyword.has_key?(driver_opts(launch), :model)
      assert log =~ "model=nil source=provider_default"
    end

    test "the recorded model is the model the driver and the agent environment received" do
      for {settings, phase} <- [
            {%ProjectSettings{thread_model: "proj-m"}, %{models: %{default: "phase-m"}}},
            {%ProjectSettings{thread_model: "proj-m"}, %{}},
            {%ProjectSettings{}, %{models: %{default: "phase-m"}}},
            {%ProjectSettings{}, %{}}
          ] do
        {launch, log} = launch_with_log(state(settings), phase)

        assert logged_model(log) == inspect(driver_opts(launch)[:model])
        assert logged_model(log) == inspect(env(launch)["FOREMAN_MODEL"])
      end
    end

    test "the record names the workflow and manifest from the frozen snapshot, in either key convention" do
      path = "/home/u/.foreman/workflows/fix.yaml"

      for snapshot <- [
            %{"workflow_name" => "fix", "manifest_path" => path},
            %{workflow_name: "fix", manifest_path: path}
          ] do
        state = state(%ProjectSettings{})
        state = %{state | task: Map.put(state.task, :workflow_snapshot, snapshot)}

        {_launch, log} = launch_with_log(state, %{})

        assert log =~ ~s(workflow="fix" manifest="#{path}")
      end
    end

    test "a run with no frozen snapshot still launches and records the workflow as unknown" do
      {_launch, log} = launch_with_log(state(%ProjectSettings{}), %{})

      assert log =~ "workflow=nil manifest=nil"
    end
  end

  test "thread_effort is delivered as reasoning_effort for a provider that declares it" do
    launch = launch(state(%ProjectSettings{thread_effort: "high"}), %{provider: "claude"})
    assert driver_opts(launch)[:reasoning_effort] == :high
  end

  test "thread_effort is absent when unset" do
    launch = launch(state(%ProjectSettings{}), %{provider: "claude"})
    refute Keyword.has_key?(driver_opts(launch), :reasoning_effort)
  end

  test "thread_effort is dropped with an info log when the provider does not declare it" do
    previous = Application.get_env(:jido_harness, :providers)
    Application.put_env(:jido_harness, :providers, %{claude: __MODULE__.NoEffortAdapter})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:jido_harness, :providers, previous),
        else: Application.delete_env(:jido_harness, :providers)
    end)

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log([level: :info], fn ->
        launch = launch(state(%ProjectSettings{thread_effort: "high"}), %{provider: "claude"})
        refute Keyword.has_key?(driver_opts(launch), :reasoning_effort)
      end)

    assert log =~ "reasoning_effort ignored for provider claude"
  end

  test "the executor latches the project's registered settings" do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: "latch-proj", path: "/tmp/latch", config: %{thread_model: "m1"}}
        }
      ])

    assert %ProjectSettings{thread_model: "m1"} =
             RunExecutor.__latch_project_settings_for_test__(%{project_id: "latch-proj"})

    assert RunExecutor.__latch_project_settings_for_test__(%{}) == nil
  end

  describe "preflight" do
    setup do
      original_path = System.get_env("PATH")

      bin_dir =
        Path.join(System.tmp_dir!(), "model-preflight-#{System.unique_integer([:positive])}")

      File.mkdir_p!(bin_dir)

      # `pi --list-models X` answers "not found"; anything else is a version probe.
      File.write!(Path.join(bin_dir, "pi"), """
      #!/bin/sh
      if [ "$1" = "--list-models" ]; then
        echo "No models matching \\"$2\\""
        exit 0
      fi
      echo "1.2.0"
      """)

      File.chmod!(Path.join(bin_dir, "pi"), 0o755)
      System.put_env("PATH", bin_dir <> ":" <> (original_path || ""))

      on_exit(fn ->
        System.put_env("PATH", original_path || "")
        File.rm_rf!(bin_dir)
      end)
    end

    test "checks the project's fallback model against the catalog" do
      state = %{
        state(%ProjectSettings{thread_model: "ghost/model"})
        | phase_specs: [%{name: :implement}]
      }

      assert {:error,
              [
                %{
                  class: :model_not_found,
                  model: "ghost/model",
                  model_source: :project_thread_model
                }
              ]} = RunExecutor.__preflight_for_test__(state)
    end

    test "a phase's own models.default is still what gets checked when declared" do
      state = %{
        state(%ProjectSettings{thread_model: "ghost/model"})
        | phase_specs: [%{name: :implement, models: %{default: "other/model"}}]
      }

      assert {:error, [%{model: "other/model", model_source: :phase_declared}]} =
               RunExecutor.__preflight_for_test__(state)
    end

    # AC-005-1 / AC-006-2: the refusal names the rule that chose the string, so the
    # fix lands on the right artifact (the manifest, or `foreman project update`).
    test "the refusal's one-line summary names where the model came from" do
      declared = %{
        state(%ProjectSettings{thread_model: "ghost/model"})
        | phase_specs: [%{name: :implement, models: %{default: "other/model"}}]
      }

      filled = %{
        state(%ProjectSettings{thread_model: "ghost/model"})
        | phase_specs: [%{name: :implement}]
      }

      assert {:error, [declared_failure]} = RunExecutor.__preflight_for_test__(declared)
      assert {:error, [filled_failure]} = RunExecutor.__preflight_for_test__(filled)

      assert PreflightFailure.summarize(declared_failure) =~
               "the model comes from the phase's models.default"

      assert PreflightFailure.summarize(filled_failure) =~
               "the model comes from the project's thread_model"
    end

    test "a provider-level refusal for a phase with no model records the provider default" do
      state = %{
        state(%ProjectSettings{})
        | phase_specs: [%{name: :implement, provider: "kimi"}]
      }

      assert {:error,
              [%{class: :provider_unsupported, model: nil, model_source: :provider_default}]} =
               RunExecutor.__preflight_for_test__(state)
    end
  end

  defmodule NoEffortAdapter do
    @behaviour Jido.Harness.Adapter

    @impl true
    def spec do
      %Jido.Harness.AdapterSpec{
        provider: :claude,
        name: "claude without effort",
        executable: "claude",
        capabilities: %Jido.Harness.Capabilities{streaming?: true, resume?: true},
        normalized_options: [:model],
        provider_options: []
      }
    end

    @impl true
    def status(_config) do
      {:ok, %Jido.Harness.ProviderStatus{provider: :claude, installed: true, compatible: true}}
    end

    @impl true
    def run(_request, _context), do: {:error, :not_used}
  end
end
