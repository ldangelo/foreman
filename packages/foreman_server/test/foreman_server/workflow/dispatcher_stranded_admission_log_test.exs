defmodule ForemanServer.Workflow.DispatcherStrandedAdmissionLogTest do
  # TRD-018-TEST (AC-007-1): a task whose admission keeps failing is named by ONE
  # `error` line; the repeats on later ticks are `debug`, not a warning per tick.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.{CommandGateway, ProjectionStore}
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H

  setup do
    ForemanServer.TestSupport.DispatcherRestart.restart!()
    ForemanServer.TestSupport.RunSlotsReset.reset!()

    :meck.new(ForemanServer.RunAdmission, [:passthrough, :no_link])

    :meck.expect(ForemanServer.RunAdmission, :start, fn _project, _payload, _timeout ->
      {:error, :stranded_for_test}
    end)

    :meck.expect(ForemanServer.RunAdmission, :start, fn _project, _payload ->
      {:error, :stranded_for_test}
    end)

    on_exit(fn ->
      if :meck.validate(ForemanServer.RunAdmission), do: :meck.unload(ForemanServer.RunAdmission)
    end)

    H.subscribe!()
    {:ok, project: H.register_project(System.tmp_dir!(), config: %{})}
  end

  test "ten failing ticks log one error naming the task", %{project: project} do
    task_id = "task-#{System.unique_integer([:positive])}"
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, _} =
                 CommandGateway.dispatch_operator(%{
                   command_id: "c-#{System.unique_integer([:positive])}",
                   aggregate_id: "task:#{task_id}",
                   type: "task.create",
                   payload: %{
                     task_id: task_id,
                     project_id: project,
                     task_type: "implement",
                     title: "t",
                     prompt: "p",
                     provider_tracked: false,
                     auto_approve: true
                   }
                 })

        wait_in_progress(task_id)

        for _ <- 1..9 do
          send(
            ForemanServer.Workflow.Dispatcher,
            {:projection_event, %{event_type: "TaskDispatched", data: %{task_id: task_id}}}
          )
        end

        # Barrier: the Dispatcher handled everything queued before this call.
        _ = :sys.get_state(ForemanServer.Workflow.Dispatcher)
      end)

    lines = log |> String.split("\n") |> Enum.filter(&String.contains?(&1, task_id))
    errors = Enum.filter(lines, &(&1 =~ "[error]"))
    warnings = Enum.filter(lines, &(&1 =~ "[warning]"))

    assert length(errors) == 1, "expected one error line, got: #{inspect(lines)}"
    assert warnings == []
    assert Enum.count(lines, &(&1 =~ "[debug]")) >= 1
  end

  defp wait_in_progress(task_id, tries \\ 100) do
    case ProjectionStore.task_projection(task_id) do
      %{status: "in_progress"} -> :ok
      _ when tries > 0 -> Process.sleep(50) && wait_in_progress(task_id, tries - 1)
      other -> flunk("task never in progress: #{inspect(other)}")
    end
  end
end
