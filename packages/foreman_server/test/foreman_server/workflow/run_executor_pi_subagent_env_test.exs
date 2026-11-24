defmodule ForemanServer.Workflow.RunExecutorPiSubagentEnvTest do
  # Foreman-launched pi workers are marked as child sessions so machine-wide pi
  # extensions (pi-advisor-flow, pi-subagents) do not override the model Foreman
  # resolved for the phase. Non-pi providers are unaffected.
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectSettings
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.RunExecutor

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp env(phase_spec) do
    {:ok, launch} =
      RunExecutor.__prepare_agent_launch_for_test__(
        %{
          run_id: "run-pi-subagent",
          plan_context: %{},
          task: %{task_id: "t1", project_id: "pi-subagent-proj"},
          completed: [],
          phase_specs: [],
          artifact_base: System.tmp_dir!(),
          project_settings: %ProjectSettings{}
        },
        Map.put_new(phase_spec, :name, :implement),
        0,
        1,
        nil
      )

    Keyword.fetch!(launch.launch_opts, :env_map)
  end

  test "a pi phase is launched marked as a pi child session" do
    assert env(%{})["PI_SUBAGENT_CHILD"] == "1"
    assert env(%{provider: :pi})["PI_SUBAGENT_CHILD"] == "1"
  end

  test "a non-pi phase is not marked" do
    refute Map.has_key?(env(%{provider: "claude"}), "PI_SUBAGENT_CHILD")
  end

  test "a project environment value does not replace the marker" do
    previous = Application.get_env(:foreman_server, :worker_environment)

    Application.put_env(:foreman_server, :worker_environment, %{
      projects: %{"pi-subagent-proj" => %{env: %{"PI_SUBAGENT_CHILD" => "0"}}}
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:foreman_server, :worker_environment, previous),
        else: Application.delete_env(:foreman_server, :worker_environment)
    end)

    assert env(%{provider: :pi})["PI_SUBAGENT_CHILD"] == "1"
  end
end
