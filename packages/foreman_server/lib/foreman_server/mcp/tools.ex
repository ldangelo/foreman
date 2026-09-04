defmodule ForemanServer.MCP.Tools do
  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Telemetry
  alias ForemanServer.Workflow.CatalogWriter
  alias ForemanServer.Workflow.PromptWriter
  alias ForemanServer.Workflow.Catalog
  alias ForemanServer.Workflow.Interpreter
  alias ForemanServer.Workflow.Validator
  alias ForemanServer.Workflow.ErrorReporter
  alias ForemanServer.AgentRuntime.Router
  alias ForemanServer.Workflow.ManifestWriter
  alias ForemanServer.MCP.Policy
  alias ForemanServer.MCP.ToolError
  alias ForemanServerWeb.MCP.Tools.Doctor, as: MCPDoctor

  # Typed DTOs — per AGENTS.md §5.1.
  defmodule RunStatus do
    @enforce_keys [:run_id, :status, :terminal]
    @type t :: %__MODULE__{
            run_id: String.t(),
            status: String.t(),
            terminal: boolean(),
            project_id: String.t() | nil,
            task_id: String.t() | nil,
            workflow_name: String.t() | nil,
            current_phase: ForemanServer.MCP.Tools.PhaseStatus.t() | nil,
            started_at_ms: integer() | nil,
            last_event_at_ms: integer() | nil,
            failure_reason: String.t() | nil,
            latest_stall: map() | nil
          }
    @derive Jason.Encoder
    defstruct [
      :run_id,
      :status,
      :terminal,
      :project_id,
      :task_id,
      :workflow_name,
      :current_phase,
      :started_at_ms,
      :last_event_at_ms,
      :failure_reason,
      :latest_stall
    ]
  end

  defmodule PhaseStatus do
    @enforce_keys [:phase_id, :status]
    @type t :: %__MODULE__{
            phase_id: String.t(),
            index: integer() | nil,
            name: String.t() | nil,
            status: String.t(),
            attempt: integer() | nil,
            started_at_ms: integer() | nil,
            last_event_at_ms: integer() | nil,
            failure_reason: String.t() | nil,
            latest_stall: map() | nil
          }
    @derive Jason.Encoder
    defstruct [
      :phase_id,
      :index,
      :name,
      :status,
      :attempt,
      :started_at_ms,
      :last_event_at_ms,
      :failure_reason,
      :latest_stall
    ]
  end

  # String → atom map for backend names accepted by Router.manual/1.
  # TRD-2026-4212be7e JHA-T002: the production default is
  # :jido_harness (the JidoHarnessAdapter routes through the vendored
  # Jido.Harness runtime, which in turn dispatches to the
  # :jido_harness, :providers list). The legacy :pi and :claude
  # atoms are also routed through the JidoHarnessAdapter as the
  # same upstream Jido.Harness provider names. Any other string
  # (including the historical :codex and :opencode names) is
  # rejected at the schema layer via the `enum` constraint and is
  # not accepted here.
  @backend_atoms %{
    "jido_harness" => :jido_harness,
    "pi" => :pi,
    "claude" => :claude
  }

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
  @schema_foreman_task_create %{
    name: "foreman_task_create",
    description:
      "Create a task and dispatch it in one call (defaults to untracked + auto-approving, matching the retired foreman_work_submit ergonomics)",
    inputSchema: %{
      type: "object",
      properties: %{
        project_id: %{type: "string", description: "The project ID"},
        prompt: %{type: "string", description: "The input prompt"},
        workflow: %{type: "string", description: "The workflow name"},
        task_type: %{
          type: "string",
          default: "task",
          description: "The task type/classification. Defaults to task."
        },
        task_id: %{type: "string", description: "The task ID. Minted automatically when omitted."},
        title: %{type: "string", description: "The task title. Defaults to the task ID."},
        backend: %{
          type: "string",
          enum: ["jido_harness", "pi", "claude"],
          default: "jido_harness",
          description:
            "Backend readiness check performed before dispatch. Defaults to jido_harness (the production default since TRD-2026-4212be7e JHA-T002). The :pi and :claude atoms are routed through the same JidoHarnessAdapter as their upstream Jido.Harness provider names."
        },
        provider_tracked: %{
          type: "boolean",
          default: false,
          description:
            "Whether this task should be claimed/completed/failed against the project's TaskProvider (e.g. a Beads issue). Defaults to false for ad-hoc dispatch."
        },
        auto_approve: %{
          type: "boolean",
          default: true,
          description:
            "Immediately approve and dispatch the task after creation. Defaults to true for one-call dispatch."
        },
        description: %{
          type: "string",
          description:
            "Task description, shown to command-phase agents as FOREMAN_TASK_DESCRIPTION"
        }
      },
      required: ["project_id", "description", "workflow"]
    }
  }
  @task_statuses ["open", "ready", "in_progress", "blocked", "closed", "failed"]

  @schema_foreman_task_list %{
    name: "foreman_task_list",
    description: "List tasks with optional project/status filters and offset pagination",
    inputSchema: %{
      type: "object",
      properties: %{
        project_id: %{type: "string", description: "Filter by project ID"},
        status: %{
          type: "string",
          enum: @task_statuses,
          description: "Filter by canonical task status"
        },
        limit: %{
          type: "integer",
          minimum: 1,
          maximum: 500,
          default: 100,
          description: "Maximum tasks to return (1-500; default 100)"
        },
        offset: %{
          type: "integer",
          minimum: 0,
          default: 0,
          description: "Zero-based task offset for pagination"
        }
      }
    }
  }

  @schema_foreman_task_get %{
    name: "foreman_task_get",
    description: "Get task details by task_id",
    inputSchema: %{
      type: "object",
      properties: %{
        task_id: %{type: "string", description: "The task ID"}
      },
      required: ["task_id"]
    }
  }

  @schema_foreman_task_update %{
    name: "foreman_task_update",
    description: "Update task fields (title, description, priority, status)",
    inputSchema: %{
      type: "object",
      properties: %{
        task_id: %{type: "string", description: "The task ID"},
        title: %{type: "string", description: "New task title"},
        description: %{type: "string", description: "New task description"},
        priority: %{type: "integer", description: "Priority 0-4 (0=critical, 4=backlog)"},
        status: %{
          type: "string",
          enum: @task_statuses,
          description: "New status (open, ready, in_progress, blocked, closed, failed)"
        }
      },
      required: ["task_id"]
    }
  }

  @schema_foreman_run_status %{
    name: "foreman_run_status",
    description: "Get a bounded run status DTO from run and phase projections",
    inputSchema: %{
      type: "object",
      properties: %{
        run_id: %{type: "string", description: "The run ID"}
      },
      required: ["run_id"]
    }
  }

  @schema_foreman_run_cancel %{
    name: "foreman_run_cancel",
    description: "Cancel a run",
    inputSchema: %{
      type: "object",
      properties: %{
        run_id: %{type: "string", description: "The run ID"},
        reason: %{type: "string", description: "The cancellation reason"}
      },
      required: ["run_id"]
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
  @schema_foreman_doctor %{
    name: "foreman_doctor",
    description: "Report jido_harness provider readiness for pi and claude",
    inputSchema: %{
      type: "object",
      properties: %{
        strict: %{
          type: "boolean",
          description: "Return provider_missing when any required provider is unavailable"
        }
      }
    }
  }

  @schema_foreman_run_get_logs %{
    name: "foreman_run_get_logs",
    description: "Return all logs for a run.",
    inputSchema: %{
      type: "object",
      required: ["run_id"],
      properties: %{
        "run_id" => %{type: "string", description: "The run_id."}
      }
    }
  }

  @schema_foreman_run_get_events %{
    name: "foreman_run_get_events",
    description: "Return all events for a run.",
    inputSchema: %{
      type: "object",
      required: ["run_id"],
      properties: %{
        "run_id" => %{type: "string", description: "The run_id."}
      }
    }
  }

  @schema_foreman_run_get_activity %{
    name: "foreman_run_get_activity",
    description: "Return activity (heartbeats) for a run.",
    inputSchema: %{
      type: "object",
      required: ["run_id"],
      properties: %{
        "run_id" => %{type: "string", description: "The run_id."}
      }
    }
  }

  @schema_foreman_inbox_get %{
    name: "foreman_inbox_get",
    description: "Get operator inbox messages for a run.",
    inputSchema: %{
      type: "object",
      required: ["run_id"],
      properties: %{
        "run_id" => %{type: "string", description: "The run_id."}
      }
    }
  }

  @tools [
    @schema_foreman_work_get,
    @schema_foreman_run_get,
    @schema_foreman_run_status,
    @schema_foreman_queue_status,
    @schema_foreman_project_list,
    @schema_foreman_project_get,
    @schema_foreman_workflow_list,
    @schema_foreman_workflow_get,
    @schema_foreman_workflow_validate,
    @schema_foreman_task_create,
    @schema_foreman_task_list,
    @schema_foreman_task_get,
    @schema_foreman_task_update,
    @schema_foreman_run_cancel,
    @schema_foreman_workflow_put,
    @schema_foreman_workflow_delete,
    @schema_foreman_prompt_put,
    @schema_foreman_prompt_get,
    @schema_foreman_doctor,
    @schema_foreman_run_get_logs,
    @schema_foreman_run_get_events,
    @schema_foreman_run_get_activity,
    @schema_foreman_inbox_get
  ]

  def list_tools, do: @tools

  # -------------------------------------------------------------------
  # Dispatch
  #
  # `call_tool/2` is GENERATED from `@tools`, so every advertised tool must
  # have a matching `tool_<name>/1` implementation or the module fails to
  # compile with an "undefined function" error. Previously the two were
  # unrelated: `foreman_queue_status` was advertised for its entire life with
  # no implementation, and each call fell through a catch-all that reported
  # `METHOD_NOT_FOUND — Unknown tool`.
  #
  # That catch-all also conflated two unrelated failures — "no such tool" and
  # "tool exists but the arguments did not match" — which is what made
  # argument-shape bugs so expensive to diagnose. They are now distinct:
  #
  #   * unknown name          -> METHOD_NOT_FOUND
  #   * missing required key   -> INVALID_PARAMS, naming the keys
  #   * string-keyed arguments -> raises ArgumentError (see check_args/3)
  # -------------------------------------------------------------------

  for schema <- @tools do
    tool_name = schema.name
    impl = :"tool_#{tool_name}"

    required =
      schema.inputSchema
      |> Map.get(:required, [])
      |> Enum.map(&String.to_atom/1)

    declared =
      schema.inputSchema
      |> Map.get(:properties, %{})
      |> Map.keys()
      |> Enum.map(&to_string/1)

    def call_tool(unquote(tool_name), args) when is_map(args) do
      case check_args(unquote(tool_name), args, unquote(required), unquote(declared)) do
        :ok -> unquote(impl)(args)
        {:error, %ToolError{}} = error -> error
      end
    end
  end

  def call_tool(name, _args) when is_binary(name) do
    Telemetry.mcp_tool_call(0, name, :not_found)
    {:error, %ToolError{code: "METHOD_NOT_FOUND", message: "Unknown tool: #{name}"}}
  end

  # String-keyed arguments never reach a tool through either MCP transport:
  # `ForemanServer.MCP.Dispatch` normalizes every schema-declared key to an
  # atom before dispatching. A string key here therefore means a caller
  # bypassed that boundary, which is a programming error and raises — rather
  # than silently matching no clause and being reported to the client as an
  # unknown tool.
  defp check_args(tool_name, args, required, declared) do
    string_keys = Enum.filter(Map.keys(args), &is_binary/1)
    declared_string_keys = Enum.filter(string_keys, &(&1 in declared))
    undeclared_string_keys = string_keys -- declared

    cond do
      declared_string_keys != [] ->
        raise ArgumentError,
              "#{tool_name} received string-keyed arguments " <>
                "#{inspect(declared_string_keys)}. Tool arguments use atom keys; " <>
                "call through ForemanServer.MCP.Dispatch, which normalizes " <>
                "schema-declared keys, or pass atoms directly."

      undeclared_string_keys != [] ->
        {:error,
         %ToolError{
           code: "INVALID_PARAMS",
           message: "Unknown arguments: #{Enum.join(undeclared_string_keys, ", ")}"
         }}

      true ->
        case Enum.reject(required, &Map.has_key?(args, &1)) do
          [] ->
            :ok

          missing ->
            {:error,
             %ToolError{
               code: "INVALID_PARAMS",
               message:
                 "Tool #{tool_name} is missing required arguments: " <>
                   Enum.map_join(missing, ", ", &inspect/1)
             }}
        end
    end
  end

  defp tool_foreman_work_get(%{work_id: work_id}) do
    start_us = System.monotonic_time(:microsecond)
    result = ProjectionStore.work_projection(work_id)
    duration_us = System.monotonic_time(:microsecond) - start_us
    outcome = if result, do: :ok, else: :not_found
    Telemetry.mcp_tool_call(duration_us, "foreman_work_get", outcome)

    if result,
      do: {:ok, result},
      else: {:error, %ToolError{code: "NOT_FOUND", message: "Work not found"}}
  end

  defp tool_foreman_run_get(%{run_id: run_id}) do
    start_us = System.monotonic_time(:microsecond)
    result = ProjectionStore.run(run_id)
    duration_us = System.monotonic_time(:microsecond) - start_us
    outcome = if result, do: :ok, else: :not_found
    Telemetry.mcp_tool_call(duration_us, "foreman_run_get", outcome)

    if result,
      do: {:ok, result},
      else: {:error, %ToolError{code: "NOT_FOUND", message: "Run not found"}}
  end

  defp tool_foreman_run_status(%{run_id: run_id}) do
    start_us = System.monotonic_time(:microsecond)

    result =
      case ProjectionStore.run(run_id) do
        nil -> nil
        run -> run_status_dto(run, ProjectionStore.phases_for_run(run_id))
      end

    duration_us = System.monotonic_time(:microsecond) - start_us
    outcome = if result, do: :ok, else: :not_found
    Telemetry.mcp_tool_call(duration_us, "foreman_run_status", outcome)

    if result,
      do: {:ok, result},
      else: {:error, %ToolError{code: "NOT_FOUND", message: "Run not found"}}
  end

  defp tool_foreman_run_get_logs(%{run_id: run_id}) do
    run_detail("foreman_run_get_logs", fn -> ProjectionStore.run_logs(run_id) end)
  end

  defp tool_foreman_run_get_events(%{run_id: run_id}) do
    run_detail("foreman_run_get_events", fn -> ProjectionStore.run_events(run_id) end)
  end

  defp tool_foreman_run_get_activity(%{run_id: run_id}) do
    run_detail("foreman_run_get_activity", fn -> ProjectionStore.run_activity(run_id) end)
  end

  defp tool_foreman_inbox_get(%{run_id: run_id}) do
    start_us = System.monotonic_time(:microsecond)
    result = ProjectionStore.inbox_thread(run_id)
    duration_us = System.monotonic_time(:microsecond) - start_us
    outcome = if result, do: :ok, else: :not_found
    Telemetry.mcp_tool_call(duration_us, "foreman_inbox_get", outcome)
    if result, do: {:ok, result}, else: {:ok, %{run_id: run_id, messages: []}}
  end

  # ProjectionStore run-detail reads return {:ok, data} | {:error, reason}.
  # Wrapping the raw return in {:ok, ...} would report `{:error, reason}` to the
  # client as a successful result — the same defect fixed one layer down. Each
  # documented reason gets its own code so "no such run" is never confused with
  # "this run has no data" (AGENTS.md §5.3).
  #
  # The trailing `{:error, reason}` clause is not a permissive fallback: it
  # yields an ERROR to the client, never a success, and `run_events/1` reads
  # the event store, whose reasons are genuinely open (`{:error, term()}`), so
  # a total match is not available here.
  #
  # There are deliberately no `:log_store_unavailable` / `:log_store_failed`
  # clauses. `ProjectionStore.run_logs/1` reads that GenServer's own state and
  # cannot report either, so those clauses were unreachable — handling for an
  # impossible scenario (AGENTS.md §2) that also advertised a store outage
  # this tool can never actually observe.
  defp run_detail(tool_name, fun) when is_binary(tool_name) and is_function(fun, 0) do
    start_us = System.monotonic_time(:microsecond)
    result = fun.()
    duration_us = System.monotonic_time(:microsecond) - start_us

    case result do
      {:ok, data} ->
        Telemetry.mcp_tool_call(duration_us, tool_name, :ok)
        {:ok, data}

      {:error, :run_not_found} ->
        Telemetry.mcp_tool_call(duration_us, tool_name, :not_found)
        {:error, %ToolError{code: "NOT_FOUND", message: "Run not found"}}

      {:error, reason} ->
        Telemetry.mcp_tool_call(duration_us, tool_name, :error)
        {:error, %ToolError{code: "RUN_DETAIL_FAILED", message: inspect(reason)}}
    end
  end

  defp tool_foreman_queue_status(%{}) do
    start_us = System.monotonic_time(:microsecond)
    result = ProjectionStore.queue_status()
    duration_us = System.monotonic_time(:microsecond) - start_us
    Telemetry.mcp_tool_call(duration_us, "foreman_queue_status", :ok)
    {:ok, result}
  end

  defp tool_foreman_project_list(%{}) do
    start_us = System.monotonic_time(:microsecond)
    result = ProjectionStore.list_projects()
    duration_us = System.monotonic_time(:microsecond) - start_us
    Telemetry.mcp_tool_call(duration_us, "foreman_project_list", :ok)
    {:ok, result}
  end

  defp tool_foreman_project_get(%{project_id: project_id}) do
    start_us = System.monotonic_time(:microsecond)
    result = ProjectionStore.project_projection(project_id)
    duration_us = System.monotonic_time(:microsecond) - start_us
    outcome = if result, do: :ok, else: :not_found
    Telemetry.mcp_tool_call(duration_us, "foreman_project_get", outcome)

    if result,
      do: {:ok, result},
      else: {:error, %ToolError{code: "NOT_FOUND", message: "Project not found"}}
  end

  defp tool_foreman_workflow_list(%{}) do
    start_us = System.monotonic_time(:microsecond)
    result = Catalog.manifests()
    duration_us = System.monotonic_time(:microsecond) - start_us
    Telemetry.mcp_tool_call(duration_us, "foreman_workflow_list", :ok)
    {:ok, result}
  end

  defp tool_foreman_workflow_get(%{name: name}) do
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
        {:error, %ToolError{code: "NOT_FOUND", message: "Workflow not found: #{name}"}}
    end
  end

  defp tool_foreman_workflow_validate(params) do
    start_us = System.monotonic_time(:microsecond)

    manifest_body =
      case params do
        %{manifest: body} when is_binary(body) ->
          {:ok, body}

        %{manifest: body} when is_map(body) ->
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
          {:ok, workflow} ->
            # HLW-T004 / TRD-094: check structural AND skill constraints
            case Validator.validate(workflow) do
              :ok ->
                duration_us = System.monotonic_time(:microsecond) - start_us
                Telemetry.mcp_tool_call(duration_us, "foreman_workflow_validate", :ok)
                {:ok, %{valid: true}}

              {:error, reason} ->
                duration_us = System.monotonic_time(:microsecond) - start_us
                Telemetry.mcp_tool_call(duration_us, "foreman_workflow_validate", :error)
                message = ErrorReporter.report(reason)
                {:error, %ToolError{code: "INVALID_WORKFLOW", message: message}}
            end

          {:error, {:manifest_load_failed, _path, message}} ->
            duration_us = System.monotonic_time(:microsecond) - start_us
            Telemetry.mcp_tool_call(duration_us, "foreman_workflow_validate", :error)

            {:error,
             %ToolError{
               code: "INVALID_MANIFEST",
               message: message
             }}

          {:error, reason} ->
            duration_us = System.monotonic_time(:microsecond) - start_us
            Telemetry.mcp_tool_call(duration_us, "foreman_workflow_validate", :error)

            {:error,
             %ToolError{
               code: "INVALID_MANIFEST",
               message: inspect(reason)
             }}
        end

      {:error, {:unsupported_construct, _} = detail} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_validate", :error)

        {:error,
         %ToolError{
           code: "INVALID_MANIFEST",
           message: "Manifest validation failed: #{inspect(detail)}"
         }}

      {:error, :invalid_params} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_workflow_validate", :error)

        {:error,
         %ToolError{
           code: "INVALID_PARAMS",
           message: "Expected manifest as a YAML string or map"
         }}
    end
  end

  defp tool_foreman_task_create(
         %{
           project_id: project_id,
           workflow: workflow,
           description: description
         } = args
       ) do
    backend = Map.get(args, :backend) || "jido_harness"

    with :ok <- check_backend(backend) do
      start_us = System.monotonic_time(:microsecond)

      task_id =
        case Map.get(args, :task_id) do
          id when is_binary(id) and id != "" -> id
          _ -> "adhoc-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
        end

      command_id = "mcp:#{task_id}:#{System.unique_integer([:positive])}"

      payload = %{
        task_id: task_id,
        project_id: project_id,
        task_type: Map.get(args, :task_type) || "task",
        workflow_type: workflow,
        prompt: Map.get(args, :prompt),
        description: description,
        title: Map.get(args, :title) || task_id,
        provider_tracked: Map.get(args, :provider_tracked, false),
        auto_approve: Map.get(args, :auto_approve, true)
      }

      envelope = %{
        type: "task.create",
        command_id: command_id,
        aggregate_id: "task:#{task_id}",
        payload: payload
      }

      case CommandGateway.dispatch_operator(envelope) do
        {:ok, result} ->
          duration_us = System.monotonic_time(:microsecond) - start_us
          Telemetry.mcp_tool_call(duration_us, "foreman_task_create", :ok)
          {:ok, result}

        {:error, reason} ->
          duration_us = System.monotonic_time(:microsecond) - start_us
          Telemetry.mcp_tool_call(duration_us, "foreman_task_create", :error)
          {:error, %ToolError{code: "DOMAIN_ERROR", message: inspect(reason)}}
      end
    else
      {:error, reason} ->
        {:error, %ToolError{code: "INVALID_BACKEND", message: reason}}
    end
  end

  defp tool_foreman_task_list(%{} = args) do
    start_us = System.monotonic_time(:microsecond)

    with {:ok, status} <- validate_task_status(Map.get(args, :status)),
         {:ok, limit} <- validate_limit(Map.get(args, :limit)),
         {:ok, offset} <- validate_offset(Map.get(args, :offset)) do
      filtered =
        ProjectionStore.list_tasks()
        |> Enum.filter(fn task ->
          project_match =
            Map.get(args, :project_id) == nil or
              Map.get(task, :project_id) == Map.get(args, :project_id)

          status_match = status == nil or Map.get(task, :status) == status

          project_match and status_match
        end)

      page = Enum.slice(filtered, offset, limit)
      next_offset = if offset + limit < length(filtered), do: offset + limit, else: nil
      duration_us = System.monotonic_time(:microsecond) - start_us
      Telemetry.mcp_tool_call(duration_us, "foreman_task_list", :ok)

      {:ok,
       %{
         tasks: page,
         total: length(filtered),
         limit: limit,
         offset: offset,
         next_offset: next_offset
       }}
    else
      {:error, %ToolError{}} = error ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_task_list", :error)
        error
    end
  end

  defp tool_foreman_task_get(%{task_id: task_id}) do
    start_us = System.monotonic_time(:microsecond)
    result = ProjectionStore.task_projection(task_id)
    duration_us = System.monotonic_time(:microsecond) - start_us
    outcome = if result, do: :ok, else: :not_found
    Telemetry.mcp_tool_call(duration_us, "foreman_task_get", outcome)

    if result,
      do: {:ok, result},
      else: {:error, %ToolError{code: "NOT_FOUND", message: "Task not found"}}
  end

  defp tool_foreman_task_update(%{task_id: task_id} = args) do
    start_us = System.monotonic_time(:microsecond)
    command_id = "mcp:#{task_id}:#{System.unique_integer([:positive])}"

    payload =
      args
      |> Map.take([:title, :description, :priority, :status])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    if map_size(payload) == 0 do
      duration_us = System.monotonic_time(:microsecond) - start_us
      Telemetry.mcp_tool_call(duration_us, "foreman_task_update", :error)
      {:error, %ToolError{code: "INVALID_PARAMS", message: "No update fields provided"}}
    else
      envelope = %{
        type: "task.update",
        command_id: command_id,
        aggregate_id: "task:#{task_id}",
        payload: Map.put(payload, :task_id, task_id)
      }

      case CommandGateway.dispatch_operator(envelope) do
        {:ok, result} ->
          duration_us = System.monotonic_time(:microsecond) - start_us
          Telemetry.mcp_tool_call(duration_us, "foreman_task_update", :ok)
          {:ok, result}

        {:error, reason} ->
          duration_us = System.monotonic_time(:microsecond) - start_us
          Telemetry.mcp_tool_call(duration_us, "foreman_task_update", :error)
          {:error, %ToolError{code: "DOMAIN_ERROR", message: inspect(reason)}}
      end
    end
  end

  defp validate_task_status(nil), do: {:ok, nil}
  defp validate_task_status(status) when status in @task_statuses, do: {:ok, status}

  defp validate_task_status(status) do
    {:error,
     %ToolError{
       code: "INVALID_PARAMS",
       message:
         "Invalid task status #{inspect(status)}; expected one of #{Enum.join(@task_statuses, ", ")}"
     }}
  end

  defp validate_limit(nil), do: {:ok, 100}

  defp validate_limit(limit) when is_integer(limit) and limit >= 1 and limit <= 500,
    do: {:ok, limit}

  defp validate_limit(limit) do
    {:error,
     %ToolError{
       code: "INVALID_PARAMS",
       message: "Invalid limit #{inspect(limit)}; expected integer 1..500"
     }}
  end

  defp validate_offset(nil), do: {:ok, 0}
  defp validate_offset(offset) when is_integer(offset) and offset >= 0, do: {:ok, offset}

  defp validate_offset(offset) do
    {:error,
     %ToolError{
       code: "INVALID_PARAMS",
       message: "Invalid offset #{inspect(offset)}; expected integer >= 0"
     }}
  end

  defp run_status_dto(run, phases) when is_map(run) and is_list(phases) do
    run_id = Map.get(run, :run_id)
    status = Map.get(run, :status)

    unless is_binary(run_id) and is_binary(status) do
      raise ArgumentError,
            "run_status_dto: run projection missing required identity fields " <>
              "(run_id: #{inspect(run_id)}, status: #{inspect(status)})"
    end

    %RunStatus{
      run_id: run_id,
      status: status,
      terminal: run_terminal?(run),
      project_id: Map.get(run, :project_id),
      task_id: Map.get(run, :task_id),
      workflow_name: Map.get(run, :workflow_name),
      current_phase: current_phase(phases),
      started_at_ms: Map.get(run, :started_at_ms),
      last_event_at_ms: Map.get(run, :last_event_at_ms),
      failure_reason: Map.get(run, :failure_reason),
      latest_stall: Map.get(run, :latest_stall)
    }
  end

  defp run_terminal?(run) do
    case Map.get(run, :terminal?) do
      b when is_boolean(b) -> b
      nil -> raise ArgumentError, "expected :terminal? boolean, got: nil"
      other -> raise ArgumentError, "expected :terminal? boolean, got: #{inspect(other)}"
    end
  end

  defp current_phase([]), do: nil

  defp current_phase(phases) do
    phases
    |> Enum.filter(&(Map.get(&1, :status) == "in_progress"))
    |> latest_phase()
    |> case do
      nil -> latest_phase(phases)
      phase -> phase
    end
    |> phase_status_dto()
  end

  defp latest_phase([]), do: nil

  defp latest_phase(phases) do
    Enum.max_by(phases, fn phase ->
      case Map.get(phase, :index) do
        index when is_integer(index) ->
          {index, Map.get(phase, :last_event_at_ms) || 0}

        other ->
          raise ArgumentError,
                "latest_phase: expected integer :index, got: #{inspect(other)}"
      end
    end)
  end

  defp phase_status_dto(phase) when is_map(phase) do
    phase_id = Map.get(phase, :phase_id)
    status = Map.get(phase, :status)

    unless is_binary(phase_id) and is_binary(status) do
      raise ArgumentError,
            "phase_status_dto: phase projection missing required identity fields " <>
              "(phase_id: #{inspect(phase_id)}, status: #{inspect(status)})"
    end

    %PhaseStatus{
      phase_id: phase_id,
      index: Map.get(phase, :index),
      name: Map.get(phase, :name),
      status: status,
      attempt: Map.get(phase, :attempt),
      started_at_ms: Map.get(phase, :started_at_ms),
      last_event_at_ms: Map.get(phase, :last_event_at_ms),
      failure_reason: Map.get(phase, :failure_reason),
      latest_stall: Map.get(phase, :latest_stall)
    }
  end

  # Returns :ok, or {:error, message_string} describing why the backend is rejected.
  defp check_backend(backend) when is_binary(backend) do
    case Map.fetch(@backend_atoms, backend) do
      {:ok, backend_atom} ->
        case Router.manual(backend_atom) do
          {:ok, _adapter} ->
            :ok

          {:error, :backend_not_found} ->
            {:error, "backend \"#{backend}\" is not registered."}

          {:error, :backend_unavailable} ->
            {:error, "backend \"#{backend}\" is registered but currently unavailable."}

          {:error, :no_available_backend} ->
            {:error, "no backends are currently available."}
        end

      :error ->
        hint =
          case backend do
            "claude" ->
              # Delegate to the runtime source of truth so MCP and
              # `foreman server doctor` can never disagree on the
              # install instruction.
              ForemanServer.AgentRuntime.JidoHarness.ReadinessCheck.install_hint(:claude)

            _ ->
              "Ensure the backend binary is on your PATH"
          end

        # The accepted backend set is `jido_harness`, `pi`, `claude`
        # (the production default + the two legacy atoms routed
        # through the same JidoHarnessAdapter). The historical
        # `codex`/`opencode` names are NOT accepted; they appear
        # in this error message only as part of the legacy contract
        # for operators who may have old runbooks referencing them.
        {:error,
         "unknown backend \"#{backend}\". Must be one of: jido_harness, pi, claude. " <> hint}
    end
  end

  defp tool_foreman_run_cancel(%{run_id: run_id} = args) do
    start_us = System.monotonic_time(:microsecond)
    command_id = "mcp:#{run_id}:#{System.unique_integer([:positive])}"
    reason = Map.get(args, :reason)

    payload =
      if is_binary(reason) and reason != "" do
        %{run_id: run_id, reason: reason}
      else
        %{run_id: run_id}
      end

    envelope = %{
      type: "run.cancel",
      command_id: command_id,
      aggregate_id: "run:#{run_id}",
      payload: payload
    }

    case CommandGateway.dispatch_operator(envelope) do
      {:ok, result} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_run_cancel", :ok)
        {:ok, result}

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_run_cancel", :error)
        {:error, %ToolError{code: "DOMAIN_ERROR", message: inspect(reason)}}
    end
  end

  defp tool_foreman_workflow_put(%{name: name, manifest: manifest}) do
    start_us = System.monotonic_time(:microsecond)

    if Policy.authorized?("foreman_workflow_put") do
      filename = name <> ".yaml"

      case CatalogWriter.write_manifest(filename, manifest) do
        {:ok, path} ->
          # Check if the catalog poll has observed the change
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

          {:error,
           %ToolError{
             code: "INVALID_FILENAME",
             message: "Path separators and '..' are not allowed"
           }}

        {:error, :outside_catalog} ->
          duration_us = System.monotonic_time(:microsecond) - start_us
          Telemetry.mcp_tool_call(duration_us, "foreman_workflow_put", :error)

          {:error,
           %ToolError{code: "OUTSIDE_CATALOG", message: "Path resolves outside catalog root"}}

        {:error, {:name_stem_mismatch, expected, actual}} ->
          duration_us = System.monotonic_time(:microsecond) - start_us
          Telemetry.mcp_tool_call(duration_us, "foreman_workflow_put", :error)

          {:error,
           %ToolError{
             code: "NAME_STEM_MISMATCH",
             message: "Manifest name '#{actual}' does not match filename stem '#{expected}'"
           }}

        {:error, {:invalid_manifest, detail}} ->
          duration_us = System.monotonic_time(:microsecond) - start_us
          Telemetry.mcp_tool_call(duration_us, "foreman_workflow_put", :error)

          {:error,
           %ToolError{
             code: "INVALID_MANIFEST",
             message: "Manifest validation failed: #{inspect(detail)}"
           }}

        {:error, {:unsupported_construct, _} = detail} ->
          duration_us = System.monotonic_time(:microsecond) - start_us
          Telemetry.mcp_tool_call(duration_us, "foreman_workflow_put", :error)

          {:error,
           %ToolError{
             code: "INVALID_MANIFEST",
             message: "Manifest validation failed: #{inspect(detail)}"
           }}
      end
    else
      duration_us = System.monotonic_time(:microsecond) - start_us
      Telemetry.mcp_tool_call(duration_us, "foreman_workflow_put", :error)
      {:error, %ToolError{code: "POLICY_REFUSED", message: "Workflow writes are disabled"}}
    end
  end

  defp tool_foreman_workflow_delete(%{name: name}) do
    start_us = System.monotonic_time(:microsecond)

    if Policy.authorized?("foreman_workflow_delete") do
      filename = name <> ".yaml"

      case CatalogWriter.delete_manifest(filename) do
        :ok ->
          # Check if the catalog poll has observed the deletion
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

          {:error,
           %ToolError{
             code: "INVALID_FILENAME",
             message: "Path separators and '..' are not allowed"
           }}

        {:error, :outside_catalog} ->
          duration_us = System.monotonic_time(:microsecond) - start_us
          Telemetry.mcp_tool_call(duration_us, "foreman_workflow_delete", :error)

          {:error,
           %ToolError{code: "OUTSIDE_CATALOG", message: "Path resolves outside catalog root"}}

        {:error, :not_found} ->
          duration_us = System.monotonic_time(:microsecond) - start_us
          Telemetry.mcp_tool_call(duration_us, "foreman_workflow_delete", :not_found)
          {:error, %ToolError{code: "NOT_FOUND", message: "Workflow not found: #{name}"}}
      end
    else
      duration_us = System.monotonic_time(:microsecond) - start_us
      Telemetry.mcp_tool_call(duration_us, "foreman_workflow_delete", :error)
      {:error, %ToolError{code: "POLICY_REFUSED", message: "Workflow writes are disabled"}}
    end
  end

  defp tool_foreman_prompt_get(%{name: name}) do
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

            {:error, %ToolError{code: "NOT_FOUND", message: "Prompt not found: #{name}"}}
        end

      {:error, :invalid_filename} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_prompt_get", :error)

        {:error,
         %ToolError{code: "INVALID_FILENAME", message: "Path separators and '..' are not allowed"}}
    end
  end

  defp tool_foreman_prompt_put(%{name: name, content: content}) do
    start_us = System.monotonic_time(:microsecond)

    if Policy.authorized?("foreman_prompt_put") do
      case PromptWriter.write_prompt(name, content) do
        {:ok, _path} ->
          # Check if the catalog poll has observed the change
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

          {:error,
           %ToolError{
             code: "INVALID_FILENAME",
             message: "Path separators and '..' are not allowed"
           }}

        {:error, :outside_catalog} ->
          duration_us = System.monotonic_time(:microsecond) - start_us
          Telemetry.mcp_tool_call(duration_us, "foreman_prompt_put", :error)

          {:error,
           %ToolError{code: "OUTSIDE_CATALOG", message: "Path resolves outside catalog root"}}
      end
    else
      duration_us = System.monotonic_time(:microsecond) - start_us
      Telemetry.mcp_tool_call(duration_us, "foreman_prompt_put", :error)
      {:error, %ToolError{code: "POLICY_REFUSED", message: "Workflow writes are disabled"}}
    end
  end

  defp tool_foreman_doctor(params) when is_map(params) do
    start_us = System.monotonic_time(:microsecond)
    strict = Map.get(params, :strict) || false
    providers = provider_rows()

    case MCPDoctor.run(strict: strict) do
      {:ok, output} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_doctor", :ok)
        {:ok, %{output: output, strict: strict, providers: providers}}

      {:error, :provider_missing, _output} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_doctor", :error)

        {:error,
         %ToolError{
           code: "PROVIDER_MISSING",
           message: "One or more required providers are unavailable"
         }}
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp provider_rows do
    MCPDoctor.rows()
    |> Enum.map(fn {:provider, provider, status, hint} ->
      %{provider: provider, installed: status == :installed, install_hint: hint}
    end)
  end

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
