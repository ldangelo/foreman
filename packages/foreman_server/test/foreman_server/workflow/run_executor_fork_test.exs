defmodule ForemanServer.Workflow.RunExecutorForkTest do
  # `adopt --continue --fork`: a task that carries a provider session (`fork_provider`,
  # `fork_session_id`, set on `TaskCreated`) launches the FIRST phase of its run as a fork of that
  # session, on the provider's own terms (`ForkSession`), and refuses to launch when the phase's provider
  # is not the session's. Later phases and ordinary tasks are untouched.
  use ExUnit.Case, async: false

  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.RunExecutor

  @uuid "3c0e51a8-7d1b-4a45-9c2e-0f6b8a1d2e34"

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp state(task_extra) do
    %{
      run_id: "run-fork-launch",
      plan_context: %{},
      task: Map.merge(%{task_id: "t-fork", project_id: "fork-proj"}, task_extra),
      completed: [],
      phase_specs: [],
      artifact_base: System.tmp_dir!(),
      project_settings: nil
    }
  end

  defp launch(state, phase_spec, index) do
    RunExecutor.__prepare_agent_launch_for_test__(
      state,
      Map.put_new(phase_spec, :name, :implement),
      index,
      index + 1,
      nil
    )
  end

  defp driver_opts({:ok, launch}), do: launch.driver_opts.(60_000)

  test "claude: the first phase resumes the session and forks it" do
    opts =
      %{fork_provider: "claude", fork_session_id: @uuid}
      |> state()
      |> launch(%{provider: "claude"}, 0)
      |> driver_opts()

    assert opts[:provider_session_id] == @uuid
    assert opts[:provider_options][:fork_session] == true
  end

  test "pi: the first phase forks the session and carries no provider_session_id" do
    opts =
      %{fork_provider: "pi", fork_session_id: @uuid}
      |> state()
      |> launch(%{provider: "pi"}, 0)
      |> driver_opts()

    assert opts[:provider_options][:fork_session] == @uuid
    refute Keyword.has_key?(opts, :provider_session_id)
  end

  test "a later phase starts its own session, like any phase" do
    opts =
      %{fork_provider: "claude", fork_session_id: @uuid}
      |> state()
      |> launch(%{provider: "claude"}, 1)
      |> driver_opts()

    refute Keyword.has_key?(opts, :provider_session_id)
    refute Map.has_key?(Keyword.get(opts, :provider_options, %{}), :fork_session)
  end

  test "an ordinary task launches without any session option" do
    opts = %{} |> state() |> launch(%{provider: "claude"}, 0) |> driver_opts()

    refute Keyword.has_key?(opts, :provider_session_id)
    refute Map.has_key?(Keyword.get(opts, :provider_options, %{}), :fork_session)
  end

  test "a phase on another provider than the session's refuses to launch, naming both" do
    assert {:error, {:fork_provider_mismatch, "claude", "pi"}} =
             %{fork_provider: "claude", fork_session_id: @uuid}
             |> state()
             |> launch(%{provider: "pi"}, 0)

    # A phase that names no provider runs on the default (pi): a claude session cannot be forked there.
    assert {:error, {:fork_provider_mismatch, "claude", "pi"}} =
             %{fork_provider: "claude", fork_session_id: @uuid}
             |> state()
             |> launch(%{}, 0)
  end
end
