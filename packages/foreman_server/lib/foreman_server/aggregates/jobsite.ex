defmodule ForemanServer.Aggregates.Jobsite do
  @moduledoc """
  Event-sourced aggregate for a scripted, event-sourced agent run ("jobsite").

  State is authoritative: the executor holds no state the event stream cannot
  reproduce, so a paused or crashed jobsite resumes by rehydrating this
  aggregate (`ForemanServer.Aggregate.load/2`), not by reading an audit log.
  """
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.EventCodec

  alias ForemanServer.Events.{
    JobsiteStarted,
    JobsiteWorktreeProvisioned,
    JobsiteSandboxProvisioned,
    JobsiteIterationStarted,
    JobsiteIterationCompleted,
    JobsiteIterationFailed,
    JobsiteCommitsRecorded,
    JobsiteOutputCaptured,
    JobsiteSandboxReleased,
    JobsiteWorktreeReleased,
    JobsiteCompleted,
    JobsiteFailed,
    JobsitePaused,
    JobsiteCancelled
  }

  defmodule State do
    @moduledoc "Authoritative in-memory state for a `jobsite:<id>` stream."
    @enforce_keys [:exists?, :jobsite_id, :status, :terminal?]
    defstruct exists?: false,
              jobsite_id: nil,
              status: nil,
              terminal?: false,
              repo_path: nil,
              strategy: nil,
              branch: nil,
              target_branch: nil,
              base_sha: nil,
              worktree_path: nil,
              worktree_reused?: false,
              sandbox_provider: nil,
              sandbox_config: %{},
              container_id: nil,
              sandbox_repo_path: nil,
              sandbox_attempt: 0,
              agent: %{},
              max_iterations: 1,
              completion_signals: [],
              prompt_digest: nil,
              name: nil,
              push?: false,
              iteration_index: 0,
              iteration_open?: false,
              iterations: [],
              session_id: nil,
              commits: [],
              output: nil,
              merged?: false,
              preserved_path: nil,
              last_error: nil
  end

  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      jobsite_id: nil,
      status: nil,
      terminal?: false
    }

  # ---------------------------------------------------------------------
  # apply_event/2 — typed structs (from `Aggregate.load/2` replay) and the
  # append-then-apply path (a map from `handle_command/2`'s own event spec,
  # applied by the Actor immediately after a confirmed append).
  # ---------------------------------------------------------------------

  @impl true
  def apply_event(state, %JobsiteStarted{} = e), do: apply_typed(state, e)
  def apply_event(state, %JobsiteWorktreeProvisioned{} = e), do: apply_typed(state, e)
  def apply_event(state, %JobsiteSandboxProvisioned{} = e), do: apply_typed(state, e)
  def apply_event(state, %JobsiteIterationStarted{} = e), do: apply_typed(state, e)
  def apply_event(state, %JobsiteIterationCompleted{} = e), do: apply_typed(state, e)
  def apply_event(state, %JobsiteIterationFailed{} = e), do: apply_typed(state, e)
  def apply_event(state, %JobsiteCommitsRecorded{} = e), do: apply_typed(state, e)
  def apply_event(state, %JobsiteOutputCaptured{} = e), do: apply_typed(state, e)
  def apply_event(state, %JobsiteSandboxReleased{} = e), do: apply_typed(state, e)
  def apply_event(state, %JobsiteWorktreeReleased{} = e), do: apply_typed(state, e)
  def apply_event(state, %JobsiteCompleted{} = e), do: apply_typed(state, e)
  def apply_event(state, %JobsiteFailed{} = e), do: apply_typed(state, e)
  def apply_event(state, %JobsitePaused{} = e), do: apply_typed(state, e)
  def apply_event(state, %JobsiteCancelled{} = e), do: apply_typed(state, e)

  def apply_event(state, event) do
    case Aggregate.event_type(event) do
      nil ->
        state

      type ->
        payload =
          event
          |> Aggregate.event_payload()
          |> Map.delete(:event_type)
          |> Map.delete("event_type")

        apply_typed(state, EventCodec.decode!(type, payload))
    end
  end

  defp apply_typed(%State{} = state, %JobsiteStarted{} = e) do
    %State{
      state
      | exists?: true,
        jobsite_id: e.jobsite_id,
        status: "starting",
        repo_path: e.repo_path,
        strategy: e.strategy,
        branch: e.branch,
        target_branch: e.target_branch,
        base_sha: e.base_sha,
        agent: e.agent || %{},
        sandbox_provider: e.sandbox_provider,
        sandbox_config: e.sandbox_config || %{},
        max_iterations: e.max_iterations || 1,
        completion_signals: e.completion_signals || [],
        prompt_digest: e.prompt_digest,
        name: e.name,
        push?: e.push == true
    }
  end

  defp apply_typed(%State{} = state, %JobsiteWorktreeProvisioned{} = e) do
    %State{
      state
      | status: "running",
        worktree_path: e.path,
        branch: e.branch,
        base_sha: e.base_sha,
        worktree_reused?: e.reused? || false
    }
  end

  # A resume provisions a fresh sandbox and then runs iteration `iteration_index + 1`,
  # which can exceed the limit the jobsite started with (a pause or crash during the
  # last iteration). The executor widens its own bound by the same rule, so the
  # aggregate must too, or it rejects the resumed iteration as over the limit and the
  # accepted resume ends `failed`. Derived from replayed state, so it stays deterministic.
  defp apply_typed(%State{} = state, %JobsiteSandboxProvisioned{} = e) do
    %State{
      state
      | status: "running",
        sandbox_provider: e.provider,
        sandbox_repo_path: e.sandbox_repo_path,
        container_id: e.container_id,
        sandbox_attempt: e.attempt || state.sandbox_attempt + 1,
        max_iterations: max(state.max_iterations, state.iteration_index + 1)
    }
  end

  defp apply_typed(%State{} = state, %JobsiteIterationStarted{} = e) do
    %State{
      state
      | iteration_index: e.index,
        iteration_open?: true,
        session_id: e.resumed_session_id || state.session_id
    }
  end

  defp apply_typed(%State{} = state, %JobsiteIterationCompleted{} = e) do
    record = %{
      index: e.index,
      status: e.status,
      text: e.text,
      text_truncated?: e.text_truncated? || false,
      session_id: e.session_id,
      usage: e.usage || %{},
      signalled?: e.signalled? || false,
      matched_signal: e.matched_signal
    }

    %State{
      state
      | iteration_open?: false,
        session_id: e.session_id || state.session_id,
        iterations: state.iterations ++ [record]
    }
  end

  defp apply_typed(%State{} = state, %JobsiteIterationFailed{} = e) do
    record = %{
      index: e.index,
      status: "failed",
      code: e.code,
      message: e.message,
      details: e.details
    }

    %State{
      state
      | iteration_open?: false,
        iterations: state.iterations ++ [record],
        last_error: %{code: e.code, message: e.message, details: e.details}
    }
  end

  defp apply_typed(%State{} = state, %JobsiteCommitsRecorded{} = e) do
    %State{state | commits: e.commits}
  end

  defp apply_typed(%State{} = state, %JobsiteOutputCaptured{} = e) do
    %State{state | output: %{tag: e.tag, value: e.value}}
  end

  defp apply_typed(%State{} = state, %JobsiteSandboxReleased{}) do
    %State{state | container_id: nil}
  end

  defp apply_typed(%State{} = state, %JobsiteWorktreeReleased{} = e) do
    %State{state | merged?: e.merged? || false, preserved_path: e.preserved_path}
  end

  defp apply_typed(%State{} = state, %JobsiteCompleted{}) do
    %State{state | status: "completed", terminal?: true}
  end

  defp apply_typed(%State{} = state, %JobsiteFailed{} = e) do
    %State{
      state
      | status: "failed",
        terminal?: true,
        last_error: %{code: e.code, message: e.message, details: e.details}
    }
  end

  defp apply_typed(%State{} = state, %JobsitePaused{}) do
    # Deliberately NOT terminal: a paused jobsite still accepts the commands
    # `resume` dispatches.
    %State{state | status: "paused", terminal?: false}
  end

  defp apply_typed(%State{} = state, %JobsiteCancelled{}) do
    %State{state | status: "cancelled", terminal?: true}
  end

  # ---------------------------------------------------------------------
  # handle_command/2
  # ---------------------------------------------------------------------

  @impl true
  def handle_command(state, %{type: "jobsite.start", payload: payload}) do
    with {:ok, jobsite_id} <- required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         {:ok, repo_path} <- required_binary(Aggregate.get(payload, :repo_path), :repo_path),
         {:ok, strategy} <- required_binary(Aggregate.get(payload, :strategy), :strategy),
         :ok <- require_absent(state, jobsite_id) do
      {:ok,
       %{
         stream_id: "jobsite:#{jobsite_id}",
         event_type: "JobsiteStarted",
         payload:
           Map.merge(payload, %{
             jobsite_id: jobsite_id,
             repo_path: repo_path,
             strategy: strategy
           })
       }}
    end
  end

  def handle_command(state, %{type: "jobsite.worktree.provision", payload: payload}) do
    with {:ok, jobsite_id} <- required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         {:ok, path} <- required_binary(Aggregate.get(payload, :path), :path),
         {:ok, branch} <- required_binary(Aggregate.get(payload, :branch), :branch),
         {:ok, base_sha} <- required_binary(Aggregate.get(payload, :base_sha), :base_sha),
         :ok <- require_exists(state, jobsite_id),
         :ok <- reject_terminal(state),
         :ok <- require_no_worktree(state) do
      {:ok,
       %{
         stream_id: "jobsite:#{jobsite_id}",
         event_type: "JobsiteWorktreeProvisioned",
         payload:
           Map.merge(payload, %{
             jobsite_id: jobsite_id,
             path: path,
             branch: branch,
             base_sha: base_sha
           })
       }}
    end
  end

  def handle_command(state, %{type: "jobsite.sandbox.provision", payload: payload}) do
    with {:ok, jobsite_id} <- required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         {:ok, provider} <- required_binary(Aggregate.get(payload, :provider), :provider),
         {:ok, sandbox_repo_path} <-
           required_binary(Aggregate.get(payload, :sandbox_repo_path), :sandbox_repo_path),
         :ok <- require_exists(state, jobsite_id),
         :ok <- reject_terminal(state),
         :ok <- require_worktree_present(state, jobsite_id) do
      {:ok,
       %{
         stream_id: "jobsite:#{jobsite_id}",
         event_type: "JobsiteSandboxProvisioned",
         payload:
           Map.merge(payload, %{
             jobsite_id: jobsite_id,
             provider: provider,
             sandbox_repo_path: sandbox_repo_path,
             attempt: state.sandbox_attempt + 1
           })
       }}
    end
  end

  def handle_command(state, %{type: "jobsite.iteration.start", payload: payload}) do
    with {:ok, jobsite_id} <- required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         {:ok, index} <- required_integer(Aggregate.get(payload, :index), :index),
         :ok <- require_exists(state, jobsite_id),
         :ok <- reject_terminal(state),
         :ok <- require_iteration_closed(state),
         :ok <- require_iteration_in_order(state, index),
         :ok <- require_within_iteration_limit(state, index) do
      {:ok,
       %{
         stream_id: "jobsite:#{jobsite_id}",
         event_type: "JobsiteIterationStarted",
         payload: Map.merge(payload, %{jobsite_id: jobsite_id, index: index})
       }}
    end
  end

  def handle_command(state, %{type: "jobsite.iteration.complete", payload: payload}) do
    with {:ok, jobsite_id} <- required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         {:ok, index} <- required_integer(Aggregate.get(payload, :index), :index),
         {:ok, status} <- required_binary(Aggregate.get(payload, :status), :status),
         :ok <- require_exists(state, jobsite_id),
         :ok <- reject_terminal(state),
         :ok <- require_iteration_open(state, index) do
      {:ok,
       %{
         stream_id: "jobsite:#{jobsite_id}",
         event_type: "JobsiteIterationCompleted",
         payload: Map.merge(payload, %{jobsite_id: jobsite_id, index: index, status: status})
       }}
    end
  end

  def handle_command(state, %{type: "jobsite.iteration.fail", payload: payload}) do
    with {:ok, jobsite_id} <- required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         {:ok, index} <- required_integer(Aggregate.get(payload, :index), :index),
         {:ok, code} <- required_binary(Aggregate.get(payload, :code), :code),
         {:ok, message} <- required_binary(Aggregate.get(payload, :message), :message),
         :ok <- require_exists(state, jobsite_id),
         :ok <- reject_terminal(state),
         :ok <- require_iteration_open(state, index) do
      {:ok,
       %{
         stream_id: "jobsite:#{jobsite_id}",
         event_type: "JobsiteIterationFailed",
         payload:
           Map.merge(payload, %{
             jobsite_id: jobsite_id,
             index: index,
             code: code,
             message: message
           })
       }}
    end
  end

  def handle_command(state, %{type: "jobsite.commits.record", payload: payload}) do
    with {:ok, jobsite_id} <- required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         {:ok, commits} <- required_list(Aggregate.get(payload, :commits), :commits),
         :ok <- require_exists(state, jobsite_id),
         :ok <- reject_terminal(state) do
      {:ok,
       %{
         stream_id: "jobsite:#{jobsite_id}",
         event_type: "JobsiteCommitsRecorded",
         payload: Map.merge(payload, %{jobsite_id: jobsite_id, commits: commits})
       }}
    end
  end

  def handle_command(state, %{type: "jobsite.output.capture", payload: payload}) do
    with {:ok, jobsite_id} <- required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         {:ok, tag} <- required_binary(Aggregate.get(payload, :tag), :tag),
         :ok <- require_exists(state, jobsite_id),
         :ok <- reject_terminal(state) do
      {:ok,
       %{
         stream_id: "jobsite:#{jobsite_id}",
         event_type: "JobsiteOutputCaptured",
         payload: Map.merge(payload, %{jobsite_id: jobsite_id, tag: tag})
       }}
    end
  end

  def handle_command(state, %{type: "jobsite.sandbox.release", payload: payload}) do
    with {:ok, jobsite_id} <- required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         :ok <- require_exists(state, jobsite_id) do
      {:ok,
       %{
         stream_id: "jobsite:#{jobsite_id}",
         event_type: "JobsiteSandboxReleased",
         payload: Map.merge(payload, %{jobsite_id: jobsite_id})
       }}
    end
  end

  def handle_command(state, %{type: "jobsite.worktree.release", payload: payload}) do
    with {:ok, jobsite_id} <- required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         :ok <- require_exists(state, jobsite_id) do
      {:ok,
       %{
         stream_id: "jobsite:#{jobsite_id}",
         event_type: "JobsiteWorktreeReleased",
         payload: Map.merge(payload, %{jobsite_id: jobsite_id})
       }}
    end
  end

  def handle_command(state, %{type: "jobsite.complete", payload: payload}) do
    with {:ok, jobsite_id} <- required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         {:ok, iterations_run} <-
           required_integer(Aggregate.get(payload, :iterations_run), :iterations_run),
         :ok <- require_exists(state, jobsite_id),
         :ok <- reject_terminal(state) do
      {:ok,
       %{
         stream_id: "jobsite:#{jobsite_id}",
         event_type: "JobsiteCompleted",
         payload: Map.merge(payload, %{jobsite_id: jobsite_id, iterations_run: iterations_run})
       }}
    end
  end

  def handle_command(state, %{type: "jobsite.fail", payload: payload}) do
    with {:ok, jobsite_id} <- required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         {:ok, code} <- required_binary(Aggregate.get(payload, :code), :code),
         {:ok, message} <- required_binary(Aggregate.get(payload, :message), :message),
         :ok <- require_exists(state, jobsite_id),
         :ok <- reject_terminal(state) do
      {:ok,
       %{
         stream_id: "jobsite:#{jobsite_id}",
         event_type: "JobsiteFailed",
         payload: Map.merge(payload, %{jobsite_id: jobsite_id, code: code, message: message})
       }}
    end
  end

  def handle_command(state, %{type: "jobsite.pause", payload: payload}) do
    with {:ok, jobsite_id} <- required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         {:ok, reason} <- required_binary(Aggregate.get(payload, :reason), :reason),
         :ok <- require_exists(state, jobsite_id),
         :ok <- reject_terminal(state) do
      {:ok,
       %{
         stream_id: "jobsite:#{jobsite_id}",
         event_type: "JobsitePaused",
         payload: Map.merge(payload, %{jobsite_id: jobsite_id, reason: reason})
       }}
    end
  end

  def handle_command(state, %{type: "jobsite.cancel", payload: payload}) do
    with {:ok, jobsite_id} <- required_binary(Aggregate.get(payload, :jobsite_id), :jobsite_id),
         {:ok, reason} <- required_binary(Aggregate.get(payload, :reason), :reason),
         :ok <- require_exists(state, jobsite_id),
         :ok <- reject_terminal(state) do
      {:ok,
       %{
         stream_id: "jobsite:#{jobsite_id}",
         event_type: "JobsiteCancelled",
         payload: Map.merge(payload, %{jobsite_id: jobsite_id, reason: reason})
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  # ---------------------------------------------------------------------
  # Guards — each rejection is distinct per AGENTS.md §5.3, never a shared
  # catch-all.
  # ---------------------------------------------------------------------

  defp require_absent(%State{exists?: true}, jobsite_id),
    do: {:error, {:jobsite_exists, jobsite_id}}

  defp require_absent(%State{exists?: false}, _jobsite_id), do: :ok

  defp require_exists(%State{exists?: true}, _jobsite_id), do: :ok

  defp require_exists(%State{exists?: false}, jobsite_id),
    do: {:error, {:jobsite_absent, jobsite_id}}

  defp reject_terminal(%State{terminal?: true, status: status}),
    do: {:error, {:jobsite_terminal, status}}

  defp reject_terminal(%State{terminal?: false}), do: :ok

  defp require_no_worktree(%State{worktree_path: nil}), do: :ok

  defp require_no_worktree(%State{worktree_path: path}),
    do: {:error, {:worktree_already_provisioned, path}}

  defp require_worktree_present(%State{worktree_path: nil}, jobsite_id),
    do: {:error, {:sandbox_before_worktree, jobsite_id}}

  defp require_worktree_present(%State{worktree_path: path}, _jobsite_id) when is_binary(path),
    do: :ok

  defp require_iteration_closed(%State{iteration_open?: false}), do: :ok

  defp require_iteration_closed(%State{iteration_open?: true, iteration_index: idx}),
    do: {:error, {:iteration_already_open, idx}}

  defp require_iteration_open(%State{iteration_open?: true, iteration_index: idx}, idx), do: :ok

  defp require_iteration_open(%State{iteration_open?: false, iteration_index: idx}, _requested),
    do: {:error, {:iteration_not_open, idx}}

  defp require_iteration_open(%State{iteration_index: current}, requested),
    do: {:error, {:iteration_out_of_order, current, requested}}

  defp require_iteration_in_order(%State{iteration_index: current}, requested)
       when requested == current + 1,
       do: :ok

  defp require_iteration_in_order(%State{iteration_index: current}, requested),
    do: {:error, {:iteration_out_of_order, current + 1, requested}}

  defp require_within_iteration_limit(%State{max_iterations: max}, index) when index <= max,
    do: :ok

  defp require_within_iteration_limit(%State{max_iterations: max}, _index),
    do: {:error, {:iteration_limit_exceeded, max}}

  # ---------------------------------------------------------------------
  # Local validation helpers — `Aggregate.required_binary/2` covers binaries;
  # `index`/`iterations_run` are integers, and `commits` is a list, neither
  # of which the shared helper validates.
  # ---------------------------------------------------------------------

  defp required_binary(value, key), do: Aggregate.required_binary(value, key)

  defp required_integer(value, _key) when is_integer(value), do: {:ok, value}
  defp required_integer(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp required_list(value, _key) when is_list(value), do: {:ok, value}
  defp required_list(_value, key), do: {:error, {:missing_or_invalid, key}}
end
