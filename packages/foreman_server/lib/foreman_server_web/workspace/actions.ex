defmodule ForemanServerWeb.Workspace.Actions do
  @moduledoc """
  The workspace's mutations. Every function calls an EXISTING operator path:
  `ForemanServer.Threads.Actions` (stop, steer, the same functions the HTTP
  thread routes call), `ForemanServer.CoordinatorAPI` (the coordinator message
  and restart entry the HTTP routes use), `ForemanServer.Library` (the library's
  single entry point: the HTTP routes, MCP and the CLI call the same `add/4` and
  `remove/3`) and `CommandGateway.dispatch_operator/1` with an
  operator-allowlisted command type (`thread.resolve`, `thread.reopen`,
  `run.pause`, `run.resume`, `task.approve`, `task.update`, `project.*`,
  `schedule.*`). The workspace adds no mutation path and no merge/approve-PR
  control.

  ## Idempotency

  Every dispatching function takes an `intent`: an opaque string the LiveView
  owns that is stable for one user intent (the view's session nonce plus a
  counter that only moves when the projection changed). The command id is
  derived from `type`, the target and the `intent`, so a double click or a
  resent event carries the SAME id and `CommandRouter` deduplicates it, while a
  later, genuinely new action (after the projection moved on) gets a new id.

  ## Errors

  Thread, task and schedule ids come from the browser, so each action first
  checks the target exists and belongs to the workspace's project. Results are
  `{:ok, message}` / `{:error, message}` with a plain-text message (HEEx escapes
  it); not-found, wrong-project and unexpected failures have different messages,
  and unexpected ones are logged.
  """

  require Logger

  alias ForemanServer.{CommandGateway, CoordinatorAPI, Library, ProjectionStore, Threads}
  alias ForemanServer.Aggregates.Project.Environment
  alias ForemanServer.Aggregates.ToolCall
  alias ForemanServer.Library.Error, as: LibraryError
  alias ForemanServer.Library.Ingest
  alias ForemanServer.Overview.{PrActions, Signals}
  alias ForemanServer.Threads.{Actions, Thread}

  @type result :: {:ok, String.t()} | {:error, String.t()}
  @type intent :: String.t()
  @actor "dashboard"
  @operator %{kind: :operator, ref: @actor}

  @doc "Stops a thread of the project (confirmation is the caller's job)."
  @spec stop_thread(String.t(), String.t(), intent()) :: result()
  def stop_thread(project_id, thread_id, intent) do
    with {:ok, _thread} <- own_thread(project_id, thread_id) do
      case Actions.stop(thread_id, "operator_dashboard", idempotency_key: "dashboard:" <> intent) do
        {:ok, :stopping} -> {:ok, "Stopping #{thread_id}."}
        {:error, reason} -> {:error, "Could not stop: #{describe(reason)}"}
      end
    end
  end

  @doc "Steers a thread with an operator message; `message_id` makes a resend a no-op."
  @spec steer_thread(String.t(), String.t(), term(), String.t()) :: result()
  def steer_thread(project_id, thread_id, text, message_id) do
    with {:ok, _thread} <- own_thread(project_id, thread_id) do
      case Actions.steer(thread_id, text, message_id: message_id) do
        {:ok, _} -> {:ok, "Message sent to #{thread_id}."}
        {:error, reason} -> {:error, "Could not send: #{describe(reason)}"}
      end
    end
  end

  @doc "Resolves or reopens a thread (`:resolve | :reopen`)."
  @spec set_resolved(String.t(), String.t(), :resolve | :reopen, intent()) :: result()
  def set_resolved(project_id, thread_id, which, intent) do
    with {:ok, _thread} <- own_thread(project_id, thread_id) do
      {type, who} =
        case which do
          :resolve -> {"thread.resolve", :resolved_by}
          :reopen -> {"thread.reopen", :reopened_by}
        end

      payload =
        Map.put(%{thread_id: thread_id, project_id: project_id, source: @actor}, who, @actor)

      dispatch(type, "thread:" <> thread_id, payload, intent, "#{type} #{thread_id}")
    end
  end

  @doc "Pauses or resumes the newest run of a workflow thread (`:pause | :resume`)."
  @spec run_control(String.t(), String.t(), :pause | :resume, intent()) :: result()
  def run_control(project_id, thread_id, which, intent) do
    case own_thread(project_id, thread_id) do
      {:ok, %Thread{run_ids: [run_id | _]}} ->
        type = if which == :pause, do: "run.pause", else: "run.resume"

        dispatch(
          type,
          "run:" <> run_id,
          %{run_id: run_id, reason: "operator_dashboard", actor: "operator_dashboard"},
          intent,
          "#{type} #{run_id}"
        )

      {:ok, %Thread{}} ->
        {:error, "This thread has no run to control."}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Decides one pending tool-call request of a project's thread (`:approve | :deny`),
  the operator's `tool.approve` / `tool.deny` command (the same one the CLI's
  `foreman approvals approve|deny` and `POST /api/commands` send). For an in-flight
  request the decision wakes the agent's blocked call (`Approvals.Inflight`); for a
  post-hoc request it resumes the paused run. The request must be pending and belong
  to the thread; nothing here touches the merge gate.
  """
  @spec decide_approval(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          :approve | :deny,
          intent()
        ) :: result()
  def decide_approval(project_id, thread_id, run_id, tool_call_id, decision, intent)
      when decision in [:approve, :deny] do
    with {:ok, thread} <- own_thread(project_id, thread_id),
         :ok <- pending_approval_of(thread, run_id, tool_call_id) do
      type = if decision == :approve, do: "tool.approve", else: "tool.deny"

      dispatch(
        type,
        ToolCall.stream_id(run_id, tool_call_id),
        %{run_id: run_id, tool_call_id: tool_call_id, decided_by: @actor},
        intent,
        "#{type} #{run_id}/#{tool_call_id}"
      )
    end
  end

  defp pending_approval_of(thread, run_id, tool_call_id) do
    if Enum.any?(
         Signals.pending_approvals(thread),
         &(&1.run_id == run_id and &1.tool_call_id == tool_call_id)
       ) do
      :ok
    else
      {:error, "That request is no longer pending for this thread."}
    end
  end

  @pr_kinds Map.new(PrActions.kinds(), &{Atom.to_string(&1), &1})

  @doc """
  Starts a PR action on the thread's newest run: `fix_ci`, `address_comments`,
  `resolve_conflicts` (E9 fix threads) or `create_pr`. It dispatches the same
  operator command the CLI, `/api/commands` and MCP `foreman_pr_fix` use
  (`PrActions.command_type/1`); `CommandGateway` performs the real PR creation
  for `run.pr.create`, and the Run aggregate refuses what the watch state cannot
  support (not watched, fix in flight, exhausted). `pr_url` (optional) must be
  one of the run's watched PRs. There is no merge or approve action.
  """
  @spec pr_action(String.t(), String.t(), String.t(), String.t() | nil, intent()) :: result()
  def pr_action(project_id, thread_id, kind, pr_url, intent) do
    with {:ok, kind} <- pr_kind(kind),
         {:ok, %Thread{door: :workflow, run_ids: [run_id | _]}} <-
           own_thread_with_run(project_id, thread_id),
         :ok <- watched_pr(run_id, pr_url) do
      type = PrActions.command_type(kind)

      payload =
        %{run_id: run_id, trigger: "operator", requested_by: @actor}
        |> put_pr_url(pr_url)

      dispatch(type, "run:" <> run_id, payload, intent, "#{type} #{run_id}")
    end
  end

  defp pr_kind(kind) do
    case Map.fetch(@pr_kinds, kind) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, "Unknown PR action."}
    end
  end

  defp own_thread_with_run(project_id, thread_id) do
    case own_thread(project_id, thread_id) do
      {:ok, %Thread{door: :workflow, run_ids: [_ | _]} = thread} -> {:ok, thread}
      {:ok, %Thread{}} -> {:error, "This thread has no run to open a pull request from."}
      {:error, _} = error -> error
    end
  end

  defp watched_pr(_run_id, nil), do: :ok
  defp watched_pr(_run_id, ""), do: :ok

  defp watched_pr(run_id, pr_url) do
    if Enum.any?(ProjectionStore.pr_watch(run_id), &(&1.pr_url == pr_url)),
      do: :ok,
      else: {:error, "That pull request is not watched for this thread."}
  end

  defp put_pr_url(payload, url) when url in [nil, ""], do: payload
  defp put_pr_url(payload, url), do: Map.put(payload, :pr_url, url)

  @doc "Posts an operator message to the project coordinator (the HTTP POST's entry)."
  @spec post_coordinator_message(String.t(), String.t(), String.t()) :: result()
  def post_coordinator_message(project_id, text, message_id) do
    case CoordinatorAPI.post_message(project_id, %{
           text: text,
           source: "dashboard",
           message_id: message_id
         }) do
      {:ok, _} -> {:ok, "Sent."}
      {:error, reason} -> {:error, "Could not send: #{describe(reason)}"}
    end
  end

  @doc "Restarts the project coordinator."
  @spec restart_coordinator(String.t()) :: result()
  def restart_coordinator(project_id) do
    case CoordinatorAPI.restart(project_id, "dashboard") do
      {:ok, _} -> {:ok, "Coordinator restart requested."}
      {:error, reason} -> {:error, "Could not restart: #{describe(reason)}"}
    end
  end

  @doc "Approves (starts) a task the coordinator proposed for this project."
  @spec start_proposed(String.t(), String.t(), intent()) :: result()
  def start_proposed(project_id, task_id, intent) do
    with :ok <- proposed?(project_id, task_id) do
      dispatch(
        "task.approve",
        "task:" <> task_id,
        %{task_id: task_id, approved_by: @actor},
        intent,
        "task.approve #{task_id}"
      )
    end
  end

  @doc """
  Declines a task the coordinator proposed for this project: the operator's
  `task.update` to `closed` (the command `POST /api/commands` and the MCP
  `foreman_task_update` carry; there is no separate decline command). A closed
  task can no longer be approved, because `task.approve` needs an `open` task.
  The guards are `start_proposed/3`'s: the task must be a still-open proposal of
  THIS project.
  """
  @spec decline_proposed(String.t(), String.t(), intent()) :: result()
  def decline_proposed(project_id, task_id, intent) do
    with :ok <- proposed?(project_id, task_id) do
      dispatch(
        "task.update",
        "task:" <> task_id,
        %{task_id: task_id, status: "closed"},
        intent,
        "task.update #{task_id}"
      )
    end
  end

  @doc "Pauses, resumes or deletes one of the project's schedules."
  @spec schedule_control(String.t(), String.t(), :pause | :resume | :delete, intent()) :: result()
  def schedule_control(project_id, schedule_id, which, intent) do
    if Enum.any?(ProjectionStore.schedules(project_id), &(&1.schedule_id == schedule_id)) do
      type = "schedule." <> Atom.to_string(which)

      dispatch(
        type,
        ForemanServer.Aggregates.Schedule.stream_id(project_id, schedule_id),
        %{project_id: project_id, schedule_id: schedule_id},
        intent,
        "#{type} #{schedule_id}"
      )
    else
      {:error, "Schedule not found in this project."}
    end
  end

  @doc "Dispatches a project lifecycle command: `project.pause|resume|archive|reactivate`."
  @spec project_lifecycle(String.t(), :pause | :resume | :archive | :reactivate, intent()) ::
          result()
  def project_lifecycle(project_id, which, intent) do
    type = "project." <> Atom.to_string(which)

    dispatch(
      type,
      "project:" <> project_id,
      %{project_id: project_id, reason: "operator_dashboard"},
      intent,
      type
    )
  end

  @doc """
  Adds `files` (`%{relative_path:, source_path:}`: the uploaded temp files) to the
  project's library as ONE entry through `Library.add/4`, the call behind
  `POST /api/projects/:id/library` and `foreman project library add`. The library
  therefore applies the same name, path, count (`max_files_per_add`) and size
  (`max_file_bytes`) rules, whatever the browser claimed. A blank `name` lets the
  library derive one.
  """
  @spec library_add(String.t(), [Ingest.file_source()], String.t()) :: result()
  def library_add(project_id, files, name) when is_binary(name) do
    case Library.add(project_id, {:files, files}, %{name: blank_to_nil(name)}, @operator) do
      {:ok, %{entry: entry}} ->
        {:ok, "Added #{entry.name} to the library (#{files_label(entry.file_count)})."}

      {:error, %LibraryError{} = error} ->
        library_failed("add", error)
    end
  end

  @doc "Removes one library entry of the project (confirmation is the caller's job)."
  @spec library_remove(String.t(), String.t()) :: result()
  def library_remove(project_id, entry_id) do
    case Library.remove(project_id, entry_id, @operator) do
      {:ok, entry} ->
        {:ok, "Removed #{entry.name} from the library."}

      {:error, %LibraryError{code: :not_found}} ->
        {:error, "That library entry no longer exists."}

      {:error, %LibraryError{} = error} ->
        library_failed("remove", error)
    end
  end

  @doc """
  Writes project settings through `project.update`. `settings` holds ONLY the
  settings the operator changed (key => value; `nil` clears that setting), so a
  setting changed elsewhere since the page loaded is never overwritten. Returns
  the aggregate's distinct error tuple untouched so the form can show it against
  its field. The command id also hashes the payload: two different saves in one
  intent window are different actions.
  """
  @spec update_settings(String.t(), map(), intent()) :: :ok | {:error, term()}
  def update_settings(project_id, settings, intent),
    do:
      dispatch_project(
        "project.update",
        project_id,
        Map.put(settings, :project_id, project_id),
        intent
      )

  @doc """
  Installs (`script` a string) or clears (`nil` or blank) the project's setup
  script through `project.environment.set`, the operator-only command behind
  `PUT /api/projects/:id/environment` and `foreman project setup-script`: the
  script is arbitrary code that runs on the server host, so `project.update`
  refuses it. The payload names only `setup_script`; the variables and the
  network policy keep their stored values. Returns the aggregate's error tuple
  untouched (`{:setup_script_too_long, bytes}`, `{:setup_script_invalid, _}`).
  """
  @spec update_setup_script(String.t(), String.t() | nil, intent()) :: :ok | {:error, term()}
  def update_setup_script(project_id, script, intent),
    do:
      dispatch_project(
        "project.environment.set",
        project_id,
        %{project_id: project_id, setup_script: script},
        intent
      )

  @typedoc "A repository to attach: id, absolute path on the server host, optional default branch."
  @type repository :: %{id: String.t(), path: String.t(), default_branch: String.t() | nil}

  @doc """
  Attaches an extra repository through `project.repo.add`, the operator command
  behind `foreman project repo add`: `CommandGateway` canonicalises the path and
  checks it is a git work tree before the aggregate checks the id and uniqueness.
  Returns the typed error tuple untouched so the form can show it at its field.
  """
  @spec add_repository(String.t(), repository(), intent()) :: :ok | {:error, term()}
  def add_repository(project_id, %{id: id, path: path, default_branch: branch}, intent) do
    payload =
      %{project_id: project_id, repo_id: id, path: path, added_by: @actor}
      |> put_default_branch(branch)

    dispatch_project("project.repo.add", project_id, payload, intent)
  end

  @doc "Detaches an extra repository (`project.repo.remove`; the primary one is refused)."
  @spec remove_repository(String.t(), String.t(), intent()) :: :ok | {:error, term()}
  def remove_repository(project_id, repo_id, intent) do
    dispatch_project(
      "project.repo.remove",
      project_id,
      %{project_id: project_id, repo_id: repo_id, removed_by: @actor},
      intent
    )
  end

  # -- helpers ---------------------------------------------------------------

  defp own_thread(project_id, thread_id) do
    case Threads.get(thread_id) do
      {:ok, %Thread{project_id: ^project_id} = thread} ->
        {:ok, thread}

      {:ok, %Thread{}} ->
        {:error, "That thread belongs to another project."}

      {:error, :thread_not_found} ->
        {:error, "Thread not found."}
    end
  end

  defp proposed?(project_id, task_id) do
    with {:ok, conv} <- ProjectionStore.coordinator_state(project_id),
         {:ok, task} <- proposal_task(task_id) do
      cond do
        task_id not in proposed_task_ids(conv) ->
          {:error, "The coordinator did not propose that task."}

        Map.get(task, :project_id) != project_id ->
          {:error, "That task belongs to another project."}

        Map.get(task, :status) != "open" ->
          {:error, "That task is no longer open (#{Map.get(task, :status)})."}

        true ->
          :ok
      end
    else
      {:error, :project_not_found} -> {:error, "Project not found."}
      {:error, :task_not_found} -> {:error, "Task not found."}
    end
  end

  defp proposal_task(task_id) do
    case ProjectionStore.task_projection(task_id) do
      %{} = task -> {:ok, task}
      nil -> {:error, :task_not_found}
    end
  end

  @doc "Task ids of every still-recorded `proposed` coordinator action."
  @spec proposed_task_ids(map()) :: [String.t()]
  def proposed_task_ids(conv) do
    for {_id, %{status: "proposed", result_ref: %{} = ref}} <- conv.actions,
        id <- Map.get(ref, "task_ids", []),
        is_binary(id),
        do: id
  end

  defp dispatch(type, aggregate_id, payload, intent, label) do
    envelope = %{
      type: type,
      command_id: command_id(type, aggregate_id, intent),
      aggregate_id: aggregate_id,
      payload: payload
    }

    case safe_dispatch(envelope) do
      {:ok, _} -> {:ok, "Done: #{label}."}
      {:error, reason} -> failed(label, reason)
      {:error, reason, detail} -> failed(label, {reason, detail})
    end
  end

  defp failed(label, reason) do
    Logger.warning("workspace action #{label} failed: #{inspect(reason, limit: 8)}")
    {:error, "#{label} failed: #{describe(reason)}"}
  end

  defp safe_dispatch(envelope) do
    CommandGateway.dispatch_operator(envelope)
  catch
    :exit, {:timeout, {GenServer, :call, _}} -> {:error, :dispatch_timeout}
  end

  defp command_id(type, key, intent), do: "dashboard:#{type}:#{key}:#{intent}"

  # `:ok | {:error, term()}` for the forms that show the aggregate's typed error at
  # their own field. The command id hashes the payload too, so two different
  # submissions inside one intent window (two repositories added back to back) are
  # different actions while a double click of one is the same.
  defp dispatch_project(type, project_id, payload, intent) do
    envelope = %{
      type: type,
      command_id: command_id(type, project_id, "#{intent}-#{:erlang.phash2(payload)}"),
      aggregate_id: "project:" <> project_id,
      payload: payload
    }

    case safe_dispatch(envelope) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      {:error, reason, detail} -> {:error, {reason, detail}}
    end
  end

  defp put_default_branch(payload, nil), do: payload
  defp put_default_branch(payload, branch), do: Map.put(payload, :default_branch, branch)

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp files_label(1), do: "1 file"
  defp files_label(count), do: "#{count} files"

  # Only a failure of the disk or of the audit command is worth a log line: the
  # rest (a taken name, a path or size rule) is the operator's input, not a fault.
  defp library_failed(verb, %LibraryError{code: code, message: message} = error) do
    if code in [:write_failed, :dispatch_failed],
      do: Logger.warning("workspace library #{verb} failed: #{inspect(error, limit: 8)}")

    {:error, "Could not #{verb}: #{message}"}
  end

  @doc "Plain-text rendering of an error term (never raises)."
  @spec describe(term()) :: String.t()
  def describe({:message_too_large, bytes, max}),
    do: "message too large (#{bytes} > #{max} bytes)"

  def describe({:invalid_text, :blank}), do: "the message is empty"
  def describe({:invalid_text, :too_long}), do: "the message is too long"
  def describe(:rate_limited), do: "rate limited"
  def describe(:no_head_branch), do: "the run has no pushed branch to open a pull request from"
  def describe(:no_base_branch), do: "the run has no base branch"
  def describe(:no_commits_to_propose), do: "the branch has no commits to propose"
  def describe({:pr_already_associated, url}), do: "a pull request already exists (#{url})"
  def describe({:project_unresolved, id}), do: "project #{id} is not registered"
  def describe({:fix_in_flight, _url}), do: "a fix is already running for that pull request"
  def describe({:pr_not_open, status}), do: "the pull request is #{status}"

  def describe({:fix_attempts_exhausted, kind, cap}),
    do: "#{kind} fix attempts reached the cap of #{cap}"

  def describe({:fix_no_progress, kind}), do: "the last #{kind} fix changed nothing on this head"
  def describe({:fix_cooling_down, _until}), do: "a fix finished too recently"
  def describe({:fix_exhausted, kind}), do: "#{kind} fixes are exhausted for this head"
  def describe({:pr_url_required, _run}), do: "name the pull request (the run watches several)"
  def describe({:pr_not_watched, _}), do: "no pull request is being watched"
  def describe({:project_archived, id}), do: "project #{id} is archived"
  def describe({:not_found, :project, id}), do: "project #{id} is not registered"
  def describe(:dispatch_timeout), do: "the server did not answer in time"

  def describe({:setup_script_too_long, bytes}),
    do: "the script is #{bytes} bytes; at most #{Environment.max_script_bytes()} are accepted"

  def describe({:setup_script_invalid, :nul_byte}), do: "the script contains a NUL byte"
  def describe({:setup_script_invalid, _}), do: "the script must be text"

  # A script-only save still re-checks the stored variables (a legacy flat `env` is
  # ported into the record), so a bad stored variable can refuse it.
  def describe({:secret_in_vars, name}),
    do:
      "the stored variable #{name} looks like a secret; move it to a project secret " <>
        "(foreman project secret set) and remove it from the environment"

  def describe({:reserved_env_name, name}),
    do: "the stored variable #{name} uses the reserved FOREMAN_ prefix"

  def describe({:invalid_repo_id, _}),
    do: "the id must be 1-32 lowercase letters, digits or dashes and not start with a dash"

  def describe({:repo_id_taken, id}), do: "the id #{id} is already used in this project"
  def describe({:repo_path_not_absolute, _}), do: "the path must be absolute"
  def describe({:repo_path_not_found, path}), do: "#{path} does not exist on the server host"
  def describe({:repo_not_git_work_tree, path}), do: "#{path} is not the root of a git work tree"
  def describe({:repo_path_duplicate, path}), do: "#{path} is already attached to this project"
  def describe({:repo_remote_duplicate, id}), do: "that remote is already attached as #{id}"
  def describe({:invalid_default_branch, _}), do: "the default branch must be a branch name"
  def describe(:primary_repo_not_removable), do: "the primary repository cannot be removed"
  def describe({:repo_not_found, id}), do: "repository #{id} is not attached to this project"

  def describe(:project_has_active_runs),
    do: "the project has active runs; try again when they have finished"

  def describe(reason), do: inspect(reason, limit: 8, printable_limit: 200)
end
