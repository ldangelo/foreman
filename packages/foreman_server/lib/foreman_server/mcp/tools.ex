defmodule ForemanServer.MCP.Tools do
  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Telemetry
  alias ForemanServer.Workflow.Catalog

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

  @schema_foreman_workflow_list %{
    name: "foreman_workflow_list",
    description: "List all available workflows",
    inputSchema: %{
      type: "object",
      properties: %{}
    }
  }

  @schema_foreman_workflow_get %{
    name: "foreman_workflow_get",
    description: "Get workflow details by name",
    inputSchema: %{
      type: "object",
      properties: %{
        name: %{type: "string", description: "The workflow name"}
      },
      required: ["name"]
    }
  }

  @schema_foreman_work_submit %{
    name: "foreman_work_submit",
    description: "Submit a new work request",
    inputSchema: %{
      type: "object",
      properties: %{
        work_id: %{type: "string", description: "The work ID"},
        project_id: %{type: "string", description: "The project ID"},
        workflow: %{type: "string", description: "The workflow name"},
        prompt: %{type: "string", description: "The input prompt"}
      },
      required: ["work_id", "project_id", "workflow", "prompt"]
    }
  }

  @schema_foreman_work_cancel %{
    name: "foreman_work_cancel",
    description: "Cancel a work request",
    inputSchema: %{
      type: "object",
      properties: %{
        work_id: %{type: "string", description: "The work ID"}
      },
      required: ["work_id"]
    }
  }

  @tools [
    @schema_foreman_work_get,
    @schema_foreman_run_get,
    @schema_foreman_queue_status,
    @schema_foreman_project_list,
    @schema_foreman_project_get,
    @schema_foreman_workflow_list,
    @schema_foreman_workflow_get,
    @schema_foreman_work_submit,
    @schema_foreman_work_cancel
  ]

  def list_tools, do: @tools

  def call_tool("foreman_work_get", %{work_id: work_id}) do
    start_us = System.monotonic_time(:microsecond)
    result = ProjectionStore.work_projection(work_id)
    duration_us = System.monotonic_time(:microsecond) - start_us
    outcome = if result, do: :ok, else: :not_found
    Telemetry.mcp_tool_call(duration_us, "foreman_work_get", outcome)
    if result, do: {:ok, result}, else: {:error, %{code: "NOT_FOUND", message: "Work not found"}}
  end

  def call_tool("foreman_run_get", %{run_id: run_id}) do
    start_us = System.monotonic_time(:microsecond)
    result = ProjectionStore.run(run_id)
    duration_us = System.monotonic_time(:microsecond) - start_us
    outcome = if result, do: :ok, else: :not_found
    Telemetry.mcp_tool_call(duration_us, "foreman_run_get", outcome)
    if result, do: {:ok, result}, else: {:error, %{code: "NOT_FOUND", message: "Run not found"}}
  end

  def call_tool("foreman_queue_status", %{}) do
    start_us = System.monotonic_time(:microsecond)
    result = ProjectionStore.queue_status()
    duration_us = System.monotonic_time(:microsecond) - start_us
    Telemetry.mcp_tool_call(duration_us, "foreman_queue_status", :ok)
    {:ok, result}
  end

  def call_tool("foreman_project_list", %{}) do
    start_us = System.monotonic_time(:microsecond)
    result = ProjectionStore.list_projects()
    duration_us = System.monotonic_time(:microsecond) - start_us
    Telemetry.mcp_tool_call(duration_us, "foreman_project_list", :ok)
    {:ok, result}
  end

  def call_tool("foreman_project_get", %{project_id: project_id}) do
    start_us = System.monotonic_time(:microsecond)
    result = ProjectionStore.project_projection(project_id)
    duration_us = System.monotonic_time(:microsecond) - start_us
    outcome = if result, do: :ok, else: :not_found
    Telemetry.mcp_tool_call(duration_us, "foreman_project_get", outcome)

    if result,
      do: {:ok, result},
      else: {:error, %{code: "NOT_FOUND", message: "Project not found"}}
  end

  def call_tool("foreman_workflow_list", %{}) do
    start_us = System.monotonic_time(:microsecond)
    result = Catalog.manifests()
    duration_us = System.monotonic_time(:microsecond) - start_us
    Telemetry.mcp_tool_call(duration_us, "foreman_workflow_list", :ok)
    {:ok, result}
  end

  def call_tool("foreman_workflow_get", %{name: name}) do
    start_us = System.monotonic_time(:microsecond)

    case Catalog.load(name <> ".yaml") do
      {:ok, manifest} ->
        result = %{
          name: name,
          description: Map.get(manifest, "description", ""),
          digest: Map.get(manifest, "digest", ""),
          phase_count: length(Map.get(manifest, "phases", [])),
          manifest_path: "workflows/#{name}.yaml",
          phases: Map.get(manifest, "phases", [])
        }

        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_get", :ok)
        {:ok, result}

      {:error, _reason} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_get", :not_found)
        {:error, %{code: "NOT_FOUND", message: "Workflow not found: #{name}"}}
    end
  end

  def call_tool("foreman_work_submit", %{
        work_id: work_id,
        project_id: project_id,
        workflow: workflow,
        prompt: prompt
      }) do
    start_us = System.monotonic_time(:microsecond)
    command_id = "mcp:#{work_id}:#{System.unique_integer([:positive])}"

    envelope = %{
      type: "work.submit",
      command_id: command_id,
      aggregate_id: "work:#{work_id}",
      payload: %{
        work_id: work_id,
        project_id: project_id,
        workflow: workflow,
        prompt: prompt
      }
    }

    case CommandGateway.dispatch_operator(envelope) do
      {:ok, result} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_work_submit", :ok)
        {:ok, result}

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_work_submit", :error)
        {:error, %{code: "DOMAIN_ERROR", message: inspect(reason)}}
    end
  end

  def call_tool("foreman_work_cancel", %{work_id: work_id}) do
    start_us = System.monotonic_time(:microsecond)
    command_id = "mcp:#{work_id}:#{System.unique_integer([:positive])}"

    envelope = %{
      type: "work.cancel",
      command_id: command_id,
      aggregate_id: "work:#{work_id}",
      payload: %{
        work_id: work_id
      }
    }

    case CommandGateway.dispatch_operator(envelope) do
      {:ok, result} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_work_cancel", :ok)
        {:ok, result}

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_work_cancel", :error)
        {:error, %{code: "DOMAIN_ERROR", message: inspect(reason)}}
    end
  end

  def call_tool(name, _) do
    start_us = System.monotonic_time(:microsecond)
    duration_us = System.monotonic_time(:microsecond) - start_us
    Telemetry.mcp_tool_call(duration_us, name, :not_found)
    {:error, %{code: "METHOD_NOT_FOUND", message: "Unknown tool: #{name}"}}
  end
end
