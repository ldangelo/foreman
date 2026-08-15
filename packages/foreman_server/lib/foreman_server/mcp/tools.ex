defmodule ForemanServer.MCP.Tools do
  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Telemetry
  alias ForemanServer.Workflow.CatalogWriter
  alias ForemanServer.Workflow.PromptWriter
  alias ForemanServer.Workflow.Catalog
  alias ForemanServer.Workflow.Interpreter
  alias ForemanServer.MCP.Policy
  alias ForemanServer.Workflow.ManifestWriter

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

  @schema_foreman_workflow_put %{
    name: "foreman_workflow_put",
    description:
      "Write or update a workflow manifest in the catalog. Requires allow_workflow_writes to be enabled.",
    inputSchema: %{
      type: "object",
      properties: %{
        name: %{
          type: "string",
          description: "The workflow name (must match the manifest's name field)"
        },
        manifest: %{
          type: "object",
          description: "The workflow manifest object with at least 'name' and 'phases' fields"
        }
      },
      required: ["name", "manifest"]
    }
  }

  @schema_foreman_workflow_delete %{
    name: "foreman_workflow_delete",
    description:
      "Delete a workflow manifest from the catalog. Requires allow_workflow_writes to be enabled.",
    inputSchema: %{
      type: "object",
      properties: %{
        name: %{type: "string", description: "The workflow name"}
      },
      required: ["name"]
    }
  }
  @schema_foreman_workflow_validate %{
    name: "foreman_workflow_validate",
    description:
      "Validate a workflow manifest by running it through the Interpreter. Accepts a YAML string or manifest object. Returns valid: true if the manifest is parseable, or the verbatim Interpreter error message.",
    inputSchema: %{
      type: "object",
      properties: %{
        manifest: %{
          description:
            "The workflow manifest as a YAML string or a manifest object with at least 'name' and 'phases' fields"
        }
      },
      required: ["manifest"]
    }
  }
  @schema_foreman_prompt_put %{
    name: "foreman_prompt_put",
    description:
      "Write or update a prompt body in the catalog. Requires allow_workflow_writes to be enabled.",
    inputSchema: %{
      type: "object",
      properties: %{
        name: %{type: "string", description: "The prompt name (without .md extension)"},
        content: %{type: "string", description: "The prompt body content"}
      },
      required: ["name", "content"]
    }
  }
  @schema_foreman_prompt_get %{
    name: "foreman_prompt_get",
    description: "Get a prompt body by name",
    inputSchema: %{
      type: "object",
      properties: %{
        name: %{type: "string", description: "The prompt name (without .md extension)"}
      },
      required: ["name"]
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
    @schema_foreman_workflow_validate,
    @schema_foreman_work_submit,
    @schema_foreman_work_cancel,
    @schema_foreman_workflow_put,
    @schema_foreman_workflow_delete,
    @schema_foreman_prompt_put,
    @schema_foreman_prompt_get
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

  def call_tool("foreman_workflow_validate", params) do
    start_us = System.monotonic_time(:microsecond)

    manifest_body =
      case params do
        %{"manifest" => body} when is_binary(body) ->
          {:ok, body}

        %{"manifest" => body} when is_map(body) ->
          ManifestWriter.write(body)

        _ ->
          {:error, :invalid_params}
      end

    case manifest_body do
      {:ok, body} ->
        # Write to a temp file outside the catalog root
        tmp_path = Path.join(System.tmp_dir!(), "validate_#{:rand.uniform(999_999)}.yaml")

        parse_result =
          case File.write(tmp_path, body) do
            :ok ->
              result = Interpreter.load(tmp_path)
              File.rm(tmp_path)
              result

            {:error, reason} ->
              {:error, {:file_write_failed, reason}}
          end

        case parse_result do
          {:ok, _workflow} ->
            duration_us = System.monotonic_time(:microsecond) - start_us
            Telemetry.mcp_tool_call(duration_us, "foreman_workflow_validate", :ok)

            {:ok, %{valid: true}}

          {:error, {:manifest_load_failed, _path, message}} ->
            duration_us = System.monotonic_time(:microsecond) - start_us
            Telemetry.mcp_tool_call(duration_us, "foreman_workflow_validate", :error)

            {:error,
             %{
               code: "INVALID_MANIFEST",
               message: message
             }}

          {:error, {:unsupported_construct, _} = detail} ->
            duration_us = System.monotonic_time(:microsecond) - start_us
            Telemetry.mcp_tool_call(duration_us, "foreman_workflow_validate", :error)

            {:error,
             %{
               code: "INVALID_MANIFEST",
               message: "Manifest validation failed: #{inspect(detail)}"
             }}

          {:error, reason} ->
            duration_us = System.monotonic_time(:microsecond) - start_us
            Telemetry.mcp_tool_call(duration_us, "foreman_workflow_validate", :error)

            {:error,
             %{
               code: "INVALID_MANIFEST",
               message: inspect(reason)
             }}
        end

      {:error, :invalid_params} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_validate", :error)

        {:error,
         %{
           code: "INVALID_PARAMS",
           message: "Expected manifest as a YAML string or map"
         }}
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

  def call_tool("foreman_workflow_put", %{name: name, manifest: manifest}) do
    start_us = System.monotonic_time(:microsecond)

    if Policy.authorized?("foreman_workflow_put") do
      filename = name <> ".yaml"

      case CatalogWriter.write_manifest(filename, manifest) do
      {:ok, path} ->
        # Force a catalog reload so the in-memory state picks up the change
        Catalog.reload()

        # Check if the catalog now includes the workflow
        observed = match?({:ok, _}, Catalog.load(filename))

        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_put", :ok)

        {:ok,
         %{
           manifest_path: "workflows/#{name}.yaml",
           catalog_path: path,
           observed: observed
         }}

      {:error, :invalid_filename} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_put", :error)
        {:error, %{code: "INVALID_FILENAME", message: "Path separators and '..' are not allowed"}}

      {:error, :outside_catalog} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_put", :error)
        {:error, %{code: "OUTSIDE_CATALOG", message: "Path resolves outside catalog root"}}

      {:error, {:name_stem_mismatch, expected, actual}} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_put", :error)

        {:error,
         %{
           code: "NAME_STEM_MISMATCH",
           message: "Manifest name '#{actual}' does not match filename stem '#{expected}'"
         }}

      {:error, {:invalid_manifest, detail}} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_put", :error)

        {:error,
         %{
           code: "INVALID_MANIFEST",
           message: "Manifest validation failed: #{inspect(detail)}"
         }}

      {:error, {:unsupported_construct, _} = detail} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_put", :error)

        {:error,
         %{
           code: "INVALID_MANIFEST",
           message: "Manifest validation failed: #{inspect(detail)}"
         }}
      end
    else
      duration_us = System.monotonic_time(:microsecond) - start_us
      Telemetry.mcp_tool_call(duration_us, "foreman_workflow_put", :error)
      {:error, %{code: "POLICY_REFUSED", message: "Workflow writes are disabled"}}
    end
  end

  def call_tool("foreman_workflow_delete", %{name: name}) do
    start_us = System.monotonic_time(:microsecond)

    if Policy.authorized?("foreman_workflow_delete") do
      filename = name <> ".yaml"

      case CatalogWriter.delete_manifest(filename) do
      :ok ->
        # Force a catalog reload so the in-memory state drops the entry
        Catalog.reload()

        # Check if the catalog still includes the workflow (it should not)
        observed = match?({:error, _}, Catalog.load(filename))

        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_delete", :ok)

        {:ok,
         %{
           manifest_path: "workflows/#{name}.yaml",
           observed: observed
         }}

      {:error, :invalid_filename} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_delete", :error)
        {:error, %{code: "INVALID_FILENAME", message: "Path separators and '..' are not allowed"}}

      {:error, :outside_catalog} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_delete", :error)
        {:error, %{code: "OUTSIDE_CATALOG", message: "Path resolves outside catalog root"}}

      {:error, :not_found} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_delete", :not_found)
        {:error, %{code: "NOT_FOUND", message: "Workflow not found: #{name}"}}
      end
    else
      duration_us = System.monotonic_time(:microsecond) - start_us
      Telemetry.mcp_tool_call(duration_us, "foreman_workflow_delete", :error)
      {:error, %{code: "POLICY_REFUSED", message: "Workflow writes are disabled"}}
    end
  end

  def call_tool("foreman_prompt_get", %{"name" => name}) do
    start_us = System.monotonic_time(:microsecond)

    filename = name <> ".md"

    case validate_filename_or_error(filename) do
      :ok ->
        case Catalog.read_prompt(filename) do
          {:ok, content} ->
            duration_us = System.monotonic_time(:microsecond) - start_us
            Telemetry.mcp_tool_call(duration_us, "foreman_prompt_get", :ok)

            {:ok,
             %{
               name: name,
               content: content
             }}

          {:error, _} ->
            duration_us = System.monotonic_time(:microsecond) - start_us
            Telemetry.mcp_tool_call(duration_us, "foreman_prompt_get", :not_found)

            {:error, %{code: "NOT_FOUND", message: "Prompt not found: #{name}"}}
        end

      {:error, :invalid_filename} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_prompt_get", :error)

        {:error, %{code: "INVALID_FILENAME", message: "Path separators and '..' are not allowed"}}
    end
  end

  def call_tool("foreman_prompt_put", %{"name" => name, "content" => content}) do
    start_us = System.monotonic_time(:microsecond)

    if Policy.authorized?("foreman_prompt_put") do
      case PromptWriter.write_prompt(name, content) do
        {:ok, path} ->
          # Force a catalog reload so the in-memory state picks up the change
          Catalog.reload()

          # Check if the catalog now includes the prompt
          observed = match?({:ok, _}, Catalog.read_prompt(name <> ".md"))

          duration_us = System.monotonic_time(:microsecond) - start_us
          Telemetry.mcp_tool_call(duration_us, "foreman_prompt_put", :ok)

          {:ok,
           %{
             prompt_path: "prompts/#{name}.md",
             observed: observed
           }}

        {:error, :invalid_filename} ->
          duration_us = System.monotonic_time(:microsecond) - start_us
          Telemetry.mcp_tool_call(duration_us, "foreman_prompt_put", :error)

          {:error, %{code: "INVALID_FILENAME", message: "Path separators and '..' are not allowed"}}

        {:error, :outside_catalog} ->
          duration_us = System.monotonic_time(:microsecond) - start_us
          Telemetry.mcp_tool_call(duration_us, "foreman_prompt_put", :error)

          {:error, %{code: "OUTSIDE_CATALOG", message: "Path resolves outside catalog root"}}
      end
    else
      duration_us = System.monotonic_time(:microsecond) - start_us
      Telemetry.mcp_tool_call(duration_us, "foreman_prompt_put", :error)
      {:error, %{code: "POLICY_REFUSED", message: "Workflow writes are disabled"}}
    end
  end

  def call_tool(name, _) do
    start_us = System.monotonic_time(:microsecond)
    duration_us = System.monotonic_time(:microsecond) - start_us
    Telemetry.mcp_tool_call(duration_us, name, :not_found)
    {:error, %{code: "METHOD_NOT_FOUND", message: "Unknown tool: #{name}"}}
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp validate_filename_or_error(filename) do
    if String.contains?(filename, "/") or
         String.contains?(filename, "\\") or
         String.contains?(filename, "..") do
      {:error, :invalid_filename}
    else
      :ok
    end
  end
end
