defmodule ForemanServer.Workflow.RunExecutorSandboxTest do
  # The run-level sandbox decision: which provider a manifest's `sandbox:` selects and
  # which runs refuse it. Pure over the executor state; no docker is started.
  use ExUnit.Case, async: true

  alias ForemanServer.Jobsite.Sandboxes.Docker
  alias ForemanServer.Workflow.RunExecutor

  defp state(overrides), do: Map.merge(%{run_id: "run-sbx-1", task: %{}}, overrides)

  test "no sandbox key, or a nil one, runs on the host" do
    assert {:ok, nil, cleanup} = RunExecutor.__run_sandbox_for_test__(state(%{}))
    assert cleanup.() == :ok
    assert {:ok, nil, _} = RunExecutor.__run_sandbox_for_test__(state(%{sandbox: nil}))
  end

  test "docker selects the Docker provider with an empty config when no project policy applies" do
    assert {:ok, %{provider: Docker, config: config}, cleanup} =
             RunExecutor.__run_sandbox_for_test__(state(%{sandbox: "docker"}))

    assert config == %{}
    assert cleanup.() == :ok
  end

  test "a multi-repo run refuses the sandbox: the extra worktrees are not mounted" do
    assert {:error, {:sandbox_unsupported, :multi_repo}} =
             RunExecutor.__run_sandbox_for_test__(
               state(%{sandbox: "docker", run_repos: %{primary: "main", extras: ["b"]}})
             )
  end
end
