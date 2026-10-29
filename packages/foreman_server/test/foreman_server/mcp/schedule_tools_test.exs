defmodule ForemanServer.MCP.ScheduleToolsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{EventStore, ProjectionStore, ProjectStore}
  alias ForemanServer.MCP.{Policy, ToolError, Tools}
  alias ForemanServer.MCP.Tools.{ScheduleCommandResult, ScheduleListResult}
  alias ForemanServer.Schedule.DTO
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

  @write_tools ~w(foreman_schedule_create foreman_schedule_update foreman_schedule_pause foreman_schedule_resume foreman_schedule_delete)

  test "list is a read tool and returns the HTTP DTOs in a ScheduleListResult", %{id: id} do
    writes(true)

    {:ok, %ScheduleCommandResult{schedule_id: sid}} =
      Tools.call_tool("foreman_schedule_create", args(id))

    writes(false)

    assert {:ok,
            %ScheduleListResult{project_id: ^id, ticker: "disabled", schedules: [%DTO{} = dto]}} =
             Tools.call_tool("foreman_schedule_list", %{project_id: id})

    assert dto.schedule_id == sid

    assert %DTO{name: "daily", status: "active", spec: %{"every" => "1h"}} = dto
    assert is_binary(dto.next_fire_at)

    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_schedule_list", %{project_id: "nope"})
  end

  test "write tools return exactly project_id, schedule_id and status, never the event or prompt",
       %{
         id: id
       } do
    writes(true)
    secret = "PROMPT-BODY-#{System.unique_integer([:positive])}"

    assert {:ok,
            %ScheduleCommandResult{project_id: ^id, schedule_id: sid, status: "created"} = created} =
             Tools.call_tool("foreman_schedule_create", args(id, %{prompt: secret}))

    ids = %{project_id: id, schedule_id: sid}

    assert {:ok, %ScheduleCommandResult{status: "paused"}} =
             Tools.call_tool("foreman_schedule_pause", ids)

    assert {:ok, %ScheduleCommandResult{status: "resumed"}} =
             Tools.call_tool("foreman_schedule_resume", ids)

    assert {:ok, %ScheduleCommandResult{project_id: ^id, schedule_id: ^sid, status: "deleted"}} =
             Tools.call_tool("foreman_schedule_delete", ids)

    # the wire shape: exactly these three snake_case keys, and no prompt payload
    assert created |> Jason.encode!() |> Jason.decode!() ==
             %{"project_id" => id, "schedule_id" => sid, "status" => "created"}

    refute Jason.encode!(created) =~ secret
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

    assert {:ok, %ScheduleCommandResult{schedule_id: sid}} =
             Tools.call_tool("foreman_schedule_create", call)

    assert {:ok, %ScheduleCommandResult{schedule_id: ^sid}} =
             Tools.call_tool("foreman_schedule_create", call)

    assert [_one] = created_events(id, sid)
    assert [%{schedule_id: ^sid}] = ProjectionStore.schedules(id)

    assert {:ok, %ScheduleCommandResult{schedule_id: other}} =
             Tools.call_tool("foreman_schedule_create", args(id, %{request_id: "req-2"}))

    assert other != sid
    assert length(ProjectionStore.schedules(id)) == 2
  end

  test "without a request_id every call creates a new schedule", %{id: id} do
    writes(true)

    assert {:ok, %ScheduleCommandResult{schedule_id: a}} =
             Tools.call_tool("foreman_schedule_create", args(id))

    assert {:ok, %ScheduleCommandResult{schedule_id: b}} =
             Tools.call_tool("foreman_schedule_create", args(id))

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

    {:ok, %ScheduleCommandResult{schedule_id: sid}} =
      Tools.call_tool("foreman_schedule_create", args(id))

    ids = %{project_id: id, schedule_id: sid}

    status = fn ->
      {:ok, %ScheduleListResult{schedules: schedules}} =
        Tools.call_tool("foreman_schedule_list", %{project_id: id})

      Enum.map(schedules, &{&1.schedule_id, &1.status})
    end

    assert [{^sid, "active"}] = status.()

    assert {:ok, %ScheduleCommandResult{status: "paused"}} =
             Tools.call_tool("foreman_schedule_pause", ids)

    assert [{^sid, "paused"}] = status.()

    assert {:error, %ToolError{code: "schedule_already_paused"}} =
             Tools.call_tool("foreman_schedule_pause", ids)

    assert {:ok, %ScheduleCommandResult{status: "resumed"}} =
             Tools.call_tool("foreman_schedule_resume", ids)

    assert [{^sid, "active"}] = status.()

    assert {:ok, %ScheduleCommandResult{status: "deleted"}} =
             Tools.call_tool("foreman_schedule_delete", ids)

    assert [] = status.()

    assert {:error, %ToolError{code: "schedule_deleted"}} =
             Tools.call_tool("foreman_schedule_resume", ids)
  end

  defp event_count(project_id, schedule_id, event_type) do
    case EventStore.read_stream_forward("schedule:#{project_id}:#{schedule_id}", 0, 1_000) do
      {:ok, events} -> Enum.count(events, &(&1.event_type == event_type))
      {:error, :stream_not_found} -> 0
    end
  end

  defp list_schedules(project_id) do
    {:ok, %ScheduleListResult{schedules: schedules}} =
      Tools.call_tool("foreman_schedule_list", %{project_id: project_id})

    schedules
  end

  defp create_schedule(project_id, extra \\ %{}) do
    writes(true)

    {:ok, %ScheduleCommandResult{schedule_id: sid}} =
      Tools.call_tool("foreman_schedule_create", args(project_id, extra))

    sid
  end

  test "update changes only the named fields and returns the three-key result", %{id: id} do
    secret = "UPDATE-PROMPT-#{System.unique_integer([:positive])}"
    sid = create_schedule(id, %{prompt: secret})
    [before] = list_schedules(id)

    assert {:ok,
            %ScheduleCommandResult{project_id: ^id, schedule_id: ^sid, status: "updated"} =
              result} =
             Tools.call_tool("foreman_schedule_update", %{
               project_id: id,
               schedule_id: sid,
               name: "renamed",
               overlap: "allow",
               auto_approve: false
             })

    assert [%DTO{} = after_update] = list_schedules(id)
    assert %DTO{name: "renamed", overlap: "allow", auto_approve: false} = after_update
    assert after_update.spec == before.spec
    assert after_update.workflow == before.workflow
    assert after_update.prompt == secret
    assert after_update.misfire_grace_seconds == before.misfire_grace_seconds
    assert event_count(id, sid, "ScheduleUpdated") == 1

    assert result |> Jason.encode!() |> Jason.decode!() ==
             %{"project_id" => id, "schedule_id" => sid, "status" => "updated"}

    refute Jason.encode!(result) =~ secret
  end

  test "update changes prompt, workflow and misfire grace", %{id: id} do
    sid = create_schedule(id)

    assert {:ok, %ScheduleCommandResult{status: "updated"}} =
             Tools.call_tool("foreman_schedule_update", %{
               project_id: id,
               schedule_id: sid,
               prompt: "new prompt",
               misfire_grace_seconds: 30
             })

    assert [%DTO{prompt: "new prompt", misfire_grace_seconds: 30, name: "daily"}] =
             list_schedules(id)
  end

  test "every and cron replace the whole spec; a no-spec update leaves it identical", %{id: id} do
    sid = create_schedule(id)
    [%DTO{spec: interval_spec}] = list_schedules(id)
    assert %{"every" => "1h"} = interval_spec

    assert {:ok, %ScheduleCommandResult{status: "updated"}} =
             Tools.call_tool("foreman_schedule_update", %{
               project_id: id,
               schedule_id: sid,
               cron: "0 9 * * 1-5"
             })

    assert [%DTO{spec: cron_spec}] = list_schedules(id)
    assert %{"cron" => "0 9 * * 1-5"} = cron_spec
    refute Map.has_key?(cron_spec, "every")
    refute Map.has_key?(cron_spec, "anchor")

    assert {:ok, %ScheduleCommandResult{status: "updated"}} =
             Tools.call_tool("foreman_schedule_update", %{
               project_id: id,
               schedule_id: sid,
               name: "still cron"
             })

    assert [%DTO{spec: ^cron_spec, name: "still cron"}] = list_schedules(id)

    assert {:ok, %ScheduleCommandResult{status: "updated"}} =
             Tools.call_tool("foreman_schedule_update", %{
               project_id: id,
               schedule_id: sid,
               every: "2h",
               timezone: "UTC"
             })

    assert [%DTO{spec: every_spec}] = list_schedules(id)
    assert %{"every" => "2h"} = every_spec
    refute Map.has_key?(every_spec, "cron")
  end

  test "update refusals carry the aggregate's typed code and change nothing", %{id: id} do
    sid = create_schedule(id)
    before = list_schedules(id)
    ids = %{project_id: id, schedule_id: sid}

    refusals = [
      {%{}, "missing_or_invalid", nil},
      {%{every: "1m"}, "invalid_schedule_spec",
       "{:invalid_schedule_spec, :every, :below_minimum}"},
      {%{every: "1h", cron: "0 * * * *"}, "invalid_schedule_spec", nil},
      {%{timezone: "UTC"}, "invalid_schedule_spec", nil},
      {%{every: "1h", timezone: "Europe/Paris"}, "invalid_schedule_spec", nil},
      {%{workflow: "does-not-exist"}, "unknown_workflow", nil},
      {%{overlap: "queue"}, "invalid_overlap", nil},
      {%{auto_approve: "yes"}, "missing_or_invalid", nil}
    ]

    for {change, code, message} <- refusals do
      assert {:error, %ToolError{code: ^code, message: got}} =
               Tools.call_tool("foreman_schedule_update", Map.merge(ids, change)),
             "update #{inspect(change)} should be refused with #{code}"

      if message, do: assert(got == message)
      assert event_count(id, sid, "ScheduleUpdated") == 0
      assert list_schedules(id) == before
    end
  end

  test "updating an unknown, foreign or deleted schedule is refused without an event", %{id: id} do
    sid = create_schedule(id)
    other = "mcp-sched-other-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ProjectStore.save(%{project_id: other, path: "/tmp/#{other}"})
    other_sid = create_schedule(other)

    assert {:error, %ToolError{code: "schedule_not_found"}} =
             Tools.call_tool("foreman_schedule_update", %{
               project_id: id,
               schedule_id: "sch-nope",
               name: "x"
             })

    # a schedule id that exists, but in another project
    assert {:error, %ToolError{code: "schedule_not_found"}} =
             Tools.call_tool("foreman_schedule_update", %{
               project_id: id,
               schedule_id: other_sid,
               name: "x"
             })

    assert event_count(other, other_sid, "ScheduleUpdated") == 0
    assert event_count(id, other_sid, "ScheduleUpdated") == 0

    assert {:ok, %ScheduleCommandResult{status: "deleted"}} =
             Tools.call_tool("foreman_schedule_delete", %{project_id: id, schedule_id: sid})

    assert {:error, %ToolError{code: "schedule_deleted"}} =
             Tools.call_tool("foreman_schedule_update", %{
               project_id: id,
               schedule_id: sid,
               name: "x"
             })

    assert event_count(id, sid, "ScheduleUpdated") == 0
  end

  test "update argument errors are INVALID_PARAMS", %{id: id} do
    writes(true)

    assert {:error, %ToolError{code: "INVALID_PARAMS", message: missing}} =
             Tools.call_tool("foreman_schedule_update", %{project_id: id, name: "x"})

    assert missing =~ "schedule_id"

    assert {:error, %ToolError{code: "INVALID_PARAMS", message: "Unknown arguments: " <> unknown}} =
             Tools.call_tool("foreman_schedule_update", %{
               :project_id => id,
               :schedule_id => "sch-x",
               "status" => "paused"
             })

    assert unknown =~ "status"
  end
end
