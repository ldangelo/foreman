defmodule ForemanServerWeb.Workspace.Actions do
  @moduledoc """
  The workspace's mutations. Every function calls an EXISTING operator path:
  `ForemanServer.Threads.Actions` (stop, steer, the same functions the HTTP
  thread routes call), `ForemanServer.CoordinatorAPI` (the coordinator message
  and restart entry the HTTP routes use), and `CommandGateway.dispatch_operator/1`
  with an operator-allowlisted command type (`thread.resolve`, `thread.reopen`,
  `run.pause`, `run.resume`, `task.approve`, `project.*`, `schedule.*`). The
  workspace adds no mutation path and no merge/approve-PR control.

  Thread, task and schedule ids come from the browser, so each action first
  checks the target belongs to the workspace's project. Results are
  `{:ok, message}` / `{:error, message}` with a plain-text message (HEEx escapes it).
  """

  alias ForemanServer.{CommandGateway, CoordinatorAPI, ProjectionStore, Threads}
  alias ForemanServer.Threads.{Actions, Thread}

  @type result :: {:ok, String.t()} | {:error, String.t()}
  @actor "dashboard"

  @doc "Stops a thread of the project (confirmation is the caller's job)."
  @spec stop_thread(String.t(), String.t()) :: result()
  def stop_thread(project_id, thread_id) do
    with {:ok, _thread} <- own_thread(project_id, thread_id) do
      case Actions.stop(thread_id, "operator_dashboard") do
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
  @spec set_resolved(String.t(), String.t(), :resolve | :reopen) :: result()
  def set_resolved(project_id, thread_id, which) do
    with {:ok, _thread} <- own_thread(project_id, thread_id) do
      {type, who} =
        case which do
          :resolve -> {"thread.resolve", :resolved_by}
          :reopen -> {"thread.reopen", :reopened_by}
        end

      payload =
        Map.put(%{thread_id: thread_id, project_id: project_id, source: @actor}, who, @actor)

      dispatch(type, "thread:" <> thread_id, payload, "#{type} #{thread_id}")
    end
  end

  @doc "Pauses or resumes the newest run of a workflow thread (`:pause | :resume`)."
  @spec run_control(String.t(), String.t(), :pause | :resume) :: result()
  def run_control(project_id, thread_id, which) do
    with {:ok, %Thread{run_ids: [run_id | _]}} <- own_thread(project_id, thread_id) do
      type = if which == :pause, do: "run.pause", else: "run.resume"

      dispatch(
        type,
        "run:" <> run_id,
        %{run_id: run_id, reason: "operator_dashboard", actor: "operator_dashboard"},
        "#{type} #{run_id}"
      )
    else
      {:ok, %Thread{}} -> {:error, "This thread has no run to control."}
      {:error, _} = error -> error
    end
  end

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
  @spec start_proposed(String.t(), String.t()) :: result()
  def start_proposed(project_id, task_id) do
    with :ok <- proposed?(project_id, task_id) do
      dispatch(
        "task.approve",
        "task:" <> task_id,
        %{task_id: task_id, approved_by: @actor},
        "task.approve #{task_id}"
      )
    end
  end

  @doc "Pauses, resumes or deletes one of the project's schedules."
  @spec schedule_control(String.t(), String.t(), :pause | :resume | :delete) :: result()
  def schedule_control(project_id, schedule_id, which) do
    if Enum.any?(ProjectionStore.schedules(project_id), &(&1.schedule_id == schedule_id)) do
      type = "schedule." <> Atom.to_string(which)

      dispatch(
        type,
        ForemanServer.Aggregates.Schedule.stream_id(project_id, schedule_id),
        %{project_id: project_id, schedule_id: schedule_id},
        "#{type} #{schedule_id}"
      )
    else
      {:error, "Unknown schedule."}
    end
  end

  @doc "Dispatches a project lifecycle command: `project.pause|resume|archive|reactivate`."
  @spec project_lifecycle(String.t(), :pause | :resume | :archive | :reactivate) :: result()
  def project_lifecycle(project_id, which) do
    type = "project." <> Atom.to_string(which)

    dispatch(
      type,
      "project:" <> project_id,
      %{project_id: project_id, reason: "operator_dashboard"},
      type
    )
  end

  @doc """
  Writes project settings through `project.update`. `settings` is a map of
  setting key => value; a `nil` value clears the setting. Returns the aggregate's
  distinct error tuple untouched so the form can show it against its field.
  """
  @spec update_settings(String.t(), map()) :: :ok | {:error, term()}
  def update_settings(project_id, settings) do
    envelope = %{
      type: "project.update",
      command_id: command_id("project.update", project_id),
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
      {:ok, %Thread{project_id: ^project_id} = thread} -> {:ok, thread}
      _ -> {:error, "Unknown thread."}
    end
  end

  defp proposed?(project_id, task_id) do
    with {:ok, conv} <- ProjectionStore.coordinator_state(project_id),
         true <- task_id in proposed_task_ids(conv),
         %{project_id: ^project_id, status: "open"} <- ProjectionStore.task_projection(task_id) do
      :ok
    else
      _ -> {:error, "That task is not an open proposal of this project."}
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

  defp dispatch(type, aggregate_id, payload, label) do
    envelope = %{
      type: type,
      command_id: command_id(type, aggregate_id),
      aggregate_id: aggregate_id,
      payload: payload
    }

    case safe_dispatch(envelope) do
      {:ok, _} -> {:ok, "Done: #{label}."}
      {:error, reason} -> {:error, "#{label} failed: #{describe(reason)}"}
      {:error, reason, detail} -> {:error, "#{label} failed: #{describe({reason, detail})}"}
    end
  end

  defp safe_dispatch(envelope) do
    CommandGateway.dispatch_operator(envelope)
  catch
    :exit, {:timeout, {GenServer, :call, _}} -> {:error, :dispatch_timeout}
  end

  defp command_id(type, key),
    do: "dashboard:#{type}:#{key}:#{System.unique_integer([:positive, :monotonic])}"

  @doc "Plain-text rendering of an error term (never raises)."
  @spec describe(term()) :: String.t()
  def describe({:message_too_large, bytes, max}),
    do: "message too large (#{bytes} > #{max} bytes)"

  def describe({:invalid_text, :blank}), do: "the message is empty"
  def describe({:invalid_text, :too_long}), do: "the message is too long"
  def describe(:rate_limited), do: "rate limited"
  def describe(reason), do: inspect(reason, limit: 8, printable_limit: 200)
end
