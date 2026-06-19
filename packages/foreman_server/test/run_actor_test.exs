defmodule ForemanServer.RunActorTest do
  use ExUnit.Case

  alias ForemanServer.{EventStore, PhaseActor, ProjectionStore, RunActor}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-run-actor-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "starting a run records phase order and current phase" do
    assert {:ok, _pid} =
             ForemanServer.start_run(%{
               run_id: "run-order",
               task_id: "task-1",
               phases: ["developer", "qa", "reviewer"]
             })

    assert %{current_phase: "developer", phase_order: ["developer", "qa", "reviewer"]} =
             ForemanServer.run_state("run-order")

    run = ProjectionStore.snapshot().runs["run-order"]
    assert run.phase_order == ["developer", "qa", "reviewer"]
    assert run.current_phase == "developer"
    assert run.phase_status["developer"] == "in_progress"
  end

  test "passing phases advances deterministically and completes run" do
    assert {:ok, _pid} = RunActor.start_run(%{run_id: "run-pass", phases: ["dev", "qa"]})

    assert {:ok, %{current_phase: "qa"}} = RunActor.pass("run-pass", %{exit_code: 0})
    assert PhaseActor.status("run-pass", "dev").status == :completed
    assert ProjectionStore.snapshot().runs["run-pass"].current_phase == "qa"

    assert {:ok, %{status: :completed, current_phase: nil}} = RunActor.pass("run-pass")

    run = ProjectionStore.snapshot().runs["run-pass"]
    assert run.status == "completed"
    assert run.phase_status == %{"dev" => "completed", "qa" => "completed"}
  end

  test "failed phase retries until limit then records retry history on failure" do
    assert {:ok, _pid} =
             RunActor.start_run(%{run_id: "run-retry", phases: ["dev"], max_retries: 1})

    assert {:ok, %{status: :in_progress, retry_history: [_]}} =
             RunActor.fail("run-retry", %{reason: "qa-rejected"})

    assert ProjectionStore.snapshot().runs["run-retry"].phase_status["dev"] == "in_progress"

    assert {:ok, %{status: :failed, retry_history: history}} =
             RunActor.timeout("run-retry", %{reason: "deadline"})

    assert length(history) == 2
    run = ProjectionStore.snapshot().runs["run-retry"]
    assert run.status == "failed"
    assert run.retry_history == history
    assert [%{event_type: "RunStarted"} | _] = EventStore.stream("run:run-retry")
  end
end
