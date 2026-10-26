defmodule ForemanServer.MCP.OverviewToolTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.{Policy, ToolError, Tools}
  alias ForemanServer.{Overview, ProjectionStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    reg = fn id ->
      %{
        event_type: "ProjectRegistered",
        payload: %{project_id: id, path: "/tmp/" <> id, task_provider: %{type: "beads"}}
      }
    end

    :ok =
      ProjectionStore.apply_events([
        reg.("busy"),
        reg.("calm"),
        reg.("gone"),
        %{event_type: "ProjectArchived", payload: %{project_id: "gone"}},
        %{event_type: "RunStarted", payload: %{run_id: "r1", task_id: "t1", project_id: "busy"}},
        %{event_type: "RunFailed", payload: %{run_id: "r1", project_id: "busy", reason: "x"}},
        %{event_type: "RunStarted", payload: %{run_id: "r2", task_id: "t2", project_id: "calm"}},
        %{event_type: "RunStarted", payload: %{run_id: "r3", task_id: "t3", project_id: "gone"}},
        %{event_type: "RunFailed", payload: %{run_id: "r3", project_id: "gone", reason: "x"}}
      ])

    :ok
  end

  test "foreman_overview is a read tool visible under the read-only policy" do
    names = Tools.list_tools() |> Policy.list_tools() |> Enum.map(& &1.name)
    assert "foreman_overview" in names
    assert Policy.authorized?("foreman_overview")
  end

  test "with project_id it returns the same data as the HTTP read model" do
    assert {:ok, dto} = Tools.call_tool("foreman_overview", %{project_id: "busy"})
    {:ok, overview} = Overview.build("busy", now_fun: fn -> 0 end)

    assert dto["counts"] == Overview.to_dto(overview)["counts"]
    assert dto["counts"]["waiting_on_you"] == 1
    assert %{"needed" => true, "count" => 1} = dto["attention"]
    assert [%{"thread_id" => "run:r1"}] = dto["groups"]["waiting_on_you"]
    assert dto["groups"]["resolved"] == []
  end

  test "without project_id: one attention line per active project, archived excluded" do
    assert {:ok, %{"projects" => lines}} = Tools.call_tool("foreman_overview", %{})
    assert lines |> Enum.map(& &1["project_id"]) |> Enum.sort() == ["busy", "calm"]

    busy = Enum.find(lines, &(&1["project_id"] == "busy"))
    assert busy["attention"] == %{"needed" => true, "count" => 1, "reasons" => ["failed"]}
    assert busy["counts"]["waiting_on_you"] == 1
    assert busy["truncated"] == false

    calm = Enum.find(lines, &(&1["project_id"] == "calm"))
    assert calm["attention"]["needed"] == false
    assert calm["counts"]["working"] == 1
  end

  test "unknown project is NOT_FOUND; bad arguments are INVALID_PARAMS" do
    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_overview", %{project_id: "nope"})

    assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
             Tools.call_tool("foreman_overview", %{project_id: ""})

    assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
             Tools.call_tool("foreman_overview", %{project_id: "busy", include_resolved: "yes"})
  end

  test "project list and get carry attention and keep their existing keys" do
    {:ok, projects} = Tools.call_tool("foreman_project_list", %{})
    busy = Enum.find(projects, &(&1.project_id == "busy"))
    gone = Enum.find(projects, &(&1.project_id == "gone"))

    assert %{attention: %{"needed" => true, "count" => 1}, attention_count: 1, path: "/tmp/busy"} =
             busy

    assert %{attention: %{"needed" => false}, attention_count: 0} = gone

    {:ok, project} = Tools.call_tool("foreman_project_get", %{project_id: "busy"})
    assert project.attention_count == 1
    assert project.path == "/tmp/busy"
  end
end
