defmodule ForemanServer.Workflow.RunExecutorResumeTest do
  # A run started to continue a provider session (`resume_session: {provider, id}` in the
  # executor's start options) launches its FIRST phase as a plain resume of that session,
  # and refuses to launch on any session it cannot honour. See `run_executor_fork_test.exs`
  # for the fork variant this mirrors.
  use ExUnit.Case, async: false

  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.RunExecutor

  @uuid "3c0e51a8-7d1b-4a45-9c2e-0f6b8a1d2e34"

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp state(extra) do
    Map.merge(
      %{
        run_id: "run-resume-launch",
        plan_context: %{},
        task: %{task_id: "t-resume", project_id: "resume-proj"},
        completed: [],
        phase_specs: [],
        artifact_base: System.tmp_dir!(),
        project_settings: nil
      },
      extra
    )
  end

  defp launch(state, phase_spec, index) do
    RunExecutor.__prepare_agent_launch_for_test__(
      state,
      Map.put_new(phase_spec, :name, :fix),
      index,
      index + 1,
      nil
    )
  end

  defp driver_opts({:ok, launch}), do: launch.driver_opts.(60_000)

  for provider <- ~w(claude pi) do
    test "#{provider}: the first phase resumes the session in place, without a fork" do
      opts =
        %{resume_session: {unquote(provider), @uuid}}
        |> state()
        |> launch(%{provider: unquote(provider)}, 0)
        |> driver_opts()

      assert opts[:provider_session_id] == @uuid
      refute Map.has_key?(Keyword.get(opts, :provider_options, %{}), :fork_session)
    end
  end

  test "a later phase starts its own session" do
    opts =
      %{resume_session: {"claude", @uuid}}
      |> state()
      |> launch(%{provider: "claude"}, 1)
      |> driver_opts()

    refute Keyword.has_key?(opts, :provider_session_id)
  end

  test "a run with no resume_session launches without any session option" do
    opts = %{resume_session: nil} |> state() |> launch(%{provider: "claude"}, 0) |> driver_opts()
    refute Keyword.has_key?(opts, :provider_session_id)
  end

  test "a phase on another provider than the session's refuses to launch, naming both" do
    assert {:error, {:resume_provider_mismatch, "claude", "pi"}} =
             %{resume_session: {"claude", @uuid}} |> state() |> launch(%{provider: "pi"}, 0)
  end

  test "a session id that could be read as a CLI flag is refused" do
    assert {:error, {:invalid_fork_session, :session_id, "--dangerous"}} =
             %{resume_session: {"claude", "--dangerous"}}
             |> state()
             |> launch(%{provider: "claude"}, 0)
  end

  test "a provider outside the closed list is refused" do
    assert {:error, {:invalid_fork_session, :provider, "gemini"}} =
             %{resume_session: {"gemini", @uuid}} |> state() |> launch(%{provider: "gemini"}, 0)
  end

  test "asking for a fork and a resume of one phase is refused" do
    task = %{task_id: "t", project_id: "p", fork_provider: "claude", fork_session_id: @uuid}

    assert {:error, :fork_and_resume_session} =
             %{task: task, resume_session: {"claude", @uuid}}
             |> state()
             |> launch(%{provider: "claude"}, 0)
  end
end
