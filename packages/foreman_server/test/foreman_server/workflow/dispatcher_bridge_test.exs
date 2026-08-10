defmodule ForemanServer.Workflow.DispatcherBridgeTest do
  @moduledoc """
  Regression test for the approval → dispatch → run.start pipeline.

  Exercises the actual wired Dispatcher GenServer (subscribed to
  ProjectionStore in `Application.start/2`) end-to-end through the public
  CommandGateway operators. Asserts that:

    1. project.register + task.create + task.approve project the task to
       status `ready`.
    2. Within a bounded window the Dispatcher reacts to `TaskApproved`
       by issuing `task.dispatch`, which lands a `TaskDispatched`
       event and projects the task to status `in_progress`.
    3. The Dispatcher then reacts to `TaskDispatched` by issuing
       `run.start`, which creates a run projection bound to the same
       run_id derived from `(task_id, approval_id)`.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, ProjectionStore}

  @poll_timeout_ms 8_000

  defp poll_until(fun, message \\ "condition") do
    deadline = System.monotonic_time(:millisecond) + @poll_timeout_ms
    do_poll(fun, deadline, message)
  end

  defp do_poll(fun, deadline, message) do
    case fun.() do
      {:ok, value} ->
        value

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for #{message} (last: #{inspect(other)})")
        else
          Process.sleep(25)
          do_poll(fun, deadline, message)
        end
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)
    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServerWeb.Presence, ForemanServerWeb.Presence)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)
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
    ensure_started(ForemanServer.Workflow.RunSupervisor, ForemanServer.Workflow.RunSupervisor)
    ensure_started(ForemanServer.Workflow.Dispatcher, ForemanServer.Workflow.Dispatcher)
    ensure_started(ForemanServer.CommandRouter, ForemanServer.CommandRouter)

    on_exit(fn -> terminate_run_supervisor_children() end)

    :ok
  end

  defp terminate_run_supervisor_children do
    sup = Process.whereis(ForemanServer.Workflow.RunSupervisor)

    if sup do
      ForemanServer.Workflow.RunSupervisor.which_runs()
      |> Enum.each(fn
        {_id, pid, _type, _modules} when is_pid(pid) ->
          terminate_run_supervisor_child(sup, pid)

        _ ->
          :ok
      end)
    end

    :ok
  end

  defp terminate_run_supervisor_child(sup, pid) do
    :ok = DynamicSupervisor.terminate_child(sup, pid)
  end

  defp unique_id(prefix) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    "#{prefix}-dispatcher-bridge-#{suffix}"
  end

  defp wait_for_status(task_id, target) do
    poll_until(
      fn ->
        case ProjectionStore.task_projection(task_id) do
          %{status: ^target} = task -> {:ok, task}
          %{status: other} -> {:error, {:status, other}}
          nil -> {:error, :missing}
        end
      end,
      "task #{task_id} status=#{target}"
    )
  end

  defp wait_for_active_run_reservation(project_id, run_id) do
    poll_until(
      fn ->
        active_runs = ProjectionStore.list_projects_with_active_runs()

        case Enum.find(active_runs, fn {listed_project_id, run_ids} ->
               listed_project_id == project_id and run_id in run_ids
             end) do
          {^project_id, run_ids} ->
            {:ok, run_ids}

          nil ->
            {:error, active_runs}
        end
      end,
      "active run reservation #{project_id}/#{run_id}"
    )
  end

  defp wait_for_run(run_id) do
    poll_until(
      fn ->
        case ProjectionStore.run(run_id) do
          %{run_id: ^run_id} = run -> {:ok, run}
          %{run_id: other} -> {:error, {:run_id_mismatch, other}}
          nil -> {:error, :missing}
        end
      end,
      "run #{run_id}"
    )
  end

  defp wait_for_project(project_id) do
    poll_until(
      fn ->
        case ProjectionStore.project_projection(project_id) do
          %{project_id: ^project_id} = project -> {:ok, project}
          nil -> {:error, :missing}
        end
      end,
      "project #{project_id}"
    )
  end

  describe "approval → dispatch → run.start bridge" do
    test "TaskApproved triggers task.dispatch then run.start via the wired Dispatcher" do
      project_id = unique_id("proj")
      task_id = unique_id("task")
      approval_id = unique_id("approval")

      # task.create aggregate requires a registered project (its
      # validate_project_allows_tasks guard). Pre-create one via raw
      # command dispatch — `project.register` is an operator type.
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "test-#{project_id}",
                 aggregate_id: "project:#{project_id}",
                 type: "project.register",
                 payload: %{
                   project_id: project_id,
                   name: "Dispatcher Bridge #{project_id}",
                   path: System.tmp_dir!()
                 }
               })

      wait_for_project(project_id)

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "test-#{task_id}",
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "implement",
                   title: "bridge test"
                 }
               })

      _ = wait_for_status(task_id, "open")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: approval_id,
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{
                   task_id: task_id,
                   approved_by: "dispatcher-bridge-test"
                 }
               })

      approved = wait_for_status(task_id, "ready")
      assert approved.approval_id
      assert approved.run_id
      assert approved.workflow_snapshot

      run_id = approved.run_id

      reserved_runs = wait_for_active_run_reservation(project_id, run_id)
      assert run_id in reserved_runs

      dispatched = wait_for_status(task_id, "in_progress")
      assert dispatched.run_id == run_id

      run = wait_for_run(run_id)
      assert run.task_id == task_id

      refute is_nil(run.status) or run.status == "",
             "run #{run_id} should have a status, got: #{inspect(run)}"
    end
  end

  defp ensure_started(child_spec, name) do
    if Process.whereis(name) do
      :ok
    else
      start_supervised!(child_spec)
      :ok
    end
  end
end
