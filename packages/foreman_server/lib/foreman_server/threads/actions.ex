defmodule ForemanServer.Threads.Actions do
  @moduledoc """
  Door-agnostic operator actions on a thread (see `ForemanServer.Threads.Thread`).

  Each action resolves the thread through `ForemanServer.Threads.get/1` and
  routes to the command or control path the thread's door already owns; no new
  aggregate command is introduced here.

    * `stop/3` - workflow door: `run.cancel` through
      `CommandGateway.dispatch_operator/1`. Jobsite door: `Jobsite.cancel/2`
      when an executor is alive (it records the intent and the executor emits
      `JobsiteCancelled`); a paused jobsite has no executor, so the existing
      `jobsite.cancel` command is dispatched directly.
    * `steer/3` - workflow door: operator `run.steer` (queue, pause, resume with
      the message in the next prompt). Jobsite door: `Jobsite.steer/3`.
    * `rereview/1` - re-run an `undetermined` review of the thread's run or jobsite
      through `ForemanServer.Review.Analyzer.rerun/2`; the verdict it records
      supersedes the undetermined one.
  """

  alias ForemanServer.CommandGateway
  alias ForemanServer.Jobsite
  alias ForemanServer.Review.Analyzer
  alias ForemanServer.Threads
  alias ForemanServer.Threads.Thread

  @default_stop_reason "operator_stop"

  @stoppable_run_statuses ~w(awaiting_worker in_progress paused blocked stuck needs_recovery)
  @stoppable_jobsite_statuses ~w(starting running paused)

  @type stop_error ::
          :thread_not_found
          | {:not_stoppable, String.t() | nil}
          | {:no_executor, String.t() | nil}
          | {:cancel_failed, term()}

  @doc """
  Stop a thread. `opts`: `:idempotency_key` (becomes the `run.cancel`
  `command_id`; default a fresh unique id, so two distinct stops never
  deduplicate into one).

  Returns `{:ok, :stopping}`, `{:error, :thread_not_found}`,
  `{:error, {:not_stoppable, status}}` for a terminal thread (nothing is
  dispatched), `{:error, {:no_executor, status}}` for a starting/running
  jobsite whose executor is gone, or `{:error, {:cancel_failed, reason}}` when
  the underlying cancel is rejected.
  """
  @spec stop(String.t(), String.t() | nil, keyword()) :: {:ok, :stopping} | {:error, stop_error()}
  def stop(thread_id, reason \\ nil, opts \\ []) when is_binary(thread_id) and is_list(opts) do
    reason = normalize_reason(reason)

    with {:ok, %Thread{} = thread} <- Threads.get(thread_id) do
      do_stop(thread, reason, opts)
    end
  end

  defp do_stop(%Thread{door: :workflow, id: "run:" <> run_id, status: status}, reason, opts)
       when status in @stoppable_run_statuses do
    envelope = %{
      type: "run.cancel",
      command_id: Keyword.get_lazy(opts, :idempotency_key, &fresh_command_id/0),
      aggregate_id: "run:" <> run_id,
      payload: %{run_id: run_id, reason: reason}
    }

    case CommandGateway.dispatch_operator(envelope) do
      {:ok, _} -> {:ok, :stopping}
      {:error, cause} -> {:error, {:cancel_failed, cause}}
      {:error, cause, _detail} -> {:error, {:cancel_failed, cause}}
    end
  end

  defp do_stop(
         %Thread{door: :jobsite, id: "jobsite:" <> jobsite_id, status: status},
         reason,
         opts
       )
       when status in @stoppable_jobsite_statuses do
    cond do
      Jobsite.Executor.pid_for(jobsite_id) != nil ->
        case Jobsite.cancel(jobsite_id, reason) do
          :ok -> {:ok, :stopping}
          {:error, %Jobsite.Error{} = error} -> {:error, {:cancel_failed, error.code}}
        end

      status == "paused" ->
        # A paused jobsite's executor has exited, so nothing would honor an
        # intent; cancel the aggregate itself.
        command = %{
          type: "jobsite.cancel",
          command_id: Keyword.get_lazy(opts, :idempotency_key, &fresh_command_id/0),
          aggregate_id: "jobsite:" <> jobsite_id,
          payload: %{jobsite_id: jobsite_id, reason: reason}
        }

        case CommandGateway.dispatch_system(command) do
          {:ok, _} -> {:ok, :stopping}
          {:error, cause} -> {:error, {:cancel_failed, cause}}
          {:error, cause, _detail} -> {:error, {:cancel_failed, cause}}
        end

      true ->
        {:error, {:no_executor, status}}
    end
  end

  defp do_stop(%Thread{status: status}, _reason, _opts), do: {:error, {:not_stoppable, status}}

  @steer_max_chars 8000

  @type steer_error ::
          :thread_not_found
          | {:not_steerable, String.t() | nil}
          | {:invalid_text, :blank | :too_long}
          | {:steer_failed, term()}

  @doc """
  Steer a thread with an operator message. `opts`: `:message_id` (idempotency
  key; default a fresh id - re-sending the same id is a no-op), `:resume`
  (workflow door only, default true: `false` keeps a paused run paused).

  Returns `{:ok, %{message_id: id, mode: :pause_resume}}`;
  `{:error, :thread_not_found}`; `{:error, {:not_steerable, status}}` for a
  terminal thread on either door; `{:error, {:invalid_text, :blank | :too_long}}`;
  `{:error, {:steer_failed, cause}}` for any other rejection (e.g. the
  jobsite's executor did not exit in time).
  """
  @spec steer(String.t(), term(), keyword()) ::
          {:ok, %{message_id: String.t(), mode: :pause_resume}} | {:error, steer_error()}
  def steer(thread_id, text, opts \\ []) when is_binary(thread_id) and is_list(opts) do
    message_id =
      case Keyword.get(opts, :message_id) do
        id when is_binary(id) and id != "" -> id
        _ -> fresh_message_id()
      end

    with {:ok, %Thread{} = thread} <- Threads.get(thread_id),
         :ok <- validate_steer_text(text),
         :ok <- do_steer(thread, text, message_id, Keyword.get(opts, :resume, true)) do
      {:ok, %{message_id: message_id, mode: :pause_resume}}
    end
  end

  @type follow_up_error ::
          steer_error()
          | :thread_resolved
          | {:needs_new_run, %{branch: String.t(), session_id: String.t() | nil}}

  @doc """
  Route a follow-up message to an existing thread. NEVER starts a run or a
  jobsite: the caller (coordinator) decides what to do when none is live.

    * live thread - `steer/3`; returns its `{:ok, %{message_id:, mode:}}`
    * terminal thread that still has a branch - `{:error, {:needs_new_run,
      %{branch:, session_id:}}}`; `session_id` is the thread's
      `provider_session_id`, `nil` when it has none
    * resolved thread - `{:error, :thread_resolved}` (reopen is never implicit)

  Other errors are those of `steer/3` (`:thread_not_found`, `{:invalid_text, _}`,
  `{:steer_failed, _}`, and `{:not_steerable, status}` for a terminal thread
  without a branch).

  `opts` are `steer/3`'s (`:message_id` makes a repeated follow-up a no-op).
  """
  @spec follow_up(String.t(), term(), keyword()) ::
          {:ok, %{message_id: String.t(), mode: :pause_resume}} | {:error, follow_up_error()}
  def follow_up(thread_id, text, opts \\ []) when is_binary(thread_id) and is_list(opts) do
    with {:ok, %Thread{} = thread} <- Threads.get(thread_id),
         :ok <- ensure_unresolved(thread) do
      case steer(thread_id, text, opts) do
        {:error, {:not_steerable, _status}} = error -> needs_new_run(thread, error)
        other -> other
      end
    end
  end

  defp ensure_unresolved(%Thread{resolved: true}), do: {:error, :thread_resolved}
  defp ensure_unresolved(%Thread{}), do: :ok

  defp needs_new_run(%Thread{branch: branch, provider_session_id: session_id}, _error)
       when is_binary(branch) and branch != "" do
    {:error, {:needs_new_run, %{branch: branch, session_id: session_id}}}
  end

  defp needs_new_run(%Thread{}, error), do: error

  defp validate_steer_text(text) when is_binary(text) do
    cond do
      String.trim(text) == "" -> {:error, {:invalid_text, :blank}}
      String.length(text) > @steer_max_chars -> {:error, {:invalid_text, :too_long}}
      true -> :ok
    end
  end

  defp validate_steer_text(_), do: {:error, {:invalid_text, :blank}}

  defp do_steer(%Thread{door: :workflow, id: "run:" <> run_id}, text, message_id, resume) do
    envelope = %{
      type: "run.steer",
      command_id: "thread-steer:" <> message_id,
      aggregate_id: "run:" <> run_id,
      payload: %{
        run_id: run_id,
        message_id: message_id,
        text: text,
        steered_by: "operator",
        resume: resume
      }
    }

    case CommandGateway.dispatch_operator(envelope) do
      {:ok, _} -> :ok
      {:error, cause} -> steer_error(cause)
      {:error, cause, _detail} -> steer_error(cause)
    end
  end

  defp do_steer(%Thread{door: :jobsite, id: "jobsite:" <> jobsite_id}, text, _message_id, _resume) do
    case Jobsite.steer(jobsite_id, text) do
      {:ok, _} -> :ok
      {:error, cause} -> steer_error(cause)
    end
  end

  defp steer_error({:run_terminal, status}), do: {:error, {:not_steerable, status}}
  defp steer_error({:not_steerable, _status} = cause), do: {:error, cause}
  defp steer_error(cause), do: {:error, {:steer_failed, cause}}

  defp fresh_message_id, do: "steer-" <> Elixir.EventStore.UUID.uuid4()

  defp normalize_reason(reason) when is_binary(reason) and reason != "", do: reason
  defp normalize_reason(_), do: @default_stop_reason

  defp fresh_command_id, do: "thread-stop:" <> Elixir.EventStore.UUID.uuid4()

  @type rereview_error :: :thread_not_found | Analyzer.rerun_error()

  @doc """
  Re-run the review of the thread's run or jobsite when its recorded review is
  `undetermined`. Returns `:ok` once the re-run is accepted, `{:error, :thread_not_found}`
  for an unknown thread, or the `Analyzer.rerun/2` reason unchanged.
  """
  @spec rereview(String.t()) :: :ok | {:error, rereview_error()}
  def rereview(thread_id) when is_binary(thread_id) do
    with {:ok, thread} <- Threads.get(thread_id) do
      {kind, subject_id} = review_subject(thread)
      Analyzer.rerun(kind, subject_id)
    end
  end

  defp review_subject(%Thread{door: :workflow, id: "run:" <> run_id}), do: {:run, run_id}

  defp review_subject(%Thread{door: :jobsite, id: "jobsite:" <> jobsite_id}),
    do: {:jobsite, jobsite_id}
end
