defmodule ForemanServer.MCP.ScheduleToolsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{EventStore, ProjectionStore, ProjectStore}
  alias ForemanServer.MCP.{Policy, ToolError, Tools}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    previous = Application.get_env(:foreman_server, :mcp, [])

    on_exit(fn ->
      Application.put_env(:foreman_server, :mcp, previous)
      ProjectionStoreReset.reset!()
    end)

    id = "mcp-sched-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ProjectStore.save(%{project_id: id, path: "/tmp/#{id}"})
    {:ok, id: id}
  end

  defp writes(enabled?) do
    config = Application.get_env(:foreman_server, :mcp, [])

    Application.put_env(
      :foreman_server,
      :mcp,
      Keyword.put(config, :allow_workflow_writes, enabled?)
    )
  end

  defp created_events(project_id, schedule_id) do
    {:ok, events} =
      EventStore.read_stream_forward("schedule:#{project_id}:#{schedule_id}", 0, 1_000)

    Enum.filter(events, &(&1.event_type == "ScheduleCreated"))
  end

  defp args(id, extra \\ %{}),
    do:
      Map.merge(
        %{project_id: id, name: "daily", every: "1h", prompt: "go", workflow: "implement"},
        extra
      )

  @write_tools ~w(foreman_schedule_create foreman_schedule_pause foreman_schedule_resume foreman_schedule_delete)

  test "list is a read tool and equals the HTTP DTOs", %{id: id} do
    writes(true)
    {:ok, %{schedule_id: sid}} = Tools.call_tool("foreman_schedule_create", args(id))
    writes(false)

    assert {:ok, %{ticker: "disabled", schedules: [dto]}} =
             Tools.call_tool("foreman_schedule_list", %{project_id: id})

    assert dto.schedule_id == sid

    assert %{name: "daily", status: "active", spec: %{"every" => "1h"}} = dto
    assert is_binary(dto.next_fire_at)

    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_schedule_list", %{project_id: "nope"})
  end

  test "write tools are hidden and refused unless writes are allowed", %{id: id} do
    writes(false)
    names = Policy.list_tools(Tools.list_tools()) |> Enum.map(& &1.name)
    assert "foreman_schedule_list" in names
    for tool <- @write_tools, do: refute(tool in names)

    for tool <- @write_tools do
      refute Policy.authorized?(tool)

      assert {:error, %ToolError{code: "WRITE_NOT_ALLOWED"}} =
               Tools.call_tool(tool, args(id) |> Map.put(:schedule_id, "x"))
    end

    assert ProjectionStore.schedules(id) == []

    writes(true)
    names = Policy.list_tools(Tools.list_tools()) |> Enum.map(& &1.name)
    for tool <- @write_tools, do: assert(tool in names)
  end

  test "a repeated request_id returns the same schedule and appends one ScheduleCreated", %{
    id: id
  } do
    writes(true)
    call = args(id, %{request_id: "req-1"})

    assert {:ok, %{schedule_id: sid}} = Tools.call_tool("foreman_schedule_create", call)
    assert {:ok, %{schedule_id: ^sid}} = Tools.call_tool("foreman_schedule_create", call)
    assert [_one] = created_events(id, sid)
    assert [%{schedule_id: ^sid}] = ProjectionStore.schedules(id)

    assert {:ok, %{schedule_id: other}} =
             Tools.call_tool("foreman_schedule_create", args(id, %{request_id: "req-2"}))

    assert other != sid
    assert length(ProjectionStore.schedules(id)) == 2
  end

  test "without a request_id every call creates a new schedule", %{id: id} do
    writes(true)
    assert {:ok, %{schedule_id: a}} = Tools.call_tool("foreman_schedule_create", args(id))
    assert {:ok, %{schedule_id: b}} = Tools.call_tool("foreman_schedule_create", args(id))
    assert a != b
  end

  test "typed aggregate errors reach the tool error with their tag", %{id: id} do
    writes(true)

    assert {:error, %ToolError{code: "invalid_schedule_spec", message: message}} =
             Tools.call_tool("foreman_schedule_create", args(id, %{every: "1m"}))

    assert message == "{:invalid_schedule_spec, :every, :below_minimum}"

    assert {:error, %ToolError{code: "invalid_schedule_spec"}} =
             Tools.call_tool("foreman_schedule_create", args(id, %{cron: "0 * * * *"}))

    assert {:error, %ToolError{code: "unknown_workflow"}} =
             Tools.call_tool("foreman_schedule_create", args(id, %{workflow: "does-not-exist"}))

    assert ProjectionStore.schedules(id) == []
  end

  test "pause, resume and delete change the DTO status", %{id: id} do
    writes(true)
    {:ok, %{schedule_id: sid}} = Tools.call_tool("foreman_schedule_create", args(id))
    ids = %{project_id: id, schedule_id: sid}

    status = fn ->
      {:ok, %{schedules: schedules}} = Tools.call_tool("foreman_schedule_list", %{project_id: id})
      Enum.map(schedules, &{&1.schedule_id, &1.status})
    end

    assert [{^sid, "active"}] = status.()
    assert {:ok, _} = Tools.call_tool("foreman_schedule_pause", ids)
    assert [{^sid, "paused"}] = status.()

    assert {:error, %ToolError{code: "schedule_already_paused"}} =
             Tools.call_tool("foreman_schedule_pause", ids)

    assert {:ok, _} = Tools.call_tool("foreman_schedule_resume", ids)
    assert [{^sid, "active"}] = status.()
    assert {:ok, _} = Tools.call_tool("foreman_schedule_delete", ids)
    assert [] = status.()

    assert {:error, %ToolError{code: "schedule_deleted"}} =
             Tools.call_tool("foreman_schedule_resume", ids)
  end
end
