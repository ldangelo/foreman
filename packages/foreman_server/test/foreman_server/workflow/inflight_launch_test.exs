defmodule ForemanServer.Workflow.InflightLaunchTest do
  @moduledoc """
  Which phase launches get the in-flight permission tool (bead foreman-exofh): only a
  claude phase whose effective `approval_mode` is `prompt`. pi has no per-call
  approvals (spike S2) and every other mode already decides tools up front, so they
  keep the E8 phase-pause path and get no permission endpoint.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.RunExecutor

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServerWeb.Presence, ForemanServerWeb.Presence)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)
    ensure_started(ForemanServer.CommandRouter, ForemanServer.CommandRouter)
    ensure_started(ForemanServer.TaskProvider.Registry, ForemanServer.TaskProvider.Registry)

    ensure_started(
      {Registry, keys: :unique, name: ForemanServer.RunExecutorRegistry},
      ForemanServer.RunExecutorRegistry
    )

    ensure_started(
      ForemanServer.AgentRuntime.AdapterCatalog,
      ForemanServer.AgentRuntime.AdapterCatalog
    )

    ensure_started(ForemanServer.Workflow.Catalog, ForemanServer.Workflow.Catalog)
    ensure_started(ForemanServer.RunControl, ForemanServer.RunControl)
    :ok
  end

  setup do
    previous = Application.get_env(:foreman_server, :approvals)
    Application.put_env(:foreman_server, :approvals, inflight_base_url: "http://127.0.0.1:4766")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:foreman_server, :approvals, previous),
        else: Application.delete_env(:foreman_server, :approvals)
    end)

    :ok
  end

  defp opts(provider, approval_mode) do
    run_id = "run-inflight-#{System.unique_integer([:positive])}"

    projection = %{
      task_id: "task-#{run_id}",
      project_id: "project-#{run_id}",
      working_directory: System.tmp_dir!(),
      workflow_type: "implement",
      workflow_snapshot: %{
        "workflow_name" => "implement",
        "workflow_digest" => "digest-inflight",
        "worktree" => %{"enabled" => false},
        "phases" => [%{"name" => "code-generation"}]
      }
    }

    {:ok, state} = RunExecutor.init({run_id, projection, []})

    spec =
      %{name: "code-generation", provider: provider, approval_mode: approval_mode}
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    assert {:ok, %{driver_opts: driver_opts}} = RunExecutor.phase_launch(state, spec, 0, nil)
    {run_id, driver_opts.(60_000)}
  end

  test "a claude phase in prompt mode routes permission prompts to Foreman, scoped to its run" do
    {run_id, driver_opts} = opts("claude", "prompt")

    assert driver_opts[:approval_mode] == :prompt

    # `live_input` is the live-steering option (config `:live_steering`, on by default).
    assert driver_opts[:provider_options] == %{
             cli_path: ForemanServer.Approvals.Inflight.wrapper_path(),
             live_input: true
           }

    assert %{"foreman_permission" => %{"type" => "http", "url" => url, "headers" => headers}} =
             driver_opts[:mcp_config]

    assert url == "http://127.0.0.1:4766/agent-permission/#{run_id}"

    assert headers == %{
             "Authorization" => "Bearer " <> ForemanServer.Approvals.Inflight.token(run_id)
           }
  end

  test "pi, other approval modes and an unset mode keep the phase-pause path" do
    for {provider, mode} <- [
          {"pi", "prompt"},
          {"claude", "auto_edit"},
          {"claude", "auto_approve"},
          {"claude", nil}
        ] do
      {_run_id, driver_opts} = opts(provider, mode)

      refute Keyword.has_key?(driver_opts, :mcp_config),
             "#{provider}/#{inspect(mode)} must not get a permission endpoint"

      # Only the live-steering option may be present: never the permission wrapper.
      assert Map.drop(Keyword.get(driver_opts, :provider_options, %{}), [:live_input]) == %{}
    end
  end

  test "`inflight: false` keeps claude prompt mode on the phase-pause path" do
    Application.put_env(:foreman_server, :approvals,
      inflight: false,
      inflight_base_url: "http://127.0.0.1:4766"
    )

    {_run_id, driver_opts} = opts("claude", "prompt")
    refute Keyword.has_key?(driver_opts, :mcp_config)
  end

  defp ensure_started(child_spec, name) do
    case Process.whereis(name) do
      nil -> start_supervised!(child_spec)
      _pid -> :ok
    end
  end
end
