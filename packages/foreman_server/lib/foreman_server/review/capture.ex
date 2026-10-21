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
  def put_iteration(archive_dir, result, secrets \\ [])

  def put_iteration(nil, _result, _secrets), do: :ok

  def put_iteration(archive_dir, %Jido.Harness.RunResult{} = result, secrets)
      when is_binary(archive_dir) and is_list(secrets) do
    if Archive.capture_enabled?() do
      guarded("put_iteration", archive_dir, fn ->
        with :ok <-
               Archive.append_events(archive_dir, redact_events(result.events || [], secrets)) do
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

  @doc """
  Persist the standing project context an agent was launched with:
  `project-context.md` (byte-identical to the text delivered) plus a
  `project_context` manifest block (sha256, bytes, truncated sections,
  redactions). Written once per archive (the first launch); a bundle with no
  text, a disabled capture or `nil` is a no-op. Never raises.
  """
  @spec put_project_context(String.t() | nil, ForemanServer.ProjectContext.Bundle.t() | nil) ::
          :ok | {:error, Error.t()}
  def put_project_context(nil, _bundle), do: :ok
  def put_project_context(_dir, nil), do: :ok
  def put_project_context(_dir, %{system_text: nil}), do: :ok

  def put_project_context(dir, %{system_text: text} = bundle) when is_binary(dir) do
    if Archive.capture_enabled?() and not File.exists?(Path.join(dir, "project-context.md")) do
      guarded("put_project_context", dir, fn ->
        with :ok <- ensure_manifest(dir, nil),
             :ok <- Archive.write_file(dir, "project-context.md", text) do
          Archive.merge_manifest(dir, %{
            "project_context" => %{
              "sha256" => bundle.sha256,
              "bytes" => bundle.bytes,
              "truncated" =>
                Enum.map(bundle.truncated, fn t ->
                  %{
                    "section" => to_string(t.section),
                    "omitted_bytes" => t.omitted_bytes,
                    "omitted_lines" => t.omitted_lines
                  }
                end),
              "redactions" => bundle.redactions
            }
          })
        end
      end)
    else
      :ok
    end
  end

  @doc "`put_project_context/2` for a workflow run's archive (dir resolved from the run)."
  @spec put_run_project_context(String.t(), ForemanServer.ProjectContext.Bundle.t() | nil) ::
          :ok | {:error, Error.t()}
  def put_run_project_context(_run_id, nil), do: :ok
  def put_run_project_context(_run_id, %{system_text: nil}), do: :ok

  def put_run_project_context(run_id, bundle) when is_binary(run_id) do
    if Archive.capture_enabled?() do
      case run_repo_path(run_id) do
        {:ok, repo_path} ->
          put_project_context(Archive.dir(:run, run_id, repo_path), bundle)

        {:error, error} ->
          Logger.warning("review capture: run #{run_id} project context: #{inspect(error)}")
          {:error, error}
      end
    else
      :ok
    end
  end

  defp ensure_manifest(dir, _) do
    case Archive.read_manifest(dir) do
      {:ok, _} -> :ok
      {:error, _} -> Archive.init(dir, %{})
    end
  end

  @doc """
  Capture `diff.patch` and `changed-files.txt` for `base..head` of the worktree.
  For a `:worktree` head new files are first marked intent-to-add; if that fails
  the tracked-file diff is still captured and the omission of the new files is
  recorded in the manifest's `capture_errors` (stage `intent_to_add`).
  """
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
  The run's repo path: the `repo_path` of the PRIMARY repository's projected
  worktree (the `primary?` entry of `ProjectionStore.run_repositories/1`),
  never a secondary repo's. Absent is a typed error, never a guess.
  """
  @spec run_repo_path(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def run_repo_path(run_id) when is_binary(run_id) do
    path =
      run_id
      |> ProjectionStore.run_repositories()
      |> Enum.find_value(fn
        %{primary?: true, worktree: %{} = wt} ->
          case Map.get(wt, :repo_path) do
            p when is_binary(p) and p != "" -> p
            _ -> nil
          end

        _ ->
          nil
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
      case Enum.find(ProjectionStore.run_repositories(run_id), & &1.primary?) do
        %{worktree: %{} = wt} ->
          wt

        _ ->
          run_id
          |> ProjectionStore.worktrees_for_run()
          |> Enum.find(fn wt ->
            is_binary(Map.get(wt, :worktree_path)) and is_binary(Map.get(wt, :base_ref))
          end)
      end

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

    carried = carried_project_context(dir)

    with :ok <- Archive.init(dir, Map.merge(manifest, carried)),
         :ok <- put_run_session_ids(dir, run),
         :ok <- write_request(dir, request_text) do
      _ = capture_run_diff(dir, worktree, outcome)
      capture_repositories(dir, run_id, worktree, outcome)
    end
  end

  # The launched project context is recorded at the first agent launch, before
  # `close_run/2` writes the final manifest; carry that block over.
  defp carried_project_context(dir) do
    case Archive.read_manifest(dir) do
      {:ok, %{"project_context" => block}} -> %{"project_context" => block}
      _ -> %{}
    end
  end

  # The workflow door's provider session ids come from the run projection
  # (`WorkerSessionBound`), de-duplicated in first-seen order, so a review or
  # resume can pick up a phase's agent thread from the manifest alone. A run
  # whose providers reported none keeps the initial `[]`.
  defp put_run_session_ids(dir, run) do
    ids =
      run
      |> Map.get(:provider_sessions, [])
      |> Enum.map(& &1.provider_session_id)
      |> Enum.uniq()

    case ids do
      [] -> :ok
      ids -> Archive.merge_manifest(dir, %{"provider_session_ids" => ids})
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

  # Multi-repo runs (the run projects more than one repository) archive every
  # non-primary repository's diff under `diffs/<repo_id>.patch` +
  # `diffs/<repo_id>.files.txt` and list all repositories in the manifest's
  # `repositories`. Single-repo runs get neither, so their archives stay
  # byte-identical.
  defp capture_repositories(dir, run_id, primary_worktree, outcome) do
    case ProjectionStore.run_repositories(run_id) do
      [_, _ | _] = repos ->
        head = if outcome == :cancelled, do: :worktree, else: "HEAD"
        prs = Map.new(ProjectionStore.pr_associations_for_run(run_id), &{&1.repo_id, &1})

        entries =
          Enum.map(repos, fn repo ->
            repository_entry(dir, repo, primary_worktree, head, prs)
          end)

        Archive.merge_manifest(dir, %{"repositories" => entries})

      _single_repo ->
        :ok
    end
  end

  defp repository_entry(dir, %{primary?: true} = repo, primary_worktree, _head, prs) do
    status =
      case Archive.read_manifest(dir) do
        {:ok, %{"diff_status" => status}} -> status
        _ -> "unavailable"
      end

    repository_view(repo, primary_worktree || repo.worktree, status, prs)
  end

  defp repository_entry(dir, repo, _primary_worktree, head, prs) do
    status = capture_repo_diff(dir, repo.repo_id, repo.worktree, head)
    repository_view(repo, repo.worktree, status, prs)
  end

  defp repository_view(repo, worktree, status, prs) do
    %{
      "id" => repo.repo_id,
      "primary" => repo.primary?,
      "branch" => worktree_field(worktree, :branch),
      "base_ref" => worktree_field(worktree, :base_ref),
      "worktree_path" => worktree_field(worktree, :worktree_path),
      "diff_status" => status,
      "pr_url" => prs |> Map.get(repo.repo_id) |> pr_url()
    }
  end

  defp pr_url(%{pr_url: url}) when is_binary(url), do: url
  defp pr_url(_), do: nil

  # One non-primary repository's diff; same bound, truncation record and ref
  # guard (`Git.diff/3`) as the primary's. Returns the manifest `diff_status`.
  defp capture_repo_diff(dir, repo_id, %{worktree_path: path, base_ref: base}, head)
       when is_binary(path) and is_binary(base) do
    with :ok <- ForemanServer.Projects.RepoValidation.validate_id(repo_id),
         status when is_binary(status) <-
           guarded("diff:" <> repo_id, dir, fn ->
             mark_new_files(dir, path, head, "intent_to_add:" <> repo_id)
             store_repo_diff(dir, repo_id, path, base, head)
           end) do
      status
    else
      _ -> repo_diff_unavailable(dir, repo_id, "repository diff could not be captured")
    end
  end

  defp capture_repo_diff(dir, repo_id, _no_worktree, _head),
    do: repo_diff_unavailable(dir, repo_id, "repository has no worktree/base_ref to diff")

  defp repo_diff_unavailable(dir, repo_id, message) do
    error = Error.new(:diff_failed, message, %{repo_id: repo_id})
    Logger.warning("review capture: #{inspect(error)}")
    Archive.record_capture_error(dir, "diff:" <> inspect(repo_id), error)
    "unavailable"
  end

  defp store_repo_diff(dir, repo_id, path, base, head) do
    case Git.diff(path, base, head) do
      {:ok, diff} ->
        max = max_diff_bytes()
        {body, truncated?} = bound(diff, max)

        if truncated? do
          Archive.record_capture_error(
            dir,
            "diff:" <> repo_id,
            Error.new(:diff_failed, "diff truncated at #{max} bytes (was #{byte_size(diff)})")
          )
        end

        write_repo_files(dir, repo_id, path, base, head, body)
        if diff == "", do: "empty", else: "captured"

      {:error, git_error} ->
        error = Error.new(:diff_failed, "git diff failed", %{git: git_error.details})
        Logger.warning("review capture: #{inspect(error)}")
        Archive.record_capture_error(dir, "diff:" <> repo_id, error)
        "unavailable"
    end
  end

  defp write_repo_files(dir, repo_id, path, base, head, body) do
    with :ok <- Archive.write_repo_file(dir, repo_id, "patch", body) do
      case Git.changed_files(path, base, head) do
        {:ok, files} ->
          Archive.write_repo_file(dir, repo_id, "files.txt", files)

        {:error, git_error} ->
          error = Error.new(:diff_failed, "git changed-files failed", %{git: git_error.details})
          Logger.warning("review capture: #{inspect(error)}")
          Archive.record_capture_error(dir, "changed_files:" <> repo_id, error)
      end
    end
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
      mark_new_files(dir, worktree_path, head, "intent_to_add")

      case Git.diff(worktree_path, base, head) do
        {:ok, diff} -> store_diff(dir, worktree_path, base, head, diff)
        {:error, git_error} -> diff_unavailable(dir, "diff", git_error)
      end
    end
  end

  # A working-tree diff shows a new file only once it is marked intent-to-add. If
  # that fails (an index lock, a refused path) the diff of the tracked files is
  # still worth archiving, but it omits the new files, so the manifest says so: a
  # partial diff must never read as a complete one.
  defp mark_new_files(dir, worktree_path, :worktree, stage) do
    case Git.mark_intent_to_add(worktree_path) do
      :ok ->
        :ok

      {:error, git_error} ->
        error =
          Error.new(
            :diff_failed,
            "git add --intent-to-add failed; new files are missing from the diff",
            %{git: git_error.details}
          )

        Logger.warning("review capture: #{inspect(error)}")
        Archive.record_capture_error(dir, stage, error)
    end
  end

  defp mark_new_files(_dir, _worktree_path, _committed_head, _stage), do: :ok

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
  # Project secrets must not reach the on-disk transcript (E4-S2): redact every
  # event's text with the same policy the workflow door's run logs use.
  defp redact_events(events, []), do: events

  defp redact_events(events, secrets) do
    Enum.map(events, fn
      %{payload: %{"text" => text} = payload} = event when is_binary(text) ->
        %{
          event
          | payload:
              Map.put(
                payload,
                "text",
                ForemanServer.Overwatch.WorkerLogPolicy.redact(text, secrets)
              )
        }

      event ->
        event
    end)
  end

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
