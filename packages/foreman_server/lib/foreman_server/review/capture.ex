defmodule ForemanServer.Review.Capture do
  @moduledoc """
  Writes a run's session material into its `ForemanServer.Review.Archive`.

  Capture never raises and never fails a run: every function returns `:ok` or
  `{:error, %Review.Error{}}`, and every failure is also logged and recorded in
  the manifest's `capture_errors`.
  """

  require Logger

  alias ForemanServer.Jobsite.Git
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Review.Archive
  alias ForemanServer.Review.Error

  @default_max_diff_bytes 1_000_000

  @doc "Append an iteration's harness events to the transcript and record its provider session id."
  @spec put_iteration(String.t() | nil, Jido.Harness.RunResult.t()) :: :ok | {:error, Error.t()}
  def put_iteration(nil, _result), do: :ok

  def put_iteration(archive_dir, %Jido.Harness.RunResult{} = result)
      when is_binary(archive_dir) do
    if Archive.capture_enabled?() do
      guarded("put_iteration", archive_dir, fn ->
        with :ok <- Archive.append_events(archive_dir, result.events || []) do
          put_session_id(archive_dir, result.provider_session_id)
        end
      end)
    else
      :ok
    end
  end

  @doc "Create the jobsite archive: verbatim `request.md` plus the initial manifest."
  @spec open_jobsite(String.t(), map(), String.t()) :: :ok | {:error, Error.t()}
  def open_jobsite(jobsite_id, spec, prompt)
      when is_binary(jobsite_id) and is_map(spec) and is_binary(prompt) do
    if Archive.capture_enabled?() do
      dir = Archive.dir(:jobsite, jobsite_id, spec.repo_path)

      guarded("open_jobsite", dir, fn ->
        manifest = %{
          "kind" => "jobsite",
          "subject_id" => jobsite_id,
          "project_id" => Map.get(spec, :project_id),
          "repo_path" => spec.repo_path,
          "bead_id" => Map.get(spec, :bead_id),
          "request" => %{
            "source" => "jobsite",
            "title" => Keyword.get(spec.opts, :name),
            "prompt" => prompt,
            "workflow_name" => nil
          },
          "agent" => %{
            "provider" => spec.agent.provider && Atom.to_string(spec.agent.provider),
            "model" => spec.agent.model
          },
          "strategy" => strategy_name(spec.strategy),
          "status" => "running",
          "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "transcript_source" => "harness_events"
        }

        with :ok <- Archive.init(dir, manifest) do
          Archive.write_file(dir, "request.md", prompt)
        end
      end)
    else
      :ok
    end
  end

  @doc "Capture `diff.patch` and `changed-files.txt` for `base..head` of the worktree."
  @spec put_diff(String.t() | nil, String.t(), String.t(), String.t() | :worktree) ::
          :ok | {:error, Error.t()}
  def put_diff(nil, _worktree_path, _base, _head), do: :ok

  def put_diff(archive_dir, worktree_path, base, head) when is_binary(archive_dir) do
    if Archive.capture_enabled?() do
      guarded("put_diff", archive_dir, fn ->
        do_put_diff(archive_dir, worktree_path, base, head)
      end)
    else
      :ok
    end
  end

  @doc """
  The bead id behind a projected task, or nil. A task's `external_id` is a bead
  id only when it was synthesised by `BeadsWatcher`, whose task id is exactly
  `"beads:<project_id>:<external_id>"`; any other external id (another
  integration) is NOT a bead id.
  """
  @spec bead_id_for_task(map() | nil) :: String.t() | nil
  def bead_id_for_task(%{task_id: task_id, project_id: project_id, external_id: external_id})
      when is_binary(task_id) and is_binary(project_id) and is_binary(external_id) and
             external_id != "" do
    if task_id == "beads:" <> project_id <> ":" <> external_id, do: external_id, else: nil
  end

  def bead_id_for_task(_other), do: nil

  @doc """
  The single source of a run's repo path: the first non-empty `repo_path` among
  its projected worktrees. Absent is a typed error, never a guess.
  """
  @spec run_repo_path(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def run_repo_path(run_id) when is_binary(run_id) do
    path =
      run_id
      |> ProjectionStore.worktrees_for_run()
      |> Enum.find_value(fn wt ->
        case Map.get(wt, :repo_path) do
          p when is_binary(p) and p != "" -> p
          _ -> nil
        end
      end)

    case path do
      nil ->
        {:error,
         Error.new(:archive_missing, "run has no projected worktree repo_path", %{run_id: run_id})}

      path ->
        {:ok, path}
    end
  end

  @doc """
  Archive a terminal workflow run: request, manifest and diff. Called from
  `RunExecutor.cleanup_run_worktree/2` while the worktree still exists. Never
  raises; failures are logged and (when an archive exists) recorded in the
  manifest's `capture_errors`.
  """
  @spec close_run(map(), :success | :failure | :cancelled) :: :ok
  def close_run(state, outcome) do
    if Archive.capture_enabled?() do
      do_close_run(state, outcome)
    end

    :ok
  rescue
    exception -> log_close_failure(exception)
  catch
    kind, reason -> log_close_failure({kind, reason})
  end

  @doc """
  Archive a cancelled workflow run from its projections. A cancelled run never
  reaches `RunExecutor.cleanup_run_worktree/2`, and its worktree is retained,
  so the diff is taken from that checkout's working tree (uncommitted work
  included). Never raises.
  """
  @spec close_cancelled_run(String.t()) :: :ok
  def close_cancelled_run(run_id) when is_binary(run_id) and run_id != "" do
    worktree =
      run_id
      |> ProjectionStore.worktrees_for_run()
      |> Enum.find(fn wt ->
        is_binary(Map.get(wt, :worktree_path)) and is_binary(Map.get(wt, :base_ref))
      end)

    close_run(%{run_id: run_id, run_worktree: worktree}, :cancelled)
  end

  @doc """
  Complete a subject's archive before analysis: for runs, materialise the
  transcript from the projected run logs; for all kinds merge `status` and
  `finished_at` into the manifest.
  """
  @spec finalize(ForemanServer.Review.Subject.t()) :: :ok | {:error, Error.t()}
  def finalize(%ForemanServer.Review.Subject{} = subject) do
    dir = subject.archive_dir

    with {:ok, _manifest} <- Archive.read_manifest(dir),
         :ok <- finalize_transcript(subject) do
      Archive.merge_manifest(dir, %{
        "status" => to_string(subject.status),
        "finished_at" => DateTime.to_iso8601(DateTime.utc_now())
      })
    end
  end

  @doc """
  Write `transcript.jsonl` from the projected run logs, one object per entry,
  and record source, truncation and omitted counts in the manifest.
  """
  @spec transcript_from_run_logs(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def transcript_from_run_logs(dir, run_id) when is_binary(dir) and is_binary(run_id) do
    case ProjectionStore.run_logs(run_id) do
      {:ok, %{entries: entries} = result} ->
        lines =
          Enum.map(entries, fn entry ->
            Archive.encode_line(to_string(entry.channel), entry.timestamp, entry.content, nil)
          end)

        with :ok <- Archive.write_file(dir, "transcript.jsonl", lines) do
          Archive.merge_manifest(dir, %{
            "transcript_source" => "run_logs",
            "transcript_truncated" => result.truncated == true,
            "omitted_entries" => result.omitted_entries,
            "omitted_bytes" => result.omitted_bytes
          })
        end

      {:error, :run_not_found} ->
        error =
          Error.new(:archive_missing, "run logs unavailable: run not found", %{run_id: run_id})

        Logger.warning("review capture: #{inspect(error)}")
        Archive.record_capture_error(dir, "transcript", error)
        {:error, error}
    end
  end

  defp finalize_transcript(%{kind: :run, archive_dir: dir, subject_id: run_id}),
    do: transcript_from_run_logs(dir, run_id)

  defp finalize_transcript(_jobsite), do: :ok

  defp do_close_run(state, outcome) do
    run_id = state.run_id

    case run_repo_path(run_id) do
      {:ok, repo_path} ->
        dir = Archive.dir(:run, run_id, repo_path)

        try do
          open_run_archive(dir, run_id, repo_path, state, outcome)
        rescue
          exception ->
            error =
              Error.new(:archive_write_failed, "capture close_run raised", %{
                exception: Exception.message(exception)
              })

            Logger.warning("review capture: #{inspect(error)}")
            Archive.record_capture_error(dir, "close_run", error)
        end

      {:error, error} ->
        Logger.warning("review capture: run #{run_id}: #{inspect(error)}")
    end
  end

  defp open_run_archive(dir, run_id, repo_path, state, outcome) do
    run = ProjectionStore.run(run_id) || %{}
    task = run |> Map.get(:task_id) |> task_projection()
    project_id = Map.get(run, :project_id) || Map.get(task || %{}, :project_id)
    {request_text, title} = request_text(task)
    worktree = Map.get(state, :run_worktree)

    manifest = %{
      "kind" => "run",
      "subject_id" => run_id,
      "project_id" => project_id,
      "repo_path" => repo_path,
      "bead_id" => bead_id_for_task(task),
      "request" => %{
        "source" => "task",
        "title" => title,
        "prompt" => request_text,
        "workflow_name" => Map.get(run, :workflow_name)
      },
      "branch" => worktree_field(worktree, :branch),
      "base_ref" => worktree_field(worktree, :base_ref),
      "worktree_path" => worktree_field(worktree, :worktree_path),
      "status" => run_status(outcome),
      "started_at" => started_at(run),
      "transcript_source" => "run_logs"
    }

    with :ok <- Archive.init(dir, manifest),
         :ok <- write_request(dir, request_text) do
      capture_run_diff(dir, worktree, outcome)
    end
  end

  defp task_projection(task_id) when is_binary(task_id) and task_id != "",
    do: ProjectionStore.task_projection(task_id)

  defp task_projection(_), do: nil

  defp request_text(nil), do: {nil, nil}

  defp request_text(task) do
    title = Map.get(task, :title)

    text =
      Enum.find([Map.get(task, :prompt), Map.get(task, :description), title], fn
        v -> is_binary(v) and String.trim(v) != ""
      end)

    {text, title}
  end

  defp write_request(dir, nil) do
    error = Error.new(:archive_missing, "run has no task request text (prompt/description/title)")
    Logger.warning("review capture: #{inspect(error)}")
    Archive.record_capture_error(dir, "request", error)
    Archive.write_file(dir, "request.md", "")
  end

  defp write_request(dir, text), do: Archive.write_file(dir, "request.md", text)

  defp capture_run_diff(dir, %{worktree_path: path, base_ref: base}, outcome)
       when is_binary(path) and is_binary(base) do
    put_diff(dir, path, base, if(outcome == :cancelled, do: :worktree, else: "HEAD"))
  end

  defp capture_run_diff(dir, _no_worktree, _outcome) do
    error = Error.new(:diff_failed, "run has no worktree/base_ref to diff")
    Logger.warning("review capture: #{inspect(error)}")
    Archive.record_capture_error(dir, "diff", error)
    :ok
  end

  defp run_status(:success), do: "completed"
  defp run_status(:failure), do: "failed"
  defp run_status(:cancelled), do: "cancelled"

  defp worktree_field(%{} = worktree, key), do: Map.get(worktree, key)
  defp worktree_field(_, _key), do: nil

  defp started_at(%{started_at_ms: ms}) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  defp started_at(_run), do: nil

  defp log_close_failure(reason) do
    Logger.warning("review capture: close_run failed: #{inspect(reason)}")
    :ok
  end

  # ---------------------------------------------------------------------

  defp do_put_diff(dir, worktree_path, base, head) do
    with :ok <-
           Archive.merge_manifest(dir, %{"base_ref" => base, "worktree_path" => worktree_path}) do
      case Git.diff(worktree_path, base, head) do
        {:ok, diff} -> store_diff(dir, worktree_path, base, head, diff)
        {:error, git_error} -> diff_unavailable(dir, "diff", git_error)
      end
    end
  end

  defp store_diff(dir, worktree_path, base, head, diff) do
    max = max_diff_bytes()
    {body, truncated?} = bound(diff, max)

    if truncated? do
      Archive.record_capture_error(
        dir,
        "diff",
        Error.new(:diff_failed, "diff truncated at #{max} bytes (was #{byte_size(diff)})")
      )
    end

    with :ok <- Archive.write_file(dir, "diff.patch", body),
         :ok <-
           Archive.merge_manifest(dir, %{
             "diff_status" => if(diff == "", do: "empty", else: "captured")
           }) do
      case Git.changed_files(worktree_path, base, head) do
        {:ok, files} -> Archive.write_file(dir, "changed-files.txt", files)
        {:error, git_error} -> changed_files_failed(dir, git_error)
      end
    end
  end

  defp changed_files_failed(dir, git_error) do
    error = Error.new(:diff_failed, "git changed-files failed", %{git: git_error.details})
    Logger.warning("review capture: #{inspect(error)}")
    Archive.record_capture_error(dir, "changed_files", error)
    {:error, error}
  end

  defp diff_unavailable(dir, stage, git_error) do
    error = Error.new(:diff_failed, "git #{stage} failed", %{git: git_error.details})
    Logger.warning("review capture: #{inspect(error)}")
    Archive.record_capture_error(dir, stage, error)

    case Archive.merge_manifest(dir, %{"diff_status" => "unavailable"}) do
      :ok -> {:error, error}
      {:error, _} = merge_error -> merge_error
    end
  end

  defp bound(diff, max) when byte_size(diff) <= max, do: {diff, false}
  defp bound(diff, max), do: {binary_part(diff, 0, max), true}

  defp put_session_id(_dir, id) when id in [nil, ""], do: :ok

  defp put_session_id(dir, id) when is_binary(id) do
    with {:ok, manifest} <- Archive.read_manifest(dir) do
      ids = List.wrap(manifest["provider_session_ids"])
      Archive.merge_manifest(dir, %{"provider_session_ids" => Enum.uniq(ids ++ [id])})
    end
  end

  defp strategy_name(:head), do: "head"
  defp strategy_name(:merge_to_head), do: "merge_to_head"
  defp strategy_name({:branch, name}), do: "branch:" <> name
  defp strategy_name(_other), do: nil

  defp max_diff_bytes do
    :foreman_server
    |> Application.get_env(:review, [])
    |> Keyword.get(:max_diff_bytes, @default_max_diff_bytes)
  end

  # Capture must never fail a run: any exception becomes a recorded error.
  defp guarded(stage, dir, fun) do
    fun.()
  rescue
    exception ->
      error =
        Error.new(:archive_write_failed, "capture #{stage} raised", %{
          exception: Exception.message(exception)
        })

      Logger.warning("review capture: #{inspect(error)}")
      Archive.record_capture_error(dir, stage, error)
      {:error, error}
  end
end
