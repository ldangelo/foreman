defmodule ForemanServer.OperationsHelpersTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{
    EventStore,
    Operations.Inspect,
    Operations.Manual
  }

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-ops-helpers-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    previous_env = [
      event_log_path: Application.get_env(:foreman_server, :event_log_path),
      project_store_path: Application.get_env(:foreman_server, :project_store_path)
    ]

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    Application.put_env(:foreman_server, :project_store_path, Path.join(tmp_dir, "projects.term"))
    :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)

      Enum.each(previous_env, fn {key, value} ->
        if is_nil(value) do
          Application.delete_env(:foreman_server, key)
        else
          Application.put_env(:foreman_server, key, value)
        end
      end)

      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  # --- Operations.Inspect ---

  test "run_state/1 returns nil for unknown run_id" do
    assert Inspect.run_state("nonexistent") |> is_nil()
  end

  test "run_state/1 returns run entry when run exists in projection" do
    run_id = "run-#{unique_id()}"

    {:ok, _} =
      EventStore.append(%{
        stream_id: "run:#{run_id}",
        event_type: "RunStarted",
        payload: %{run_id: run_id, task_id: "task-1", project_id: "proj-1"},
        metadata: %{}
      })

    result = Inspect.run_state(run_id)
    assert is_map(result)
    assert result.run_id == run_id
  end

  test "list_active_runs/0 returns empty list when no runs exist" do
    assert Inspect.list_active_runs() == []
  end

  test "list_active_runs/0 excludes terminal runs" do
    active_id = "active-#{unique_id()}"
    done_id = "done-#{unique_id()}"

    {:ok, _} =
      EventStore.append(%{
        stream_id: "run:#{active_id}",
        event_type: "RunStarted",
        payload: %{run_id: active_id, task_id: "task-1", project_id: "proj-1"},
        metadata: %{}
      })

    {:ok, _} =
      EventStore.append(%{
        stream_id: "run:#{done_id}",
        event_type: "RunStarted",
        payload: %{run_id: done_id, task_id: "task-1", project_id: "proj-1"},
        metadata: %{}
      })

    {:ok, _} =
      EventStore.append(%{
        stream_id: "run:#{done_id}",
        event_type: "RunCompleted",
        payload: %{run_id: done_id},
        metadata: %{}
      })

    active = Inspect.list_active_runs()
    active_ids = active |> Enum.map(& &1.run_id)

    assert active_id in active_ids
    refute done_id in active_ids
  end

  # --- Operations.Manual ---

  test "force_complete/1 dispatches run.complete through CommandRouter" do
    run_id = "force-#{unique_id()}"

    {:ok, _} =
      EventStore.append(%{
        stream_id: "run:#{run_id}",
        event_type: "RunStarted",
        payload: %{run_id: run_id, task_id: "task-1", project_id: "proj-1"},
        metadata: %{}
      })

    assert {:ok, %{event: event}} = Manual.force_complete(run_id)
    assert event.event_type == "RunCompleted"
    assert event.payload.run_id == run_id
  end

  test "force_complete/1 returns RunAlreadyCompleted for already-completed run" do
    run_id = "idempotent-#{unique_id()}"

    {:ok, _} =
      EventStore.append(%{
        stream_id: "run:#{run_id}",
        event_type: "RunStarted",
        payload: %{run_id: run_id, task_id: "task-1", project_id: "proj-1"},
        metadata: %{}
      })

    {:ok, _} =
      EventStore.append(%{
        stream_id: "run:#{run_id}",
        event_type: "RunCompleted",
        payload: %{run_id: run_id},
        metadata: %{}
      })

    assert {:ok, %{event: event}} = Manual.force_complete(run_id)
    assert event.event_type == "RunAlreadyCompleted"
  end

  test "mark_recovered/1 dispatches run.recover through CommandRouter" do
    run_id = "recover-#{unique_id()}"

    {:ok, _} =
      EventStore.append(%{
        stream_id: "run:#{run_id}",
        event_type: "RunStarted",
        payload: %{run_id: run_id, task_id: "task-1", project_id: "proj-1"},
        metadata: %{}
      })

    assert {:ok, %{event: event}} = Manual.mark_recovered(run_id)
    assert event.event_type == "RunRecoveryEvent"
    assert event.payload.run_id == run_id
    assert event.payload.outcome == "recovered"
  end

  test "mark_recovered/1 requires run_id to exist" do
    result = Manual.mark_recovered("does-not-exist")
    assert {:error, _} = result
  end

  test "force_complete/1 requires run_id to exist" do
    result = Manual.force_complete("does-not-exist")
    assert {:error, _} = result
  end

  # --- Helpers ---

  defp unique_id, do: System.unique_integer([:positive]) |> Integer.to_string()
end
