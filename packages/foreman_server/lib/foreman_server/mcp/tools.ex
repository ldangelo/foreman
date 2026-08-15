defmodule ForemanServer.MCP.Tools do
  alias ForemanServer.ProjectionStore

  @schema_foreman_work_get %{
    name: "foreman_work_get",
    description: "Get work details by work_id",
    inputSchema: %{
      type: "object",
      properties: %{
        work_id: %{type: "string", description: "The work ID"}
      },
      required: ["work_id"]
    }
  }

  @schema_foreman_run_get %{
    name: "foreman_run_get",
    description: "Get run details by run_id",
    inputSchema: %{
      type: "object",
      properties: %{
        run_id: %{type: "string", description: "The run ID"}
      },
      required: ["run_id"]
    }
  }

  @schema_foreman_queue_status %{
    name: "foreman_queue_status",
    description: "Get the current run slot queue status",
    inputSchema: %{
      type: "object",
      properties: %{}
    }
  }

  @schema_foreman_project_list %{
    name: "foreman_project_list",
    description: "List all projects",
    inputSchema: %{
      type: "object",
      properties: %{}
    }
  }

  @schema_foreman_project_get %{
    name: "foreman_project_get",
    description: "Get project details by project_id",
    inputSchema: %{
      type: "object",
      properties: %{
        project_id: %{type: "string", description: "The project ID"}
      },
      required: ["project_id"]
    }
  }

  @tools [@schema_foreman_work_get, @schema_foreman_run_get, @schema_foreman_queue_status, @schema_foreman_project_list, @schema_foreman_project_get]

  def list_tools, do: @tools

  def call_tool("foreman_work_get", %{work_id: work_id}) do
    case ProjectionStore.work_projection(work_id) do
      nil -> {:error, %{code: "NOT_FOUND", message: "Work not found"}}
      work -> {:ok, work}
    end
  end

  def call_tool("foreman_run_get", %{run_id: run_id}) do
    case ProjectionStore.run(run_id) do
      nil -> {:error, %{code: "NOT_FOUND", message: "Run not found"}}
      run -> {:ok, run}
    end
  end

  def call_tool("foreman_queue_status", %{}) do
    {:ok, ProjectionStore.queue_status()}
  end

  def call_tool("foreman_project_list", %{}) do
    {:ok, ProjectionStore.list_projects()}
  end

  def call_tool("foreman_project_get", %{project_id: project_id}) do
    case ProjectionStore.project_projection(project_id) do
      nil -> {:error, %{code: "NOT_FOUND", message: "Project not found"}}
      project -> {:ok, project}
    end
  end

  def call_tool(name, _) do
    {:error, %{code: "METHOD_NOT_FOUND", message: "Unknown tool: #{name}"}}
  end
end
