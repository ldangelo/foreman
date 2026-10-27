defmodule ForemanServerWeb.CommandControllerReplayTest do
  @moduledoc """
  `POST /api/commands` tells the caller when a command id was already recorded: the response
  carries `result.replayed` (`false` for a fresh command, `true` when the same command id is
  re-sent and the recorded effect is returned instead of being applied again). Without it an
  identical `A -> B -> A` update sequence (the CLI derives deterministic command ids) answered
  201 `{project_id}` both times and the operator could not tell the second `A` never applied.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.ProjectStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "command-replay-token"

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()

      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    id = "replay-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ProjectStore.save(%{project_id: id, path: "/tmp/#{id}", name: "Replay"})
    {:ok, id: id}
  end

  defp post_command(id, command_id, goal) do
    body = %{
      type: "project.update",
      command_id: command_id,
      payload: %{project_id: id, goal: goal}
    }

    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/commands", Jason.encode!(body))
    |> json_response(201)
  end

  defp goal(id) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get("/api/projects/#{id}/settings")
    |> json_response(200)
    |> get_in(["settings", "goal"])
  end

  test "a fresh command is replayed: false", %{id: id} do
    assert %{"status" => "accepted", "result" => %{"project_id" => ^id, "replayed" => false}} =
             post_command(id, "cmd-a", "A")

    assert goal(id) == "A"
  end

  test "re-sending a command id after the state changed is replayed: true and NOT re-applied",
       %{id: id} do
    assert %{"result" => %{"replayed" => false}} = post_command(id, "cmd-a", "A")
    assert %{"result" => %{"replayed" => false}} = post_command(id, "cmd-b", "B")
    assert goal(id) == "B"

    assert %{"status" => "accepted", "result" => %{"project_id" => ^id, "replayed" => true}} =
             post_command(id, "cmd-a", "A")

    assert goal(id) == "B"
  end
end
