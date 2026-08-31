defmodule ForemanServer.Workflow.Worktree do
  @moduledoc """
  Lifecycle orchestrator for Foreman-managed VCS worktrees.

  Phase entry (success path):

      Worktree.create(%{...opts})
        -> VcsAdapter.run(Default, :create_worktree, [repo, path, [...]])
        -> CommandGateway.dispatch_system(%{type: "vcs.worktree.create", ...})
        -> emit [:foreman_server, :vcs, :worktree, :create]
        -> {:ok, worktree_path}

  Phase entry (compensation path):

      git worktree add succeeded
      vcs.worktree.create dispatch failed
        -> compensate via VcsAdapter.run(Default, :clean_worktree, ...)
        -> on clean compensation success: emit :create_compensated
        -> on clean compensation failure: dispatch
           vcs.worktree.create.orphan_record; on orphan-dispatch
           failure, emit :create_orphan_unrecorded with worktree path
        -> never fabricate WorktreeCreated

  Phase terminal (clean path):

      Worktree.clean(%{...opts})
        -> only proceed if ProjectionStore.worktree/1 reports
           status == "created"
        -> VcsAdapter.run(Default, :clean_worktree, ...)
        -> on success:
             CommandGateway.dispatch_system
             %{type: "vcs.worktree.clean", ...}
             emits :clean success
        -> on Git failure: emit :clean_failed, keep projection
           unresolved, do NOT overwrite original phase result
        -> on dispatch failure: emit :clean_dispatch_failed, keep
           projection unresolved

  Telemetry events align with TRD §6:

      [:foreman_server, :vcs, :worktree, :create]                  measurements: %{duration_ms: ms}
      [:foreman_server, :vcs, :worktree, :clean]                   measurements: %{duration_ms: ms}
      [:foreman_server, :vcs, :worktree, :create_failed]
      [:foreman_server, :vcs, :worktree, :clean_failed]
      [:foreman_server, :vcs, :worktree, :create_compensated]
      [:foreman_server, :vcs, :worktree, :clean_dispatch_failed]
      [:foreman_server, :vcs, :worktree, :create_compensation_failed]
      [:foreman_server, :vcs, :worktree, :create_orphan_unrecorded]
  """

  alias ForemanServer.{CommandGateway, ProjectionStore, VcsAdapter}
  alias ForemanServer.VcsAdapter.Default, as: DefaultAdapter

  @doc """
  Provision a worktree through the adapter and append `WorktreeCreated`.
  Returns `{:ok, worktree_path}` on success and an error tuple on failure.

  Failure semantics:
    * `git worktree add` failure -> emit `:create_failed`, return git error.
    * Append failure -> compensate via clean, emit `:create_compensated`
      on clean success; on clean failure, dispatch orphan record and emit
      `:create_compensation_failed`; on orphan-record dispatch failure,
      emit `:create_orphan_unrecorded` with the path for operator recovery.
    * `WorktreeCreated` is NEVER fabricated.
  """
  @spec create(map()) :: {:ok, String.t()} | {:error, term()}
  def create(%{
        operation_id: op_id,
        project_id: project_id,
        run_id: run_id,
        phase_id: phase_id,
        repo_path: repo_path,
        worktree_path: worktree_path,
        base_ref: base_ref,
        branch: branch
      })
      when is_binary(op_id) and op_id != "" do
    started_ms = System.monotonic_time(:millisecond)

    case run_create_git(
           op_id,
           repo_path,
           worktree_path,
           base_ref,
           branch,
           project_id,
           run_id,
           phase_id
         ) do
      {:ok, _git_result} ->
        case dispatch_worktree_created(
               op_id,
               project_id,
               run_id,
               phase_id,
               repo_path,
               worktree_path,
               branch,
               base_ref
             ) do
          :ok ->
            emit_create(
              op_id,
              project_id,
              run_id,
              phase_id,
              repo_path,
              worktree_path,
              base_ref,
              branch,
              started_ms
            )

            {:ok, worktree_path}

          {:error, append_error} ->
            handle_append_failure(
              started_ms,
              op_id,
              project_id,
              run_id,
              phase_id,
              repo_path,
              worktree_path,
              base_ref,
              branch,
              append_error
            )
        end

      {:error, git_error} ->
        emit_create_failed(
          op_id,
          project_id,
          run_id,
          phase_id,
          repo_path,
          worktree_path,
          base_ref,
          branch,
          started_ms,
          reason: git_error
        )

        {:error, git_error}
    end
  end

  @doc """
  Remove a worktree through the adapter and append `WorktreeCleaned`.
  Returns `:ok | {:ok, :already_cleaned}` on success and an error tuple
  on failure. The worktree must be provisioned (status == "created" in
  the projection) before this function will touch the disk.
  """
  @spec clean(map()) :: :ok | {:ok, :already_cleaned} | {:error, term()}
  def clean(%{
        operation_id: op_id,
        project_id: project_id,
        run_id: run_id,
        phase_id: phase_id,
        repo_path: repo_path
      })
      when is_binary(op_id) and op_id != "" do
    started_ms = System.monotonic_time(:millisecond)

    case ProjectionStore.worktree(op_id) do
      nil ->
        {:error, :worktree_not_provisioned}

      %{status: "cleaned"} ->
        {:ok, :already_cleaned}

      %{status: "created", worktree_path: worktree_path}
      when is_binary(worktree_path) and worktree_path != "" ->
        case run_clean_git(op_id, repo_path, worktree_path, project_id, run_id, phase_id) do
          {:ok, _git_result} ->
            case dispatch_worktree_cleaned(
                   op_id,
                   project_id,
                   run_id,
                   phase_id,
                   repo_path,
                   worktree_path
                 ) do
              :ok ->
                emit_clean(op_id, project_id, run_id, phase_id, worktree_path, started_ms,
                  noop?: false
                )

                :ok

              {:error, append_error} ->
                emit_clean_dispatch_failed(
                  op_id,
                  project_id,
                  run_id,
                  phase_id,
                  worktree_path,
                  started_ms,
                  reason: append_error
                )

                {:error, {:worktree_clean_append_failed, append_error}}
            end

          {:error, git_error} ->
            emit_clean_failed(op_id, project_id, run_id, phase_id, worktree_path, started_ms,
              reason: git_error
            )

            {:error, git_error}
        end

      %{status: "created"} ->
        {:error, :worktree_path_missing}
    end
  end

  @doc """
  Best-effort cleanup for every projected worktree owned by a run, then delete
  each matching local branch. Used by `run.remove` after the run is terminated.
  """

  @spec clean_for_run(String.t()) :: :ok
  def clean_for_run(run_id) when is_binary(run_id) and run_id != "" do
    cleanup_errors =
      ProjectionStore.worktrees_for_run(run_id)
      |> Enum.reduce([], fn worktree, acc ->
        case clean(worktree) do
          :ok -> acc
          {:error, reason} -> [{worktree.worktree_path, reason} | acc]
        end
      end)

    if cleanup_errors != [] do
      :telemetry.execute(
        [:foreman_server, :run, :worktree_cleanup_failed],
        %{count: length(cleanup_errors)},
        %{run_id: run_id, failures: cleanup_errors}
      )
    end

    # Delete the run's branch from every worktree's repo.
    ProjectionStore.worktrees_for_run(run_id)
    |> Enum.each(fn worktree -> _ = delete_branch(worktree) end)

    :ok
  end

  @doc """
  Recover a worktree-create orphan: tear down the durable worktree path
  directly via the adapter. This path bypasses
  `ProjectionStore.worktree/1` because the orphan's `WorktreeCreated` event
  was never persisted — only `WorktreeCreateOrphanRecorded` was.

  Cleanup-only; the caller (BootReconciliation) owns the
  `vcs.worktree.create.orphan_resolve` dispatch so the projection can be
  cleared after the disk teardown.

  Returns `:ok` on success and `{:error, reason}` on adapter failure.
  No `WorktreeCleaned` event is emitted; recovery is exclusively through
  `WorktreeCreateOrphanResolved`.
  """
  @spec clean_orphan(map()) :: :ok | {:error, term()}
  def clean_orphan(%{
        operation_id: op_id,
        project_id: project_id,
        run_id: run_id,
        phase_id: phase_id,
        repo_path: repo_path,
        worktree_path: worktree_path
      })
      when is_binary(op_id) and op_id != "" and is_binary(worktree_path) and
             worktree_path != "" do
    case run_clean_git(op_id, repo_path, worktree_path, project_id, run_id, phase_id) do
      {:ok, _git_result} -> :ok
      {:error, git_error} -> {:error, git_error}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp delete_branch(%{repo_path: repo_path, branch: branch})
       when is_binary(repo_path) and repo_path != "" and is_binary(branch) and branch != "" do
    if protected_branch?(branch) do
      :ok
    else
      case System.cmd("git", ["-C", repo_path, "branch", "-D", branch], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, _} -> {:error, {:branch_delete_failed, branch, output}}
      end
    end
  end

  defp delete_branch(_worktree), do: :ok

  defp protected_branch?(branch), do: branch in ["main", "master", "trunk"]

  defp handle_append_failure(
         started_ms,
         op_id,
         project_id,
         run_id,
         phase_id,
         repo_path,
         worktree_path,
         base_ref,
         branch,
         append_error
       ) do
    emit_create_failed(
      op_id,
      project_id,
      run_id,
      phase_id,
      repo_path,
      worktree_path,
      base_ref,
      branch,
      started_ms,
      reason: {:append_failed, append_error}
    )

    case run_clean_git(op_id, repo_path, worktree_path, project_id, run_id, phase_id) do
      {:ok, _git_result} ->
        emit_create_compensated(
          op_id,
          project_id,
          run_id,
          phase_id,
          repo_path,
          worktree_path,
          base_ref,
          branch,
          started_ms
        )

        {:error, {:worktree_create_compensated, append_error}}

      {:error, _comp_reason} ->
        emit_create_compensation_failed(
          op_id,
          project_id,
          run_id,
          phase_id,
          repo_path,
          worktree_path,
          base_ref,
          branch,
          started_ms
        )

        record_orphan(op_id, project_id, run_id, phase_id, worktree_path, :compensation_failed)
        {:error, {:worktree_create_orphaned, append_error}}
    end
  end

  defp record_orphan(op_id, project_id, run_id, phase_id, worktree_path, reason) do
    case dispatch_worktree_create_orphan(
           op_id,
           project_id,
           run_id,
           phase_id,
           worktree_path,
           reason
         ) do
      :ok ->
        :ok

      {:error, _orphan_error} ->
        :telemetry.execute(
          [:foreman_server, :vcs, :worktree, :create_orphan_unrecorded],
          %{},
          %{
            run_id: run_id,
            phase_id: phase_id,
            operation_id: op_id,
            worktree_path: worktree_path,
            reason: reason
          }
        )
    end
  end

  defp run_create_git(
         op_id,
         repo_path,
         worktree_path,
         base_ref,
         branch,
         project_id,
         run_id,
         phase_id
       ) do
    VcsAdapter.run(
      DefaultAdapter,
      :create_worktree,
      [
        repo_path,
        worktree_path,
        [
          operation_id: op_id,
          base: base_ref,
          branch: branch,
          project_id: project_id,
          run_id: run_id,
          phase_id: phase_id
        ]
      ],
      []
    )
  end

  defp run_clean_git(op_id, repo_path, worktree_path, project_id, run_id, phase_id) do
    VcsAdapter.run(
      DefaultAdapter,
      :clean_worktree,
      [
        worktree_path,
        [
          operation_id: op_id,
          repo_path: repo_path,
          project_id: project_id,
          run_id: run_id,
          phase_id: phase_id
        ]
      ],
      []
    )
  end

  defp dispatch_worktree_created(
         op_id,
         project_id,
         run_id,
         phase_id,
         repo_path,
         worktree_path,
         branch,
         base_ref
       ) do
    command = %{
      command_id: "vcs.worktree.create:" <> op_id,
      aggregate_id: "vcs:" <> op_id,
      type: "vcs.worktree.create",
      payload: %{
        operation_id: op_id,
        project_id: project_id,
        run_id: run_id,
        phase_id: phase_id,
        repo_path: repo_path,
        worktree_path: worktree_path,
        branch: branch,
        base_ref: base_ref
      }
    }

    case CommandGateway.dispatch_system(command) do
      {:ok, _event} -> :ok
      {:error, _} = err -> err
    end
  end

  defp dispatch_worktree_cleaned(op_id, project_id, run_id, phase_id, repo_path, worktree_path) do
    command = %{
      command_id: "vcs.worktree.clean:" <> op_id,
      aggregate_id: "vcs:" <> op_id,
      type: "vcs.worktree.clean",
      payload: %{
        operation_id: op_id,
        project_id: project_id,
        run_id: run_id,
        phase_id: phase_id,
        repo_path: repo_path,
        worktree_path: worktree_path
      }
    }

    case CommandGateway.dispatch_system(command) do
      {:ok, _event} -> :ok
      {:error, _} = err -> err
    end
  end

  defp dispatch_worktree_create_orphan(op_id, project_id, run_id, phase_id, worktree_path, reason) do
    command = %{
      command_id: "vcs.worktree.create.orphan_record:" <> op_id,
      aggregate_id: "vcs:" <> op_id,
      type: "vcs.worktree.create.orphan_record",
      payload: %{
        operation_id: op_id,
        project_id: project_id,
        run_id: run_id,
        phase_id: phase_id,
        worktree_path: worktree_path,
        reason: to_string(reason)
      }
    }

    case CommandGateway.dispatch_system(command) do
      {:ok, _event} -> :ok
      {:error, _} = err -> err
    end
  end

  defp duration_ms(started_ms), do: System.monotonic_time(:millisecond) - started_ms

  defp success_metadata(
         op_id,
         project_id,
         run_id,
         phase_id,
         repo_path,
         worktree_path,
         base,
         branch
       ) do
    %{
      run_id: run_id,
      phase_id: phase_id,
      operation_id: op_id,
      repo_path: repo_path,
      worktree_path: worktree_path,
      base: base,
      branch: branch
    }
  end

  defp emit_create(
         op_id,
         project_id,
         run_id,
         phase_id,
         repo_path,
         worktree_path,
         base,
         branch,
         started_ms
       ) do
    :telemetry.execute(
      [:foreman_server, :vcs, :worktree, :create],
      %{duration_ms: duration_ms(started_ms)},
      success_metadata(
        op_id,
        project_id,
        run_id,
        phase_id,
        repo_path,
        worktree_path,
        base,
        branch
      )
    )
  end

  defp emit_clean(op_id, project_id, run_id, phase_id, worktree_path, started_ms, opts) do
    noop? = Keyword.get(opts, :noop?, false)

    :telemetry.execute(
      [:foreman_server, :vcs, :worktree, :clean],
      %{duration_ms: duration_ms(started_ms)},
      %{
        run_id: run_id,
        phase_id: phase_id,
        operation_id: op_id,
        worktree_path: worktree_path,
        noop?: noop?
      }
    )
  end

  defp emit_create_failed(
         op_id,
         project_id,
         run_id,
         phase_id,
         repo_path,
         worktree_path,
         base,
         branch,
         started_ms,
         opts
       ) do
    reason = Keyword.fetch!(opts, :reason)

    base_meta =
      success_metadata(
        op_id,
        project_id,
        run_id,
        phase_id,
        repo_path,
        worktree_path,
        base,
        branch
      )

    :telemetry.execute(
      [:foreman_server, :vcs, :worktree, :create_failed],
      %{duration_ms: duration_ms(started_ms)},
      Map.put(base_meta, :reason, reason)
    )
  end

  defp emit_clean_failed(op_id, project_id, run_id, phase_id, worktree_path, started_ms, opts) do
    reason = Keyword.fetch!(opts, :reason)

    :telemetry.execute(
      [:foreman_server, :vcs, :worktree, :clean_failed],
      %{duration_ms: duration_ms(started_ms)},
      %{
        run_id: run_id,
        phase_id: phase_id,
        operation_id: op_id,
        worktree_path: worktree_path,
        reason: reason
      }
    )
  end

  defp emit_create_compensated(
         op_id,
         project_id,
         run_id,
         phase_id,
         repo_path,
         worktree_path,
         base,
         branch,
         started_ms
       ) do
    :telemetry.execute(
      [:foreman_server, :vcs, :worktree, :create_compensated],
      %{duration_ms: duration_ms(started_ms)},
      success_metadata(
        op_id,
        project_id,
        run_id,
        phase_id,
        repo_path,
        worktree_path,
        base,
        branch
      )
    )
  end

  defp emit_clean_dispatch_failed(
         op_id,
         project_id,
         run_id,
         phase_id,
         worktree_path,
         started_ms,
         opts
       ) do
    reason = Keyword.fetch!(opts, :reason)

    :telemetry.execute(
      [:foreman_server, :vcs, :worktree, :clean_dispatch_failed],
      %{duration_ms: duration_ms(started_ms)},
      %{
        run_id: run_id,
        phase_id: phase_id,
        operation_id: op_id,
        worktree_path: worktree_path,
        reason: reason
      }
    )
  end

  defp emit_create_compensation_failed(
         op_id,
         project_id,
         run_id,
         phase_id,
         repo_path,
         worktree_path,
         base,
         branch,
         started_ms
       ) do
    :telemetry.execute(
      [:foreman_server, :vcs, :worktree, :create_compensation_failed],
      %{duration_ms: duration_ms(started_ms)},
      success_metadata(
        op_id,
        project_id,
        run_id,
        phase_id,
        repo_path,
        worktree_path,
        base,
        branch
      )
    )
  end
end
