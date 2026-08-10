defmodule ForemanServer.Workflow.DispatcherTest do
  @moduledoc """
  Tests for `ForemanServer.Workflow.Dispatcher` terminal-event coverage.

  Verifies that when `ProjectionStore` broadcasts a terminal run event
  (`RunCancelled`, `RunFlaggedStuck`, `RunCompleted`, `RunFailed`), the
  Dispatcher forwards it to `BootReconciliation.run_terminated/2` so the
  orphan-task scan and dispatch path mirrors the boot path. Earlier
  builds only reacted to `RunCancelled`; this test pins the full set.

  Tests call `Dispatcher.handle_info({:projection_event, envelope}, ...)`
  directly so they exercise the dispatcher's pattern-matching without
  polluting the shared ProjectionStore with synthetic fixtures.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.BootReconciliation
  alias ForemanServer.Workflow.Dispatcher

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
    ensure_started(ForemanServer.Workflow.RunSupervisor, ForemanServer.Workflow.RunSupervisor)
    ensure_started(ForemanServer.Workflow.Dispatcher, ForemanServer.Workflow.Dispatcher)

    ensure_started(
      ForemanServer.Workflow.BootReconciliation,
      ForemanServer.Workflow.BootReconciliation
    )

    :ok
  end

  setup do
    parent = self()
    boot_name = ForemanServer.Workflow.BootReconciliation
    real_pid = Process.whereis(boot_name)

    forwarder =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        forward_loop(parent)
      end)

    Process.unregister(boot_name)
    :erlang.register(boot_name, forwarder)

    on_exit(fn ->
      if Process.whereis(boot_name) == forwarder do
        Process.unregister(boot_name)
      end

      if Process.alive?(real_pid) do
        :erlang.register(boot_name, real_pid)
      end

      Process.exit(forwarder, :kill)
    end)

    :ok
  end

  describe "terminal run events fan out to BootReconciliation.run_terminated/2" do
    test "RunCancelled uses default reason 'run_cancelled'" do
      send_envelope(%{event_type: "RunCancelled", data: %{run_id: "run-x", status: "cancelled"}})
      assert_receive {:"$gen_cast", {:run_terminated, "run-x", "run_cancelled"}}, 500
    end

    test "RunFlaggedStuck uses default reason 'run_flagged_stuck'" do
      send_envelope(%{
        event_type: "RunFlaggedStuck",
        data: %{run_id: "run-x", flagged_at: 1_700_000_000_000}
      })

      assert_receive {:"$gen_cast", {:run_terminated, "run-x", "run_flagged_stuck"}}, 500
    end

    test "RunCompleted uses default reason 'run_completed'" do
      send_envelope(%{event_type: "RunCompleted", data: %{run_id: "run-x", status: "completed"}})

      assert_receive {:"$gen_cast", {:run_terminated, "run-x", "run_completed"}}, 500
    end

    test "RunFailed uses default reason 'run_failed'" do
      send_envelope(%{
        event_type: "RunFailed",
        data: %{run_id: "run-x", status: "failed", failure_reason: "boom"}
      })

      assert_receive {:"$gen_cast", {:run_terminated, "run-x", "run_failed"}}, 500
    end
  end

  describe "reason override and missing run_id" do
    test "payload reason overrides event_type default" do
      send_envelope(%{
        event_type: "RunCancelled",
        data: %{run_id: "run-x", reason: "operator_supplied", status: "cancelled"}
      })

      assert_receive {:"$gen_cast", {:run_terminated, "run-x", "operator_supplied"}}, 500
    end

    test "missing run_id is a no-op (no crash, no dispatch)" do
      send_envelope(%{
        event_type: "RunCancelled",
        data: %{project_id: "project-x", status: "cancelled"}
      })

      refute_receive {:"$gen_cast", {:run_terminated, _, _}}, 100
    end

    test "non-terminal events do not trigger run_terminated" do
      send_envelope(%{event_type: "TaskApproved", data: %{task_id: "task-x"}})
      refute_receive {:"$gen_cast", {:run_terminated, _, _}}, 100
    end

    test "string-keyed envelope is dispatched" do
      send_envelope(%{
        "event_type" => "RunCancelled",
        "data" => %{run_id: "run-x", status: "cancelled"}
      })

      assert_receive {:"$gen_cast", {:run_terminated, "run-x", "run_cancelled"}}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp send_envelope(envelope) do
    pid = Process.whereis(Dispatcher)
    # Calling handle_info directly so the dispatcher's pattern-matching runs
    # without going through ProjectionStore (no shared-state pollution).
    {:noreply, _state} = Dispatcher.handle_info({:projection_event, envelope}, %{pending: %{}})
    _ = pid
  end

  defp forward_loop(parent) do
    receive do
      {:EXIT, _, _} ->
        :ok

      msg ->
        send(parent, msg)
        forward_loop(parent)
    end
  end

  defp ensure_started(child_spec, name) do
    case Process.whereis(name) do
      nil -> start_supervised!(child_spec)
      _pid -> :ok
    end
  end
end
