defmodule ForemanServer.MCP.Tools do
  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore
  alias ForemanServer.ProjectMemory
  alias ForemanServer.ProjectSettings
  alias ForemanServer.ProjectSettingsDTO
  alias ForemanServer.Threads
  alias ForemanServer.Threads.Thread
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
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.TaskProviders.ProviderError
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
            latest_stall: map() | nil,
            provider_session_id: String.t() | nil,
            provider_sessions: [map()],
            usage: ForemanServer.Usage.t() | nil
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
      :latest_stall,
      :provider_session_id,
      :usage,
      provider_sessions: []
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

  defmodule InboxSendResult do
    @enforce_keys [:run_id, :message_id, :status]
    @type t :: %__MODULE__{run_id: String.t(), message_id: String.t(), status: String.t()}
    @derive Jason.Encoder
    defstruct [:run_id, :message_id, :status]
  end

  defmodule ProjectMemoryEntry do
    @moduledoc "Whitelisted memory topic metadata returned by the project-memory tools."
    @enforce_keys [:name, :bytes]
    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            bytes: non_neg_integer(),
            author_kind: String.t() | nil,
            updated_at: String.t() | nil
          }
    @derive Jason.Encoder
    defstruct [:name, :bytes, :author_kind, :updated_at, description: ""]
  end

  defmodule ProjectMemoryListResult do
    @enforce_keys [:project_id, :index, :entries]
    @type t :: %__MODULE__{
            project_id: String.t(),
            index: String.t(),
            entries: [ProjectMemoryEntry.t()]
          }
    @derive Jason.Encoder
    defstruct [:project_id, :index, :entries]
  end

  defmodule ProjectMemoryReadResult do
    @enforce_keys [:name, :content, :bytes]
    @type t :: %__MODULE__{name: String.t(), content: String.t(), bytes: non_neg_integer()}
    @derive Jason.Encoder
    defstruct [:name, :content, :bytes]
  end

  defmodule ProjectMemoryWriteResult do
    @enforce_keys [:name, :sha256, :bytes, :redactions]
    @type t :: %__MODULE__{
            name: String.t(),
            sha256: String.t(),
            bytes: non_neg_integer(),
            redactions: non_neg_integer()
          }
    @derive Jason.Encoder
    defstruct [:name, :sha256, :bytes, :redactions]
  end

  defmodule ProjectMemoryForgetResult do
    @enforce_keys [:name, :status]
    @type t :: %__MODULE__{name: String.t(), status: String.t()}
    @derive Jason.Encoder
    defstruct [:name, :status]
  end

  defmodule TaskAddCommentResult do
    @enforce_keys [:run_id, :task_id, :provider, :status]
    @type t :: %__MODULE__{
            run_id: String.t(),
            task_id: String.t(),
            provider: String.t(),
            status: String.t()
          }
    @derive Jason.Encoder
    defstruct [:run_id, :task_id, :provider, :status]
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

  @schema_foreman_thread_list %{
    name: "foreman_thread_list",
    description:
      "List a project's threads (workflow runs and jobsites), newest first, " <>
        "with last review report and provider session id",
    inputSchema: %{
      type: "object",
      properties: %{
        project_id: %{type: "string", description: "The project ID"},
        status: %{type: "string", description: "Only threads with this raw status"},
        door: %{type: "string", enum: ["workflow", "jobsite"], description: "Only this door"},
        limit: %{type: "integer", minimum: 1, maximum: 500, description: "Default 100"}
      },
      required: ["project_id"]
    }
  }

  @schema_foreman_thread_find %{
    name: "foreman_thread_find",
    description:
      "Find the existing thread a request most likely belongs to (read-only, deterministic): " <>
        "ranks exact external_id/branch/PR matches above conservative text matches. " <>
        "Text matches are suggestions only and skip resolved/deleted threads. Never starts a run.",
    inputSchema: %{
      type: "object",
      properties: %{
        project_id: %{type: "string", description: "The project ID"},
        q: %{type: "string", description: "Free text to match against thread title and prompt"},
        external_id: %{type: "string", description: "Exact bead/external task id"},
        branch: %{type: "string", description: "Exact branch name"},
        pr: %{type: "string", description: "PR URL or number"},
        limit: %{type: "integer", minimum: 1, maximum: 500, description: "Default 5"}
      },
      required: ["project_id"]
    }
  }

  @schema_foreman_thread_get %{
    name: "foreman_thread_get",
    description: "Get one thread by id (run:<run_id> or jobsite:<jobsite_id>)",
    inputSchema: %{
      type: "object",
      properties: %{
        thread_id: %{type: "string", description: "The thread ID"}
      },
      required: ["thread_id"]
    }
  }

  @schema_foreman_thread_transcript %{
    name: "foreman_thread_transcript",
    description:
      "Read a thread's structured transcript turns after a cursor (seq). Returns " <>
        "turns, next_cursor, truncated, omitted_entries and terminal. Read-only.",
    inputSchema: %{
      type: "object",
      properties: %{
        thread_id: %{type: "string", description: "The thread ID"},
        after: %{type: "integer", description: "Return turns with seq > after (default -1)"},
        limit: %{type: "integer", description: "Page size, 1..1000 (default 200)"}
      },
      required: ["thread_id"]
    }
  }

  @schema_foreman_thread_stop %{
    name: "foreman_thread_stop",
    description:
      "Stop a thread (workflow run or jobsite). Terminal threads are rejected with " <>
        "their status. Never merges or approves.",
    inputSchema: %{
      type: "object",
      properties: %{
        thread_id: %{type: "string", description: "The thread ID"},
        reason: %{type: "string", description: "Why it is stopped (default operator_stop)"}
      },
      required: ["thread_id"]
    }
  }

  @schema_foreman_thread_steer %{
    name: "foreman_thread_steer",
    description:
      "Send an operator message to a thread (workflow run or jobsite). The work is " <>
        "paused and resumed with the message in its next prompt. Terminal threads are rejected.",
    inputSchema: %{
      type: "object",
      properties: %{
        thread_id: %{type: "string", description: "The thread ID"},
        text: %{type: "string", description: "The message (1..8000 characters)"},
        message_id: %{
          type: "string",
          description: "Idempotency id; re-sending the same id is a no-op"
        },
        resume: %{
          type: "boolean",
          description: "Workflow door: false keeps a paused run paused (default true)"
        }
      },
      required: ["thread_id", "text"]
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

  @schema_foreman_project_settings_get %{
    name: "foreman_project_settings_get",
    description:
      "Get a project's typed settings (goal, instructions, thread/coordinator model and effort, " <>
        "limits), its status (active|paused|archived) and its live limits/usage. Never includes env values.",
    inputSchema: %{
      type: "object",
      properties: %{
        project_id: %{type: "string", description: "The project ID"}
      },
      required: ["project_id"]
    }
  }

  @schema_foreman_project_settings_update %{
    name: "foreman_project_settings_update",
    description:
      "Update a project's settings. Only the listed settings can change; a setting named in `clear` is removed. " <>
        "Requires allow_workflow_writes. Retries with the same idempotency_key and arguments are one command.",
    inputSchema: %{
      type: "object",
      properties: %{
        project_id: %{type: "string", description: "The project ID"},
        goal: %{type: "string", description: "Project goal (max 2000 characters)"},
        instructions: %{
          type: "string",
          description: "Standing instructions for every thread (max 16000 characters)"
        },
        thread_model: %{type: "string", description: "Default model for threads"},
        thread_effort: %{type: "string", description: "Default effort: low, medium or high"},
        coordinator_provider: %{type: "string", description: "Coordinator provider: pi or claude"},
        coordinator_model: %{type: "string", description: "Coordinator model"},
        coordinator_effort: %{
          type: "string",
          description: "Coordinator effort: low, medium or high"
        },
        max_concurrent_runs: %{type: "integer", description: "Concurrent runs limit (1..1000)"},
        daily_thread_cap: %{type: "integer", description: "Threads per UTC day (1..10000)"},
        clear: %{
          type: "array",
          items: %{type: "string"},
          description: "Names of settings to clear"
        },
        idempotency_key: %{type: "string", description: "Caller supplied retry key"}
      },
      required: ["project_id"],
      additionalProperties: false
    }
  }

  @schema_foreman_project_pause %{
    name: "foreman_project_pause",
    description:
      "Pause a project: new tasks, runs, jobsites and bead imports are refused (in-flight work continues). Requires allow_workflow_writes.",
    inputSchema: %{
      type: "object",
      properties: %{
        project_id: %{type: "string", description: "The project ID"},
        reason: %{type: "string", description: "Why the project is paused"}
      },
      required: ["project_id"],
      additionalProperties: false
    }
  }

  @schema_foreman_project_resume %{
    name: "foreman_project_resume",
    description:
      "Resume a paused project; held work is admitted again. Requires allow_workflow_writes.",
    inputSchema: %{
      type: "object",
      properties: %{
        project_id: %{type: "string", description: "The project ID"}
      },
      required: ["project_id"],
      additionalProperties: false
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

  @schema_foreman_task_add_comment %{
    name: "foreman_task_add_comment",
    description:
      "Append a structured Work Log comment to the provider-backed task for a run. Requires allow_workflow_writes.",
    inputSchema: %{
      type: "object",
      properties: %{
        run_id: %{type: "string", description: "The Foreman run ID"},
        workflow_name: %{
          type: "string",
          maxLength: 100,
          description: "Workflow name (1-100 chars)"
        },
        phase_name: %{type: "string", maxLength: 100, description: "Phase name (1-100 chars)"},
        description: %{
          type: "string",
          maxLength: 2000,
          description: "Concise work performed description (1-2000 chars)"
        }
      },
      required: ["run_id", "workflow_name", "phase_name", "description"]
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

  @schema_foreman_run_pause %{
    name: "foreman_run_pause",
    description: "Pause a run",
    inputSchema: %{
      type: "object",
      properties: %{
        run_id: %{type: "string", description: "The run ID"},
        reason: %{type: "string", description: "The pause reason"}
      },
      required: ["run_id"]
    }
  }

  @schema_foreman_run_resume %{
    name: "foreman_run_resume",
    description: "Resume a paused run",
    inputSchema: %{
      type: "object",
      properties: %{
        run_id: %{type: "string", description: "The run ID"}
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

  @schema_foreman_inbox_send %{
    name: "foreman_inbox_send",
    description:
      "Append a concise operator-facing progress note to a run inbox. Requires allow_workflow_writes.",
    inputSchema: %{
      type: "object",
      required: ["run_id", "body"],
      properties: %{
        "run_id" => %{type: "string", description: "The run_id."},
        "body" => %{
          type: "string",
          maxLength: 2000,
          description: "Concise progress note body (1-2000 UTF-8 characters)."
        },
        "message_id" => %{type: "string", description: "Optional caller-stable message ID."},
        "command_id" => %{type: "string", description: "Optional caller-stable command ID."},
        "metadata" => %{
          type: "object",
          description:
            "Optional JSON-safe metadata. Allowed keys: phase_id, worker_id, session_id, severity."
        }
      }
    }
  }

  @schema_foreman_project_memory_list %{
    name: "foreman_project_memory_list",
    description: ProjectMemory.Guidance.tool_description(:list),
    inputSchema: %{
      type: "object",
      required: ["project_id"],
      properties: %{"project_id" => %{type: "string", description: "The project ID."}}
    }
  }

  @schema_foreman_project_memory_read %{
    name: "foreman_project_memory_read",
    description: ProjectMemory.Guidance.tool_description(:read),
    inputSchema: %{
      type: "object",
      required: ["project_id", "name"],
      properties: %{
        "project_id" => %{type: "string", description: "The project ID."},
        "name" => %{type: "string", description: "Topic name, e.g. \"conventions\"."}
      }
    }
  }

  @schema_foreman_project_memory_write %{
    name: "foreman_project_memory_write",
    description:
      ProjectMemory.Guidance.tool_description(:write) <> "\nRequires allow_workflow_writes.",
    inputSchema: %{
      type: "object",
      required: ["project_id", "name", "content"],
      properties: %{
        "project_id" => %{type: "string", description: "The project ID."},
        "name" => %{
          type: "string",
          description: "Topic name: lowercase letters, digits, - and _ (max 64)."
        },
        "description" => %{
          type: "string",
          maxLength: 200,
          description: "One-line hook shown in the MEMORY.md index."
        },
        "content" => %{
          type: "string",
          maxLength: 65_536,
          description: "Markdown content of the topic (secrets are redacted)."
        },
        "run_id" => %{type: "string", description: "Optional run recorded as the author."},
        "session_id" => %{type: "string", description: "Optional session recorded as the author."}
      }
    }
  }

  @schema_foreman_project_memory_forget %{
    name: "foreman_project_memory_forget",
    description:
      ProjectMemory.Guidance.tool_description(:forget) <> "\nRequires allow_workflow_writes.",
    inputSchema: %{
      type: "object",
      required: ["project_id", "name"],
      properties: %{
        "project_id" => %{type: "string", description: "The project ID."},
        "name" => %{type: "string", description: "Topic name to delete."},
        "run_id" => %{type: "string", description: "Optional run recorded as the author."},
        "session_id" => %{type: "string", description: "Optional session recorded as the author."}
      }
    }
  }

  @tools [
    @schema_foreman_run_get,
    @schema_foreman_run_status,
    @schema_foreman_thread_list,
    @schema_foreman_thread_get,
    @schema_foreman_thread_find,
    @schema_foreman_thread_transcript,
    @schema_foreman_thread_stop,
    @schema_foreman_thread_steer,
    @schema_foreman_queue_status,
    @schema_foreman_project_list,
    @schema_foreman_project_get,
    @schema_foreman_project_settings_get,
    @schema_foreman_project_settings_update,
    @schema_foreman_project_pause,
    @schema_foreman_project_resume,
    @schema_foreman_workflow_list,
    @schema_foreman_workflow_get,
    @schema_foreman_workflow_validate,
    @schema_foreman_task_create,
    @schema_foreman_task_list,
    @schema_foreman_task_get,
    @schema_foreman_task_update,
    @schema_foreman_task_add_comment,
    @schema_foreman_run_cancel,
    @schema_foreman_run_pause,
    @schema_foreman_run_resume,
    @schema_foreman_workflow_put,
    @schema_foreman_workflow_delete,
    @schema_foreman_prompt_put,
    @schema_foreman_prompt_get,
    @schema_foreman_doctor,
    @schema_foreman_run_get_logs,
    @schema_foreman_run_get_events,
    @schema_foreman_run_get_activity,
    @schema_foreman_inbox_get,
    @schema_foreman_inbox_send,
    @schema_foreman_project_memory_list,
    @schema_foreman_project_memory_read,
    @schema_foreman_project_memory_write,
    @schema_foreman_project_memory_forget
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

  defp tool_foreman_thread_list(%{project_id: project_id} = args) do
    start_us = System.monotonic_time(:microsecond)

    result =
      with true <- is_binary(project_id) and project_id != "",
           {:ok, opts} <- thread_list_opts(args) do
        {:ok, project_id |> Threads.list(opts) |> Enum.map(&Thread.to_dto/1)}
      else
        false -> {:error, "project_id must be a non-empty string"}
        {:error, message} -> {:error, message}
      end

    duration_us = System.monotonic_time(:microsecond) - start_us

    case result do
      {:ok, _} = ok ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_list", :ok)
        ok

      {:error, message} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_list", :error)
        {:error, %ToolError{code: "INVALID_PARAMS", message: message}}
    end
  end

  defp thread_list_opts(args) do
    with {:ok, limit} <- thread_limit(Map.get(args, :limit)),
         {:ok, door} <- thread_door(Map.get(args, :door)),
         {:ok, status} <- thread_status(Map.get(args, :status)) do
      opts =
        Enum.reject([limit: limit, door: door, status: status], fn {_k, v} -> is_nil(v) end)

      {:ok, opts}
    end
  end

  defp thread_limit(nil), do: {:ok, nil}

  defp thread_limit(limit) when is_integer(limit) do
    max = Threads.max_limit()

    if limit >= 1 and limit <= max,
      do: {:ok, limit},
      else: {:error, "limit must be an integer between 1 and #{max}"}
  end

  defp thread_limit(_), do: {:error, "limit must be an integer"}

  defp thread_door(nil), do: {:ok, nil}
  defp thread_door("workflow"), do: {:ok, :workflow}
  defp thread_door("jobsite"), do: {:ok, :jobsite}
  defp thread_door(_), do: {:error, "door must be workflow or jobsite"}

  defp thread_status(nil), do: {:ok, nil}
  defp thread_status(status) when is_binary(status) and status != "", do: {:ok, status}
  defp thread_status(_), do: {:error, "status must be a non-empty string"}

  defp tool_foreman_thread_find(%{project_id: project_id} = args) do
    start_us = System.monotonic_time(:microsecond)

    result =
      if is_binary(project_id) and project_id != "" do
        opts = [
          text: Map.get(args, :q),
          external_id: Map.get(args, :external_id),
          branch: Map.get(args, :branch),
          pr: Map.get(args, :pr),
          limit: Map.get(args, :limit)
        ]

        case ForemanServer.Threads.Finder.find(project_id, opts) do
          {:ok, candidates} ->
            {:ok, Enum.map(candidates, &ForemanServer.Threads.Finder.to_dto/1)}

          {:error, :no_criteria} ->
            {:error, "one of q, external_id, branch, pr is required"}
        end
      else
        {:error, "project_id must be a non-empty string"}
      end

    duration_us = System.monotonic_time(:microsecond) - start_us

    case result do
      {:ok, _} = ok ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_find", :ok)
        ok

      {:error, message} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_find", :error)
        {:error, %ToolError{code: "INVALID_PARAMS", message: message}}
    end
  end

  defp tool_foreman_thread_get(%{thread_id: thread_id}) do
    start_us = System.monotonic_time(:microsecond)

    result =
      if is_binary(thread_id), do: Threads.get(thread_id), else: {:error, :thread_not_found}

    duration_us = System.monotonic_time(:microsecond) - start_us

    case result do
      {:ok, thread} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_get", :ok)
        {:ok, Thread.to_dto(thread)}

      {:error, :thread_not_found} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_get", :not_found)
        {:error, %ToolError{code: "NOT_FOUND", message: "Thread not found"}}
    end
  end

  defp tool_foreman_thread_transcript(%{thread_id: thread_id} = args) do
    start_us = System.monotonic_time(:microsecond)

    result =
      with true <- is_binary(thread_id),
           {:ok, opts} <- transcript_opts(args) do
        ForemanServer.Threads.Transcript.page(thread_id, opts)
      else
        false -> {:error, :thread_not_found}
        {:error, _} = error -> error
      end

    duration_us = System.monotonic_time(:microsecond) - start_us

    case result do
      {:ok, page} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_transcript", :ok)
        {:ok, ForemanServer.Threads.Transcript.Page.to_dto(page)}

      {:error, :thread_not_found} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_transcript", :not_found)
        {:error, %ToolError{code: "NOT_FOUND", message: "Thread not found"}}

      {:error, {:invalid_option, key}} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_transcript", :error)
        {:error, %ToolError{code: "INVALID_PARAMS", message: "#{key} is out of range"}}

      {:error, reason} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_transcript", :error)

        {:error,
         %ToolError{code: "DOMAIN_ERROR", message: "transcript unavailable: #{inspect(reason)}"}}
    end
  end

  defp transcript_opts(args) do
    opts =
      for key <- [:after, :limit], Map.get(args, key) != nil, do: {key, Map.fetch!(args, key)}

    if Enum.all?(opts, fn {_key, value} -> is_integer(value) end),
      do: {:ok, opts},
      else: {:error, {:invalid_option, :after}}
  end

  defp tool_foreman_thread_stop(%{thread_id: thread_id} = args) do
    start_us = System.monotonic_time(:microsecond)
    reason = Map.get(args, :reason)

    result =
      cond do
        not is_binary(thread_id) -> {:error, :thread_not_found}
        not (is_nil(reason) or is_binary(reason)) -> {:error, :invalid_reason}
        true -> ForemanServer.Threads.Actions.stop(thread_id, reason)
      end

    duration_us = System.monotonic_time(:microsecond) - start_us

    case result do
      {:ok, :stopping} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_stop", :ok)
        {:ok, %{thread_id: thread_id, requested: "stopping"}}

      {:error, :thread_not_found} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_stop", :not_found)
        {:error, %ToolError{code: "NOT_FOUND", message: "Thread not found"}}

      {:error, :invalid_reason} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_stop", :error)
        {:error, %ToolError{code: "INVALID_PARAMS", message: "reason must be a string"}}

      {:error, other} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_stop", :error)
        {:error, %ToolError{code: "DOMAIN_ERROR", message: inspect(other)}}
    end
  end

  defp tool_foreman_thread_steer(%{thread_id: thread_id} = args) do
    start_us = System.monotonic_time(:microsecond)

    opts =
      [resume: Map.get(args, :resume, true)]
      |> then(fn opts ->
        case Map.get(args, :message_id) do
          id when is_binary(id) and id != "" -> Keyword.put(opts, :message_id, id)
          _ -> opts
        end
      end)

    result =
      cond do
        not is_binary(thread_id) -> {:error, :thread_not_found}
        not is_boolean(opts[:resume]) -> {:error, :invalid_resume}
        true -> ForemanServer.Threads.Actions.steer(thread_id, Map.get(args, :text), opts)
      end

    duration_us = System.monotonic_time(:microsecond) - start_us

    case result do
      {:ok, %{message_id: message_id, mode: mode}} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_steer", :ok)

        {:ok, %{thread_id: thread_id, message_id: message_id, mode: Atom.to_string(mode)}}

      {:error, :thread_not_found} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_steer", :not_found)
        {:error, %ToolError{code: "NOT_FOUND", message: "Thread not found"}}

      {:error, {:invalid_text, why}} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_steer", :error)
        {:error, %ToolError{code: "INVALID_PARAMS", message: "text is #{why}"}}

      {:error, :invalid_resume} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_steer", :error)
        {:error, %ToolError{code: "INVALID_PARAMS", message: "resume must be a boolean"}}

      {:error, other} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_thread_steer", :error)
        {:error, %ToolError{code: "DOMAIN_ERROR", message: inspect(other)}}
    end
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

  defp tool_foreman_project_memory_list(%{project_id: project_id}) do
    start_us = System.monotonic_time(:microsecond)

    result =
      with {:ok, topics} <- ProjectMemory.list(project_id),
           {:ok, index} <- ProjectMemory.index(project_id) do
        {:ok,
         %__MODULE__.ProjectMemoryListResult{
           project_id: project_id,
           index: index,
           entries: Enum.map(topics, &project_memory_entry/1)
         }}
      end

    project_memory_reply("foreman_project_memory_list", start_us, result)
  end

  defp tool_foreman_project_memory_read(%{project_id: project_id, name: name}) do
    start_us = System.monotonic_time(:microsecond)

    result =
      with {:ok, topic, content} <- ProjectMemory.read(project_id, name) do
        {:ok,
         %__MODULE__.ProjectMemoryReadResult{
           name: topic.name,
           content: content,
           bytes: byte_size(content)
         }}
      end

    project_memory_reply("foreman_project_memory_read", start_us, result)
  end

  defp tool_foreman_project_memory_write(
         %{project_id: project_id, name: name, content: content} = args
       ) do
    start_us = System.monotonic_time(:microsecond)

    result =
      with :ok <- authorize_write_tool("foreman_project_memory_write"),
           {:ok, topic} <-
             ProjectMemory.write(
               project_id,
               %{name: name, content: content, description: Map.get(args, :description)},
               project_memory_author(args)
             ) do
        {:ok,
         %__MODULE__.ProjectMemoryWriteResult{
           name: topic.name,
           sha256: topic.sha256,
           bytes: topic.bytes,
           redactions: topic.redactions
         }}
      end

    project_memory_reply("foreman_project_memory_write", start_us, result)
  end

  defp tool_foreman_project_memory_forget(%{project_id: project_id, name: name} = args) do
    start_us = System.monotonic_time(:microsecond)

    result =
      with :ok <- authorize_write_tool("foreman_project_memory_forget"),
           {:ok, topic} <- ProjectMemory.forget(project_id, name, project_memory_author(args)) do
        {:ok, %__MODULE__.ProjectMemoryForgetResult{name: topic.name, status: "forgotten"}}
      end

    project_memory_reply("foreman_project_memory_forget", start_us, result)
  end

  # An MCP caller is an agent; operators use the CLI/HTTP surfaces.
  defp project_memory_author(args),
    do: %{kind: :agent, ref: Map.get(args, :run_id) || Map.get(args, :session_id)}

  defp project_memory_entry(topic) do
    %__MODULE__.ProjectMemoryEntry{
      name: topic.name,
      description: topic.description,
      bytes: topic.bytes,
      author_kind: topic.author_kind,
      updated_at: topic.updated_at
    }
  end

  defp project_memory_reply(tool, start_us, result) do
    duration_us = System.monotonic_time(:microsecond) - start_us

    case result do
      {:ok, _} = ok ->
        Telemetry.mcp_tool_call(duration_us, tool, :ok)
        ok

      {:error, %ToolError{}} = error ->
        Telemetry.mcp_tool_call(duration_us, tool, :error)
        error

      {:error, %ProjectMemory.Error{} = error} ->
        Telemetry.mcp_tool_call(duration_us, tool, :error)
        {:error, project_memory_tool_error(error)}
    end
  end

  defp project_memory_tool_error(%ProjectMemory.Error{code: code, message: message})
       when code in [:not_found, :project_not_found],
       do: %ToolError{code: "NOT_FOUND", message: "#{code}: #{message}"}

  defp project_memory_tool_error(%ProjectMemory.Error{code: code, message: message})
       when code in [
              :name_invalid,
              :description_invalid,
              :content_too_large,
              :index_full,
              :too_many_topics,
              :content_not_durable
            ],
       do: %ToolError{code: "INVALID_PARAMS", message: "#{code}: #{message}"}

  defp project_memory_tool_error(%ProjectMemory.Error{code: code, message: message}),
    do: %ToolError{code: "DOMAIN_ERROR", message: "#{code}: #{message}"}

  defp tool_foreman_inbox_send(%{} = args) do
    start_us = System.monotonic_time(:microsecond)

    with :ok <- authorize_write_tool("foreman_inbox_send"),
         {:ok, command} <- build_inbox_send_command(args),
         :ok <- require_run_exists(command.payload.run_id),
         {:ok, _result} <- CommandGateway.dispatch_operator(command) do
      duration_us = System.monotonic_time(:microsecond) - start_us
      Telemetry.mcp_tool_call(duration_us, "foreman_inbox_send", :ok)

      {:ok,
       %__MODULE__.InboxSendResult{
         run_id: command.payload.run_id,
         message_id: command.payload.message_id,
         status: "sent"
       }}
    else
      {:error, %ToolError{}} = error ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_inbox_send", :error)
        error

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_inbox_send", :error)
        {:error, inbox_send_tool_error(reason)}
    end
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
    result = Enum.map(ProjectionStore.list_projects(), &ProjectSettings.public_view/1)
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
      do: {:ok, ProjectSettings.public_view(result)},
      else: {:error, %ToolError{code: "NOT_FOUND", message: "Project not found"}}
  end

  defp tool_foreman_project_settings_get(%{project_id: project_id}) do
    start_us = System.monotonic_time(:microsecond)
    result = ProjectSettingsDTO.fetch(project_id)
    duration_us = System.monotonic_time(:microsecond) - start_us

    case result do
      {:ok, dto} ->
        Telemetry.mcp_tool_call(duration_us, "foreman_project_settings_get", :ok)
        {:ok, dto}

      :not_found ->
        Telemetry.mcp_tool_call(duration_us, "foreman_project_settings_get", :not_found)
        {:error, %ToolError{code: "NOT_FOUND", message: "Project not found"}}
    end
  end

  @settings_update_keys ~w(goal instructions thread_model thread_effort coordinator_provider
                           coordinator_model coordinator_effort max_concurrent_runs
                           daily_thread_cap)a

  # The command id is content-derived (tool + canonical args + caller key), so a
  # retry of the same update collapses into one command while two different
  # updates of the same project stay two commands.
  defp tool_foreman_project_settings_update(%{project_id: project_id} = args) do
    tool = "foreman_project_settings_update"

    with :ok <- authorize_write(tool) do
      payload =
        args
        |> Map.take(@settings_update_keys)
        |> Map.put(:project_id, project_id)
        |> put_cleared(Map.get(args, :clear))

      dispatch_project_command(tool, "project.update", project_id, payload, args)
    end
  end

  defp put_cleared(payload, clear) when is_list(clear),
    do: Map.put(payload, :cleared_settings, clear)

  defp put_cleared(payload, _none), do: payload

  # Pause/resume are not idempotent over time (pause, resume, pause again are
  # three real commands), so without a caller key they get a random id.
  defp tool_foreman_project_pause(%{project_id: project_id} = args) do
    tool = "foreman_project_pause"

    with :ok <- authorize_write(tool) do
      payload =
        case Map.get(args, :reason) do
          reason when is_binary(reason) and reason != "" ->
            %{project_id: project_id, reason: reason}

          _ ->
            %{project_id: project_id}
        end

      dispatch_project_command(tool, "project.pause", project_id, payload, nil)
    end
  end

  defp tool_foreman_project_resume(%{project_id: project_id}) do
    tool = "foreman_project_resume"

    with :ok <- authorize_write(tool) do
      dispatch_project_command(tool, "project.resume", project_id, %{project_id: project_id}, nil)
    end
  end

  defp authorize_write(tool) do
    if Policy.authorized?(tool) do
      :ok
    else
      {:error,
       %ToolError{
         code: "WRITE_NOT_ALLOWED",
         message: "#{tool} requires allow_workflow_writes to be enabled"
       }}
    end
  end

  defp dispatch_project_command(tool, type, project_id, payload, idempotent_args) do
    start_us = System.monotonic_time(:microsecond)

    envelope = %{
      type: type,
      command_id: project_command_id(tool, project_id, idempotent_args),
      aggregate_id: "project:#{project_id}",
      payload: payload
    }

    result = CommandGateway.dispatch_operator(envelope)
    duration_us = System.monotonic_time(:microsecond) - start_us

    case result do
      {:ok, event} ->
        Telemetry.mcp_tool_call(duration_us, tool, :ok)
        {:ok, event}

      {:error, reason} ->
        Telemetry.mcp_tool_call(duration_us, tool, :error)
        {:error, %ToolError{code: error_code(reason), message: inspect(reason)}}
    end
  end

  defp project_command_id(tool, project_id, nil),
    do: "mcp:#{tool}:#{project_id}:#{System.unique_integer([:positive])}"

  defp project_command_id(tool, _project_id, args) do
    key = Map.get(args, :idempotency_key) || ""

    canonical =
      args |> Map.delete(:idempotency_key) |> canonical_json() |> Jason.encode!()

    "mcp:" <> Base.encode16(:crypto.hash(:sha256, tool <> canonical <> key), case: :lower)
  end

  defp canonical_json(%{} = map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonical_json(v)} end)
    |> Enum.sort()
    |> Jason.OrderedObject.new()
  end

  defp canonical_json(list) when is_list(list), do: Enum.map(list, &canonical_json/1)
  defp canonical_json(other), do: other

  # Stable machine code: the head atom of the error tuple (`instructions_too_long`,
  # `project_paused`, ...). The full tuple stays in the message.
  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp error_code(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: Atom.to_string(elem(reason, 0))

  defp error_code(_reason), do: "DOMAIN_ERROR"

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

  @inbox_send_body_max 2_000
  @inbox_send_metadata_keys ~w(phase_id worker_id session_id severity)
  @inbox_send_metadata_max_value_length 200
  @inbox_send_severity_values ~w(info warn error critical)
  @inbox_send_args [:run_id, :body, :message_id, :command_id, :metadata]

  defp authorize_write_tool(tool_name) do
    if Policy.authorized?(tool_name) do
      :ok
    else
      {:error, %ToolError{code: "POLICY_REFUSED", message: "Tool #{tool_name} is not permitted"}}
    end
  end

  defp require_run_exists(run_id) do
    if ProjectionStore.run(run_id) do
      :ok
    else
      {:error, :run_not_found}
    end
  end

  defp build_inbox_send_command(%{} = args) do
    with :ok <- reject_unknown_inbox_send_args(args),
         {:ok, run_id} <- required_nonblank(args, :run_id),
         {:ok, body} <- required_nonblank(args, :body),
         :ok <- validate_inbox_body(body),
         :ok <- reject_command_id_without_message_id(args),
         {:ok, message_id} <- optional_nonblank(args, :message_id, &mint_inbox_message_id/0),
         {:ok, command_id} <-
           optional_nonblank(args, :command_id, fn -> inbox_command_id(run_id, message_id) end),
         {:ok, metadata} <- normalize_inbox_metadata(Map.get(args, :metadata)) do
      {:ok,
       %{
         type: "inbox.send",
         command_id: command_id,
         aggregate_id: "inbox:" <> run_id,
         payload: %{
           run_id: run_id,
           message_id: message_id,
           body: body,
           metadata: metadata
         }
       }}
    end
  end

  # A caller-supplied command_id without a caller-supplied message_id
  # would report a freshly-minted message_id back to the caller on every
  # call (see mint_inbox_message_id/0 below), including a genuine retry --
  # but CommandRouter dedupes by command_id, so only the FIRST call's
  # message actually persists. A retry would then tell the caller a
  # message_id that was never stored. Reject the combination outright
  # rather than silently reporting a mismatched identifier.
  defp reject_command_id_without_message_id(args) do
    if Map.get(args, :command_id) != nil and Map.get(args, :message_id) == nil do
      {:error,
       %ToolError{
         code: "INVALID_PARAMS",
         message: "command_id requires message_id to also be supplied"
       }}
    else
      :ok
    end
  end

  defp reject_unknown_inbox_send_args(args) do
    unknown = Map.keys(args) -- @inbox_send_args

    if unknown == [] do
      :ok
    else
      {:error,
       %ToolError{
         code: "INVALID_PARAMS",
         message: "Unknown arguments: " <> Enum.map_join(unknown, ", ", &to_string/1)
       }}
    end
  end

  defp required_nonblank(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, %ToolError{code: "INVALID_PARAMS", message: "#{key} must be nonblank"}}
        else
          {:ok, value}
        end

      _ ->
        {:error, %ToolError{code: "INVALID_PARAMS", message: "#{key} must be a string"}}
    end
  end

  defp optional_nonblank(args, key, default_fun) do
    case Map.get(args, key) do
      nil ->
        {:ok, default_fun.()}

      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, %ToolError{code: "INVALID_PARAMS", message: "#{key} must be nonblank"}}
        else
          {:ok, value}
        end

      _ ->
        {:error, %ToolError{code: "INVALID_PARAMS", message: "#{key} must be a string"}}
    end
  end

  defp validate_inbox_body(body) do
    if String.length(body) <= @inbox_send_body_max do
      :ok
    else
      {:error,
       %ToolError{
         code: "INVALID_PARAMS",
         message: "body must be at most #{@inbox_send_body_max} UTF-8 characters"
       }}
    end
  end

  defp mint_inbox_message_id do
    "msg_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp inbox_command_id(run_id, message_id) do
    digest = :crypto.hash(:sha256, run_id <> "\0" <> message_id)
    "mcp:foreman_inbox_send:" <> Base.url_encode64(digest, padding: false)
  end

  defp normalize_inbox_metadata(nil), do: {:ok, %{}}

  defp normalize_inbox_metadata(metadata) when is_map(metadata) do
    with :ok <- validate_metadata_key_count(metadata),
         {:ok, validated} <-
           Enum.reduce_while(metadata, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
             case normalize_inbox_metadata_key(key) do
               {:ok, normalized_key} ->
                 with :ok <- reject_duplicate_metadata_key(acc, normalized_key),
                      :ok <- validate_metadata_value(normalized_key, value),
                      :ok <- validate_metadata_value_size(normalized_key, value) do
                   {:cont, {:ok, Map.put(acc, normalized_key, value)}}
                 else
                   {:error, %ToolError{}} = error -> {:halt, error}
                 end

               {:error, %ToolError{}} = error ->
                 {:halt, error}
             end
           end) do
      {:ok, validated}
    else
      {:error, %ToolError{}} = error -> error
    end
  end

  defp normalize_inbox_metadata(_metadata) do
    {:error, %ToolError{code: "INVALID_PARAMS", message: "metadata must be an object"}}
  end

  defp validate_metadata_key_count(metadata) do
    if map_size(metadata) <= 8 do
      :ok
    else
      {:error, %ToolError{code: "INVALID_PARAMS", message: "metadata must have at most 8 keys"}}
    end
  end

  defp reject_duplicate_metadata_key(acc, normalized_key) do
    if Map.has_key?(acc, normalized_key) do
      {:error,
       %ToolError{
         code: "INVALID_PARAMS",
         message: "duplicate metadata key (atom/string collision): #{normalized_key}"
       }}
    else
      :ok
    end
  end

  defp validate_metadata_value("severity", value) do
    if Enum.member?(@inbox_send_severity_values, value) do
      :ok
    else
      {:error,
       %ToolError{
         code: "INVALID_PARAMS",
         message:
           "metadata.severity must be one of " <> Enum.join(@inbox_send_severity_values, ", ")
       }}
    end
  end

  # Metadata keys are identifiers (phase_id/worker_id/session_id) or the
  # whitelisted severity string -- never nested structures. Requiring a
  # binary here, rather than accepting any term and only size-checking
  # binaries below, is what keeps validate_metadata_value_size/2 a real
  # bound: an arbitrarily large or deep map/list value would otherwise
  # bypass the byte-size limit entirely (its non-binary clause is `:ok`).
  defp validate_metadata_value(_key, value) when is_binary(value), do: :ok

  defp validate_metadata_value(key, _value) do
    {:error, %ToolError{code: "INVALID_PARAMS", message: "metadata.#{key} must be a string"}}
  end

  defp validate_metadata_value_size(_key, value) when is_binary(value) do
    if byte_size(value) <= @inbox_send_metadata_max_value_length do
      :ok
    else
      {:error,
       %ToolError{
         code: "INVALID_PARAMS",
         message:
           "metadata value must be at most " <>
             Integer.to_string(@inbox_send_metadata_max_value_length) <> " bytes"
       }}
    end
  end

  defp validate_metadata_value_size(_key, _value), do: :ok

  defp normalize_inbox_metadata_key(key) when is_atom(key),
    do: normalize_inbox_metadata_key(Atom.to_string(key))

  defp normalize_inbox_metadata_key(key) when is_binary(key) do
    if key in @inbox_send_metadata_keys do
      {:ok, key}
    else
      {:error,
       %ToolError{
         code: "INVALID_PARAMS",
         message: "Unknown metadata key: #{key}"
       }}
    end
  end

  defp normalize_inbox_metadata_key(key) do
    {:error,
     %ToolError{
       code: "INVALID_PARAMS",
       message: "Unknown metadata key: #{inspect(key)}"
     }}
  end

  defp inbox_send_tool_error(:run_not_found),
    do: %ToolError{code: "NOT_FOUND", message: "Run not found"}

  defp inbox_send_tool_error({:invalid_envelope, reason}),
    do: %ToolError{code: "INVALID_PARAMS", message: "Invalid inbox send envelope: #{reason}"}

  defp inbox_send_tool_error({:command_not_allowed, _type}),
    do: %ToolError{code: "POLICY_REFUSED", message: "Tool foreman_inbox_send is not permitted"}

  defp inbox_send_tool_error({:already_exists, :message, message_id}),
    do: %ToolError{code: "ALREADY_EXISTS", message: "Inbox message already exists: #{message_id}"}

  defp inbox_send_tool_error({:not_found, :run, _run_id}),
    do: %ToolError{code: "NOT_FOUND", message: "Run not found"}

  defp inbox_send_tool_error(reason),
    do: %ToolError{code: "DOMAIN_ERROR", message: inspect(reason)}

  @task_add_comment_args [:run_id, :workflow_name, :phase_name, :description]
  @task_add_comment_field_max 100
  @task_add_comment_description_max 2_000
  @task_add_comment_body_max 2_500

  defp tool_foreman_task_add_comment(%{} = args) do
    start_us = System.monotonic_time(:microsecond)

    with :ok <- authorize_write_tool("foreman_task_add_comment"),
         :ok <- reject_unknown_task_add_comment_args(args),
         {:ok, run_id} <- required_nonblank(args, :run_id),
         {:ok, workflow_name} <-
           required_bounded(args, :workflow_name, @task_add_comment_field_max),
         {:ok, phase_name} <- required_bounded(args, :phase_name, @task_add_comment_field_max),
         {:ok, description} <-
           required_bounded(args, :description, @task_add_comment_description_max),
         {:ok, body} <- compose_task_comment_body(workflow_name, phase_name, description),
         {:ok, run} <- fetch_comment_run(run_id),
         {:ok, task_id} <- fetch_comment_task_id(run),
         {:ok, task} <- fetch_comment_task(task_id),
         {:ok, external_id} <- fetch_comment_external_id(task),
         {:ok, project_id} <- fetch_comment_project_id(run),
         {:ok, provider_module, provider_config} <- fetch_comment_provider_config(project_id),
         {:ok, _comment} <- provider_module.annotate(external_id, body, provider_config) do
      duration_us = System.monotonic_time(:microsecond) - start_us
      Telemetry.mcp_tool_call(duration_us, "foreman_task_add_comment", :ok)

      {:ok,
       %__MODULE__.TaskAddCommentResult{
         run_id: run_id,
         task_id: task_id,
         provider: provider_name(provider_module),
         status: "comment_added"
       }}
    else
      {:error, %ToolError{}} = error ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_task_add_comment", :error)
        error

      {:error, %ProviderError{} = provider_error} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_task_add_comment", :error)
        {:error, provider_comment_tool_error(provider_error)}
    end
  end

  defp reject_unknown_task_add_comment_args(args) do
    unknown = Map.keys(args) -- @task_add_comment_args

    if unknown == [] do
      :ok
    else
      {:error,
       %ToolError{
         code: "INVALID_PARAMS",
         message: "Unknown arguments: " <> Enum.map_join(unknown, ", ", &to_string/1)
       }}
    end
  end

  defp required_bounded(args, key, max_length) do
    with {:ok, value} <- required_nonblank(args, key) do
      if String.length(value) <= max_length do
        {:ok, value}
      else
        {:error,
         %ToolError{
           code: "INVALID_PARAMS",
           message: "#{key} must be at most #{max_length} UTF-8 characters"
         }}
      end
    end
  end

  defp compose_task_comment_body(workflow_name, phase_name, description) do
    body = """
    Work Log
    Workflow: #{workflow_name}
    Phase: #{phase_name}

    Work performed:
    #{description}
    """

    if String.length(body) <= @task_add_comment_body_max do
      {:ok, body}
    else
      {:error,
       %ToolError{
         code: "INVALID_PARAMS",
         message:
           "composed Work Log body must be at most #{@task_add_comment_body_max} UTF-8 characters"
       }}
    end
  end

  defp fetch_comment_run(run_id) do
    case ProjectionStore.run(run_id) do
      nil -> {:error, %ToolError{code: "NOT_FOUND", message: "Run not found"}}
      run -> {:ok, run}
    end
  end

  defp fetch_comment_task_id(run) do
    case Map.fetch(run, :task_id) do
      {:ok, task_id} when is_binary(task_id) and task_id != "" -> {:ok, task_id}
      {:ok, _} -> {:error, %ToolError{code: "INVALID_STATE", message: "Run task_id is malformed"}}
      :error -> {:error, %ToolError{code: "INVALID_STATE", message: "Run is not bound to a task"}}
    end
  end

  defp fetch_comment_task(task_id) do
    case ProjectionStore.task_projection(task_id) do
      nil -> {:error, %ToolError{code: "NOT_FOUND", message: "Task not found"}}
      task -> {:ok, task}
    end
  end

  defp fetch_comment_external_id(task) do
    case Map.fetch(task, :external_id) do
      {:ok, external_id} when is_binary(external_id) and external_id != "" ->
        {:ok, external_id}

      {:ok, _} ->
        {:error, %ToolError{code: "INVALID_STATE", message: "Task external_id is malformed"}}

      :error ->
        {:error, %ToolError{code: "INVALID_STATE", message: "Task has no provider issue id"}}
    end
  end

  defp fetch_comment_project_id(run) do
    case Map.fetch(run, :project_id) do
      {:ok, project_id} when is_binary(project_id) and project_id != "" ->
        {:ok, project_id}

      {:ok, _} ->
        {:error, %ToolError{code: "INVALID_STATE", message: "Run project_id is malformed"}}

      :error ->
        {:error, %ToolError{code: "INVALID_STATE", message: "Run has no project id"}}
    end
  end

  defp fetch_comment_provider_config(project_id) do
    case TaskProviderRegistry.project_config(project_id) do
      {:ok, %{provider_module: provider_module, config: config}} ->
        {:ok, provider_module, config}

      {:error, reason} ->
        {:error,
         %ToolError{
           code: "PROVIDER_CONFIG_ERROR",
           message: "Task provider config unavailable: #{inspect(reason)}"
         }}
    end
  end

  defp provider_name(provider_module) do
    if function_exported?(provider_module, :name, 0) do
      provider_module.name() |> to_string()
    else
      inspect(provider_module)
    end
  end

  defp provider_comment_tool_error(%ProviderError{} = provider_error) do
    %ToolError{code: provider_error.code, message: provider_error.message}
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
      latest_stall: Map.get(run, :latest_stall),
      provider_session_id: Map.get(run, :provider_session_id),
      provider_sessions: Map.get(run, :provider_sessions) || [],
      usage: Map.get(run, :usage)
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

  # Explicit "operator_pause" default (rather than omitting the key like
  # `tool_foreman_run_cancel/1` does for `reason`): the `run.pause`
  # command clause itself defaults an absent `reason` to "crash_loop"
  # for its other caller (`Overwatch.CrashLoopDetector`), which would
  # mislabel an operator-issued pause.
  defp tool_foreman_run_pause(%{run_id: run_id} = args) do
    start_us = System.monotonic_time(:microsecond)
    command_id = "mcp:#{run_id}:#{System.unique_integer([:positive])}"
    reason = Map.get(args, :reason)

    payload =
      if is_binary(reason) and reason != "" do
        %{run_id: run_id, reason: reason}
      else
        %{run_id: run_id, reason: "operator_pause"}
      end

    envelope = %{
      type: "run.pause",
      command_id: command_id,
      aggregate_id: "run:#{run_id}",
      payload: payload
    }

    case CommandGateway.dispatch_operator(envelope) do
      {:ok, result} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_run_pause", :ok)
        {:ok, result}

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_run_pause", :error)
        {:error, %ToolError{code: "DOMAIN_ERROR", message: inspect(reason)}}
    end
  end

  defp tool_foreman_run_resume(%{run_id: run_id}) do
    start_us = System.monotonic_time(:microsecond)
    command_id = "mcp:#{run_id}:#{System.unique_integer([:positive])}"

    envelope = %{
      type: "run.resume",
      command_id: command_id,
      aggregate_id: "run:#{run_id}",
      payload: %{run_id: run_id}
    }

    case CommandGateway.dispatch_operator(envelope) do
      {:ok, result} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_run_resume", :ok)
        {:ok, result}

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - start_us
        Telemetry.mcp_tool_call(duration_us, "foreman_run_resume", :error)
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
