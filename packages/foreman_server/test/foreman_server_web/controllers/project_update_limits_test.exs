defmodule ForemanServerWeb.ProjectUpdateLimitsTest do
  @moduledoc """
  The settings limits at the HTTP door: `POST /api/commands` `project.update` refuses a goal over
  2 000 and instructions over 16 000 CHARACTERS (`String.length/1`) with a 422 that names the
  measured length, a refused update changes nothing, and an update the validator accepted reaches
  the agent whole through `GET /api/projects/:id/context`. The aggregate, MCP, LiveView and CLI
  tests cover the same limits behind their own doors; this is the one every other client uses.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.ProjectStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "project-update-limits-token"

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

    id = "limits-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             ProjectStore.save(%{project_id: id, path: "/tmp/#{id}", name: "Limits Demo"})

    update(id, %{goal: "Ship v2", instructions: "Be terse"}, 201)

    {:ok, id: id}
  end

  defp authed do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp update(id, settings, status) do
    body = %{type: "project.update", payload: Map.put(settings, :project_id, id)}

    authed()
    |> post("/api/commands", Jason.encode!(body))
    |> json_response(status)
  end

  defp settings(id) do
    authed()
    |> get("/api/projects/#{id}/settings")
    |> json_response(200)
    |> Map.fetch!("settings")
  end

  test "an over-limit goal is a 422 that names the measured length, and changes nothing", %{
    id: id
  } do
    assert %{"error" => "{:goal_too_long, 2001, 2000}"} =
             update(id, %{goal: String.duplicate("g", 2_001)}, 422)

    assert %{"goal" => "Ship v2", "instructions" => "Be terse"} = settings(id)
  end

  test "over-limit instructions are a 422 that names the measured length, and change nothing",
       %{id: id} do
    assert %{"error" => "{:instructions_too_long, 16001, 16000}"} =
             update(id, %{instructions: String.duplicate("i", 16_001)}, 422)

    assert %{"goal" => "Ship v2", "instructions" => "Be terse"} = settings(id)
  end

  test "the limits count characters, not bytes: the limit itself is accepted, one more is not",
       %{id: id} do
    goal = String.duplicate("日", 2_000)
    instructions = String.duplicate("日", 16_000)
    assert byte_size(goal) > 2_000 and byte_size(instructions) > 16_000

    update(id, %{goal: goal, instructions: instructions}, 201)
    assert %{"goal" => ^goal, "instructions" => ^instructions} = settings(id)

    assert %{"error" => "{:goal_too_long, 2001, 2000}"} =
             update(id, %{goal: goal <> "日"}, 422)

    assert %{"error" => "{:instructions_too_long, 16001, 16000}"} =
             update(id, %{instructions: instructions <> "日"}, 422)

    assert %{"goal" => ^goal, "instructions" => ^instructions} = settings(id)
  end

  test "instructions the validator accepted at the limit reach the agent's context whole",
       %{id: id} do
    instructions = String.duplicate("日", 16_000)
    update(id, %{instructions: instructions}, 201)

    context = authed() |> get("/api/projects/#{id}/context") |> json_response(200)

    assert context["truncated"] == []
    assert context["system_text"] =~ "## Project instructions\n" <> instructions
    refute context["system_text"] =~ "[truncated:"
  end
end
