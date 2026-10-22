defmodule ForemanServerWeb.Workspace.Actions do
  @moduledoc """
  The workspace's mutations. Every function calls an EXISTING operator path:
  `ForemanServer.Threads.Actions` (stop, steer, the same functions the HTTP
  thread routes call), `ForemanServer.CoordinatorAPI` (the coordinator message
  and restart entry the HTTP routes use), and `CommandGateway.dispatch_operator/1`
  with an operator-allowlisted command type (`thread.resolve`, `thread.reopen`,
  `run.pause`, `run.resume`, `task.approve`, `project.*`, `schedule.*`). The
  workspace adds no mutation path and no merge/approve-PR control.

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

  alias ForemanServer.{CommandGateway, CoordinatorAPI, ProjectionStore, Threads}
  alias ForemanServer.Overview.PrActions
  alias ForemanServer.Threads.{Actions, Thread}

  @type result :: {:ok, String.t()} | {:error, String.t()}
  @type intent :: String.t()
  @actor "dashboard"

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
  Writes project settings through `project.update`. `settings` holds ONLY the
  settings the operator changed (key => value; `nil` clears that setting), so a
  setting changed elsewhere since the page loaded is never overwritten. Returns
  the aggregate's distinct error tuple untouched so the form can show it against
  its field. The command id also hashes the changed settings: two different saves
  in one intent window are different actions.
  """
  @spec update_settings(String.t(), map(), intent()) :: :ok | {:error, term()}
  def update_settings(project_id, settings, intent) do
    envelope = %{
      type: "project.update",
      command_id:
        command_id("project.update", project_id, "#{intent}-#{:erlang.phash2(settings)}"),
      aggregate_id: "project:" <> project_id,
      payload: Map.put(settings, :project_id, project_id)
    }

    case safe_dispatch(envelope) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      {:error, reason, detail} -> {:error, {reason, detail}}
    end
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
  def describe(reason), do: inspect(reason, limit: 8, printable_limit: 200)
end
