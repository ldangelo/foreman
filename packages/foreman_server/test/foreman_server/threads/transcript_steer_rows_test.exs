defmodule ForemanServer.Threads.TranscriptSteerRowsTest do
  @moduledoc """
  What the operator reads in `GET /api/threads/:id/transcript` about a steering message after
  `RunSteerQueued`: `RunSteerDelivered` (written into the live agent session),
  `RunSteerConsumed` (taken by the agent, live or in a rebuilt prompt) and
  `RunSteerUndelivered` (the run ended without taking it, visibly distinct as
  `Steer NOT delivered`).

  The events are produced by the real gateway and aggregate. The run is paused first (operator
  pause), so the `Dispatcher` has no running agent to steer and adds nothing of its own; the
  delivery commands are the ones `Workflow.LiveSteer` sends, and the undelivered one is recorded
  by the `Dispatcher` when the run is cancelled.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.{CommandGateway, CommandRouter, ProjectionStore}

  @endpoint ForemanServerWeb.Endpoint
  @token "transcript-steer-rows-test-token"

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    :ok = ProjectionStore.subscribe(replay_existing: false)
    {:ok, run_id: start_paused_run!()}
  end

  test "a steer written into the live session reads: queued, delivered, taken, in that order", %{
    run_id: run_id
  } do
    steer!(run_id, "m1", "use tabs")

    system!("run.steer.deliver", run_id, "deliver", %{message_id: "m1", mode: "live"})
    system!("run.steer.consume", run_id, "consume", %{message_ids: ["m1"], delivery: "live"})

    assert steering_rows(run_id) == [
             %{
               "role" => "operator",
               "kind" => "steer",
               "source" => "steer",
               "text" => "use tabs"
             },
             %{
               "role" => "system",
               "kind" => "status",
               "source" => "run_event",
               "text" => "Steer delivered to the running agent: live"
             },
             %{
               "role" => "system",
               "kind" => "status",
               "source" => "run_event",
               "text" => "Steer taken by the agent: live"
             }
           ]
  end

  test "a steer taken into a rebuilt prompt says so", %{run_id: run_id} do
    steer!(run_id, "m1", "use spaces")
    system!("run.steer.consume", run_id, "consume", %{message_ids: ["m1"]})

    assert [%{"kind" => "steer", "text" => "use spaces"}, taken] = steering_rows(run_id)
    assert taken["text"] == "Steer taken by the agent: prompt"
  end

  test "a steer the run ended without taking is a distinct NOT delivered row with the reason", %{
    run_id: run_id
  } do
    steer!(run_id, "m1", "never read")

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "run.cancel",
        command_id: "cancel:" <> run_id,
        aggregate_id: "run:" <> run_id,
        payload: %{run_id: run_id}
      })

    await("RunSteerUndelivered", run_id)

    assert steering_rows(run_id) == [
             %{
               "role" => "operator",
               "kind" => "steer",
               "source" => "steer",
               "text" => "never read"
             },
             %{
               "role" => "system",
               "kind" => "status",
               "source" => "run_event",
               "text" => "Steer NOT delivered: run_cancelled"
             }
           ]
  end

  # -- helpers ---------------------------------------------------------------

  defp start_paused_run! do
    n = System.unique_integer([:positive])
    project_id = "p-tr-#{n}"
    run_id = "run-tr-#{n}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        aggregate_id: "project:#{project_id}",
        command_id: "register:#{project_id}",
        type: "project.register",
        payload: %{project_id: project_id, name: project_id, path: System.tmp_dir!()}
      })

    {:ok, _} =
      CommandRouter.dispatch_run_start(project_id, %{
        run_id: run_id,
        task_id: "task-#{run_id}",
        workflow_snapshot: %{phases: [%{id: "phase-1", kind: "command"}]},
        phase_specs: [%{phase_id: "phase-1", kind: "command"}],
        approval_id: "approval-#{run_id}"
      })

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "run.pause",
        command_id: "pause:" <> run_id,
        aggregate_id: "run:" <> run_id,
        payload: %{run_id: run_id, reason: "operator"}
      })

    await("RunPaused", run_id)
    run_id
  end

  defp steer!(run_id, message_id, text) do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "run.steer",
        command_id: "steer:#{run_id}:#{message_id}",
        aggregate_id: "run:" <> run_id,
        payload: %{run_id: run_id, message_id: message_id, text: text}
      })
  end

  defp system!(type, run_id, label, payload) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: type,
        command_id: "#{label}:#{run_id}",
        aggregate_id: "run:" <> run_id,
        payload: Map.put(payload, :run_id, run_id)
      })
  end

  # The steering rows of the transcript, as the HTTP endpoint serves them (the pause row is the
  # test's own set-up).
  defp steering_rows(run_id) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/threads/run:#{run_id}/transcript")

    for turn <- json_response(conn, 200)["turns"],
        turn["kind"] == "steer" or String.starts_with?(turn["text"], "Steer"),
        do: Map.take(turn, ~w(role kind source text))
  end

  defp await(type, run_id) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        data = if is_struct(data), do: Map.from_struct(data), else: data
        if Map.get(data, :run_id) == run_id, do: data, else: await(type, run_id)

      {:projection_event, _other} ->
        await(type, run_id)
    after
      15_000 -> flunk("timed out waiting for #{type} on #{run_id}")
    end
  end
end
