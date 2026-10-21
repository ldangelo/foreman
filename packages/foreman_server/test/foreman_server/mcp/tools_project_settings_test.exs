defmodule ForemanServer.MCP.ToolsProjectSettingsTest do
  # Project settings over MCP: a read tool that is always available, and gated
  # write tools (settings_update, pause, resume) that dispatch the SAME operator
  # commands as the CLI/HTTP surface. No merge/approve tool exists here.
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

    id = "mcp-settings-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             ProjectStore.save(%{
               project_id: id,
               path: "/tmp/#{id}",
               config: %{env: %{"API_TOKEN" => "s3cr3t"}}
             })

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

  defp events(id, type) do
    {:ok, events} = EventStore.read_stream_forward("project:#{id}", 0, 1_000)
    Enum.filter(events, &(&1.event_type == type))
  end

  test "the read tool works with writes disabled, returns the typed payload and no env", %{id: id} do
    writes(false)
    assert {:ok, dto} = Tools.call_tool("foreman_project_settings_get", %{project_id: id})

    assert %{
             "project_id" => ^id,
             "status" => "active",
             "settings" => settings,
             "limits" => limits
           } = dto

    assert settings["goal"] == nil and settings["max_concurrent_runs"] == nil
    assert Map.has_key?(limits, "deferred_tasks")
    refute inspect(dto) =~ "s3cr3t"
  end

  test "project reads redact env values over MCP", %{id: id} do
    assert {:ok, project} = Tools.call_tool("foreman_project_get", %{project_id: id})
    assert project.config.env == %{"API_TOKEN" => "[redacted]"}
    refute inspect(Tools.call_tool("foreman_project_list", %{})) =~ "s3cr3t"
  end

  test "an unknown project is NOT_FOUND" do
    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_project_settings_get", %{project_id: "nope"})
  end

  test "write tools are hidden and refused unless writes are allowed", %{id: id} do
    writes(false)
    names = Policy.list_tools(Tools.list_tools()) |> Enum.map(& &1.name)
    assert "foreman_project_settings_get" in names
    refute "foreman_project_settings_update" in names
    refute "foreman_project_pause" in names

    assert {:error, %ToolError{code: "WRITE_NOT_ALLOWED"}} =
             Tools.call_tool("foreman_project_settings_update", %{project_id: id, goal: "x"})

    assert {:error, %ToolError{code: "WRITE_NOT_ALLOWED"}} =
             Tools.call_tool("foreman_project_pause", %{project_id: id})

    assert events(id, "ProjectUpdated") == []
  end

  test "settings_update applies, is idempotent for identical args and distinct for different ones",
       %{id: id} do
    writes(true)
    args = %{project_id: id, goal: "ship it", max_concurrent_runs: 2, idempotency_key: "k1"}

    assert {:ok, _} = Tools.call_tool("foreman_project_settings_update", args)
    assert {:ok, _} = Tools.call_tool("foreman_project_settings_update", args)
    assert length(events(id, "ProjectUpdated")) == 1

    assert %{goal: "ship it", max_concurrent_runs: 2} = ProjectionStore.project_settings(id)

    assert {:ok, _} =
             Tools.call_tool("foreman_project_settings_update", %{project_id: id, goal: "other"})

    assert length(events(id, "ProjectUpdated")) == 2
    assert %{goal: "other", max_concurrent_runs: 2} = ProjectionStore.project_settings(id)
  end

  test "clear removes only the named settings", %{id: id} do
    writes(true)

    {:ok, _} =
      Tools.call_tool("foreman_project_settings_update", %{
        project_id: id,
        goal: "g",
        thread_model: "m"
      })

    {:ok, _} =
      Tools.call_tool("foreman_project_settings_update", %{project_id: id, clear: ["goal"]})

    assert %{goal: nil, thread_model: "m"} = ProjectionStore.project_settings(id)
  end

  test "validation errors surface with a stable code and nothing is appended", %{id: id} do
    writes(true)

    assert {:error, %ToolError{code: "instructions_too_long", message: message}} =
             Tools.call_tool("foreman_project_settings_update", %{
               project_id: id,
               instructions: String.duplicate("x", 16_001)
             })

    assert message =~ "16001"
    assert events(id, "ProjectUpdated") == []
  end

  test "pr_auto_fix is advertised and reaches the project settings", %{id: id} do
    writes(true)
    assert "pr_auto_fix" in schema_properties("foreman_project_settings_update")

    assert {:ok, _} =
             Tools.call_tool("foreman_project_settings_update", %{
               project_id: id,
               pr_auto_fix: %{"kinds" => ["ci"], "max_attempts" => 3}
             })

    assert %{pr_auto_fix: %{"kinds" => ["ci"], "max_attempts" => 3, "cooldown_seconds" => 0}} =
             ProjectionStore.project_settings(id)
  end

  test "pause refuses new work and resume restores it; status is not an update argument", %{
    id: id
  } do
    writes(true)

    assert {:ok, _} =
             Tools.call_tool("foreman_project_pause", %{project_id: id, reason: "freeze"})

    assert %{status: "paused"} = ProjectionStore.project_projection(id)

    assert {:error, %ToolError{code: "already_paused"}} =
             Tools.call_tool("foreman_project_pause", %{project_id: id})

    assert {:ok, _} = Tools.call_tool("foreman_project_resume", %{project_id: id})
    assert %{status: "active"} = ProjectionStore.project_projection(id)

    refute "status" in schema_properties("foreman_project_settings_update")
    refute "task_provider" in schema_properties("foreman_project_settings_update")
    refute "env" in schema_properties("foreman_project_settings_update")
  end

  test "no merge or approve tool is exposed" do
    names = Enum.map(Tools.list_tools(), & &1.name)
    refute Enum.any?(names, &String.contains?(&1, "merge"))
    refute Enum.any?(names, &String.contains?(&1, "approve"))
  end

  defp schema_properties(tool) do
    Tools.list_tools()
    |> Enum.find(&(&1.name == tool))
    |> get_in([:inputSchema, :properties])
    |> Map.keys()
    |> Enum.map(&to_string/1)
  end
end
